-- =====================================================================
-- Funções internas (schema "interno", não exposto pela API)
-- =====================================================================

-- Pepper do HMAC: gerado DENTRO do banco e guardado no Vault.
-- Nunca sai do banco e nunca aparece no repositório.
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'hmac_pepper') then
    perform vault.create_secret(
      encode(extensions.gen_random_bytes(32), 'hex'),
      'hmac_pepper',
      'Pepper do HMAC de CPF e nascimento (votação Destaques)');
  end if;
end $$;

create or replace function interno.pepper()
returns text language plpgsql stable security definer
set search_path = '' as $$
declare p text;
begin
  select decrypted_secret into p from vault.decrypted_secrets where name = 'hmac_pepper' limit 1;
  if p is null or length(p) < 32 then
    raise exception 'pepper ausente no Vault';
  end if;
  return p;
end $$;

create or replace function interno.hmac(p text)
returns text language sql stable
set search_path = '' as $$
  select encode(extensions.hmac(convert_to(p, 'UTF8'), convert_to(interno.pepper(), 'UTF8'), 'sha256'), 'hex')
$$;

-- Só dígitos; completa zeros à esquerda perdidos pelo Excel.
create or replace function interno.cpf_digitos(p text)
returns text language sql immutable
set search_path = '' as $$
  select case
    when length(regexp_replace(coalesce(p, ''), '\D', '', 'g')) between 1 and 11
      then lpad(regexp_replace(coalesce(p, ''), '\D', '', 'g'), 11, '0')
    else regexp_replace(coalesce(p, ''), '\D', '', 'g')
  end
$$;

create or replace function interno.cpf_valido(p text)
returns boolean language plpgsql immutable
set search_path = '' as $$
declare d text := regexp_replace(coalesce(p, ''), '\D', '', 'g'); s int; r int; i int;
begin
  if length(d) <> 11 or d ~ '^(\d)\1{10}$' then return false; end if;
  s := 0; for i in 1..9 loop s := s + substr(d, i, 1)::int * (11 - i); end loop;
  r := (s * 10) % 11; if r = 10 then r := 0; end if;
  if r <> substr(d, 10, 1)::int then return false; end if;
  s := 0; for i in 1..10 loop s := s + substr(d, i, 1)::int * (12 - i); end loop;
  r := (s * 10) % 11; if r = 10 then r := 0; end if;
  return r = substr(d, 11, 1)::int;
end $$;

-- Minúsculas, sem acento, espaços simples. Usada para comparar textos.
create or replace function interno.chave(p text)
returns text language sql immutable
set search_path = '' as $$
  select btrim(regexp_replace(lower(translate(coalesce(p, ''),
    'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑáàâãäéèêëíìîïóòôõöúùûüçñ',
    'AAAAAEEEEIIIIOOOOOUUUUCNaaaaaeeeeiiiiooooouuuucn')), '\s+', ' ', 'g'))
$$;

-- Seção 1.2: unidades que viram Matriz. Também tira o prefixo "WAP - " /
-- "WAP 103 - " da planilha (padronização do texto).
create or replace function interno.normalizar_unidade(p text)
returns text language plpgsql immutable
set search_path = '' as $$
declare t text; k text;
begin
  t := btrim(regexp_replace(coalesce(p, ''), '\s+', ' ', 'g'));
  t := btrim(regexp_replace(t, '^wap(\s*\d+)?\s*-\s*', '', 'i'));
  t := btrim(regexp_replace(t, '^wap\s+', '', 'i'));
  if t = '' then return 'Sem unidade'; end if;
  k := regexp_replace(interno.chave(t), '\s*/\s*', '/', 'g');
  if k in ('home office', 'externos', 'externo', 'afonso pena', 'antonio singer',
           'antonio singer/matriz', 'matriz') then
    return 'Matriz';
  end if;
  return initcap(lower(t));
end $$;

-- Devolve NULL se o vínculo é efetivo; senão, o motivo da exclusão.
-- Sem coluna de vínculo, usa o cargo para achar estagiário/aprendiz.
create or replace function interno.motivo_vinculo(p_vinculo text, p_cargo text)
returns text language plpgsql immutable
set search_path = '' as $$
declare v text := interno.chave(p_vinculo); c text := interno.chave(p_cargo);
begin
  if v ~ 'tempor' then return 'Vínculo temporário'; end if;
  if v ~ 'tercei|prestador|\mpj\M|autonom' then return 'Terceiro'; end if;
  if v ~ 'estag' then return 'Estagiário'; end if;
  if v ~ 'aprendiz' then return 'Aprendiz'; end if;
  if c ~ 'estagiari' then return 'Estagiário (pelo cargo)'; end if;
  if c ~ 'aprendiz' then return 'Aprendiz (pelo cargo)'; end if;
  return null;
end $$;

create or replace function interno.situacao_desligado(p text)
returns boolean language sql immutable
set search_path = '' as $$
  select interno.chave(p) ~ 'deslig|demit|demiss|rescis|inativ|falec'
$$;

create or replace function interno.exigir_admin()
returns void language plpgsql stable security definer
set search_path = '' as $$
begin
  if auth.uid() is null or not exists (select 1 from public.admins where user_id = auth.uid()) then
    raise exception 'acesso negado' using errcode = '42501';
  end if;
end $$;

create or replace function interno.votacao_aberta()
returns boolean language sql stable
set search_path = '' as $$
  select c.status = 'aberta'
     and (c.inicio is null or now() >= c.inicio)
     and (c.fim is null or now() <= c.fim)
  from public.config c where c.id = 1
$$;

-- Fonte única da regra "quem pode receber voto de quem, em cada categoria".
create or replace function interno.candidatos(p_eleitor uuid)
returns table (categoria text, candidato_id uuid)
language sql stable
set search_path = '' as $$
  select k.codigo, p.id
  from public.categorias k
  cross join (select id, unidade from public.pessoas where id = p_eleitor) e
  cross join (select * from public.config where id = 1) cfg
  join public.pessoas p
    on p.ativo and p.elegivel
   and (cfg.permitir_auto_voto or p.id <> e.id)
   and (k.escopo = 'geral' or p.unidade = e.unidade)
   and (    k.regra = 'todos'
        or (k.regra = 'admitidos_12m' and p.data_admissao between cfg.vim_para_ficar_desde and cfg.data_corte)
        or (k.regra = 'hipo' and p.high_potential))
$$;

-- Converte a cédula JSON em linhas (categoria, candidato). Assume formato já validado.
create or replace function interno.escolhas(p jsonb)
returns table (categoria text, candidato_id uuid)
language sql immutable
set search_path = '' as $$
  select e.key, (x #>> '{}')::uuid
  from jsonb_each(p) e, jsonb_array_elements(e.value) x
$$;

revoke all on all functions in schema interno from public;
do $$ begin
  execute 'revoke all on all functions in schema interno from anon, authenticated';
exception when undefined_object then null; end $$;

-- =====================================================================
-- Multiempresa: WAP e Freso no mesmo banco (plano Free = 2 projetos).
-- Cada empresa tem config, base, lista HiPo, votação e apuração próprias.
-- Admins são unificados. Nada liga eleitor a voto (requisito mantido).
-- =====================================================================

create table if not exists public.empresas (
  codigo text primary key check (codigo ~ '^[A-Z]+$'),
  nome text not null,
  ordem int not null
);
alter table public.empresas enable row level security;
revoke all on table public.empresas from public;
do $$ begin execute 'revoke all on table public.empresas from anon, authenticated';
exception when undefined_object then null; end $$;
insert into public.empresas (codigo, nome, ordem) values ('WAP', 'WAP', 1), ('FRESO', 'Freso', 2)
on conflict (codigo) do update set nome = excluded.nome, ordem = excluded.ordem;

-- ---------------------------------------------------------------- config por empresa
alter table public.config add column if not exists empresa text references public.empresas(codigo);
update public.config set empresa = 'WAP' where empresa is null;
alter table public.config alter column empresa set not null;
alter table public.config drop constraint if exists config_pkey;
alter table public.config drop constraint if exists config_id_check;
alter table public.config drop column if exists id;
alter table public.config add primary key (empresa);
insert into public.config (empresa, nome_eleicao, data_corte, vim_para_ficar_desde, inicio, fim, status, permitir_auto_voto, max_por_categoria)
select 'FRESO', 'Destaques do Ano 2026', '2026-11-30', '2025-12-01',
       '2026-12-09 00:00:00-03', '2026-12-23 23:59:59-03', 'rascunho', false, 3
on conflict (empresa) do nothing;

-- ---------------------------------------------------------------- pessoas / votos / importações
alter table public.pessoas add column if not exists empresa text references public.empresas(codigo);
update public.pessoas set empresa = 'WAP' where empresa is null;
alter table public.pessoas alter column empresa set not null;
alter table public.pessoas drop constraint if exists pessoas_cpf_hash_key;
alter table public.pessoas add constraint pessoas_empresa_cpf_key unique (empresa, cpf_hash);
drop index if exists public.pessoas_unidade_ativos_idx;
create index if not exists pessoas_empresa_unidade_idx on public.pessoas (empresa, unidade) where ativo and elegivel;

alter table public.votos add column if not exists empresa text references public.empresas(codigo);
update public.votos set empresa = 'WAP' where empresa is null;
alter table public.votos alter column empresa set not null;
drop index if exists public.votos_apuracao_idx;
create index if not exists votos_apuracao_idx on public.votos (empresa, categoria, unidade_apuracao, candidato_id);

alter table public.importacoes add column if not exists empresa text references public.empresas(codigo);

-- ---------------------------------------------------------------- remove as assinaturas antigas
drop function if exists public.info_publica();
drop function if exists public.iniciar_votacao(text, date);
drop function if exists public.importar_ativos(jsonb, boolean);
drop function if exists public.importar_hipo(jsonb, boolean);
drop function if exists public.configurar(jsonb);
drop function if exists public.alterar_status(text);
drop function if exists public.apurar();
drop function if exists public.exportar_ata();
drop function if exists public.painel_admin();
drop function if exists public.zerar_votacao(text);
drop function if exists public.anonimizar_base(text);
drop function if exists interno.votacao_aberta();
drop function if exists interno.apuracao();
drop function if exists interno.normalizar_unidade(text);

-- ---------------------------------------------------------------- funções internas
create or replace function interno.empresa_valida(p text)
returns text language plpgsql stable
set search_path = '' as $$
begin
  if p is null or not exists (select 1 from public.empresas where codigo = upper(p)) then
    raise exception 'empresa inválida';
  end if;
  return upper(p);
end $$;

-- Seção 1.2 (regra da Matriz) vale só para a WAP. Para as demais, só padroniza o texto.
create or replace function interno.normalizar_unidade(p text, p_empresa text)
returns text language plpgsql immutable
set search_path = '' as $$
declare t text; k text;
begin
  t := btrim(regexp_replace(coalesce(p, ''), '\s+', ' ', 'g'));
  t := btrim(regexp_replace(t, '^(wap|freso)(\s*\d+)?\s*-\s*', '', 'i'));
  t := btrim(regexp_replace(t, '^(wap|freso)\s+', '', 'i'));
  if t = '' then return 'Sem unidade'; end if;
  k := regexp_replace(interno.chave(t), '\s*/\s*', '/', 'g');
  if p_empresa = 'WAP' and k in ('home office', 'externos', 'externo', 'afonso pena', 'antonio singer',
           'antonio singer/matriz', 'matriz') then
    return 'Matriz';
  end if;
  -- Title case, mantendo siglas curtas (CD, SP) e preposições em minúsculas.
  return (select string_agg(case
            when lower(w) in ('da', 'de', 'do', 'das', 'dos', 'e') and ord > 1 then lower(w)
            when length(w) <= 3 and w = upper(w) and w ~ '[A-Z]' then w
            else initcap(lower(w)) end, ' ' order by ord)
          from unnest(string_to_array(t, ' ')) with ordinality as x(w, ord));
end $$;

create or replace function interno.votacao_aberta(p_empresa text)
returns boolean language sql stable
set search_path = '' as $$
  select c.status = 'aberta'
     and (c.inicio is null or now() >= c.inicio)
     and (c.fim is null or now() <= c.fim)
  from public.config c where c.empresa = p_empresa
$$;

-- Fonte única da regra "quem pode receber voto de quem" (sempre dentro da mesma empresa).
create or replace function interno.candidatos(p_eleitor uuid)
returns table (categoria text, candidato_id uuid)
language sql stable
set search_path = '' as $$
  select k.codigo, p.id
  from public.categorias k
  cross join (select id, unidade, empresa from public.pessoas where id = p_eleitor) e
  join public.config cfg on cfg.empresa = e.empresa
  join public.pessoas p
    on p.empresa = e.empresa
   and p.ativo and p.elegivel
   and (cfg.permitir_auto_voto or p.id <> e.id)
   and (k.escopo = 'geral' or p.unidade = e.unidade)
   and (    k.regra = 'todos'
        or (k.regra = 'admitidos_12m' and p.data_admissao between cfg.vim_para_ficar_desde and cfg.data_corte)
        or (k.regra = 'hipo' and p.high_potential))
$$;

-- ---------------------------------------------------------------- RPCs públicas
create or replace function public.info_publica(p_empresa text)
returns jsonb language plpgsql stable security definer
set search_path = public, extensions as $$
declare e text := interno.empresa_valida(p_empresa);
begin
  return (select jsonb_build_object(
    'empresa', c.empresa,
    'empresa_nome', (select nome from empresas where codigo = c.empresa),
    'nome_eleicao', c.nome_eleicao,
    'status', c.status,
    'aberta_agora', interno.votacao_aberta(c.empresa),
    'inicio', c.inicio, 'fim', c.fim, 'data_corte', c.data_corte,
    'max_por_categoria', c.max_por_categoria,
    'categorias', (select coalesce(jsonb_agg(jsonb_build_object(
        'codigo', k.codigo, 'nome', k.nome, 'descricao', k.descricao, 'escopo', k.escopo) order by k.ordem), '[]'::jsonb) from categorias k))
  from config c where c.empresa = e);
end $$;

create or replace function public.iniciar_votacao(p_empresa text, p_cpf text, p_nascimento date)
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions as $$
declare
  generica constant text := 'Não foi possível validar seus dados ou seu voto já foi registrado. Procure o RH.';
  emp text := interno.empresa_valida(p_empresa);
  d text;
  v pessoas;
  tok uuid;
  exp timestamptz := now() + interval '20 minutes';
  res jsonb;
begin
  if not coalesce(interno.votacao_aberta(emp), false) then
    return jsonb_build_object('ok', false, 'codigo', 'fechada', 'mensagem', 'A votação não está aberta no momento.');
  end if;

  d := regexp_replace(coalesce(p_cpf, ''), '\D', '', 'g');
  if not interno.cpf_valido(d) then
    return jsonb_build_object('ok', false, 'codigo', 'cpf_invalido', 'mensagem', 'CPF inválido. Confira os números digitados.');
  end if;

  select * into v from pessoas where empresa = emp and cpf_hash = interno.hmac(d) for update;
  if not found then
    return jsonb_build_object('ok', false, 'codigo', 'recusado', 'mensagem', generica);
  end if;
  if v.bloqueado_ate is not null and v.bloqueado_ate > now() then
    return jsonb_build_object('ok', false, 'codigo', 'recusado', 'mensagem', generica);
  end if;
  if p_nascimento is null
     or v.nasc_hash <> interno.hmac(d || '|' || to_char(p_nascimento, 'YYYY-MM-DD')) then
    update pessoas set
      tentativas_falhas = case when tentativas_falhas + 1 >= 5 then 0 else tentativas_falhas + 1 end,
      bloqueado_ate     = case when tentativas_falhas + 1 >= 5 then now() + interval '15 minutes' else bloqueado_ate end
    where id = v.id;
    return jsonb_build_object('ok', false, 'codigo', 'recusado', 'mensagem', generica);
  end if;
  if not v.ativo or not v.elegivel or v.ja_votou then
    return jsonb_build_object('ok', false, 'codigo', 'recusado', 'mensagem', generica);
  end if;
  if v.tentativas_falhas <> 0 or v.bloqueado_ate is not null then
    update pessoas set tentativas_falhas = 0, bloqueado_ate = null where id = v.id;
  end if;

  delete from sessoes_voto where expira_em < now();
  insert into sessoes_voto (pessoa_id, expira_em) values (v.id, exp) returning token into tok;

  with cand as (
    select * from interno.candidatos(v.id)
  ), ppl as (
    select p.id, p.nome, coalesce(p.setor, '') as setor,
           (row_number() over (order by interno.chave(p.nome), p.id) - 1)::int as idx
    from pessoas p where p.id in (select candidato_id from cand)
  )
  select jsonb_build_object(
    'ok', true, 'token', tok, 'expira_em', exp,
    'primeiro_nome', initcap(lower(split_part(btrim(v.nome), ' ', 1))),
    'unidade', v.unidade,
    'max_por_categoria', (select max_por_categoria from config where empresa = emp),
    'pessoas', coalesce((select jsonb_agg(jsonb_build_array(ppl.id, ppl.nome, ppl.setor) order by ppl.idx) from ppl), '[]'::jsonb),
    'categorias', (
      select jsonb_agg(jsonb_build_object(
        'codigo', k.codigo, 'nome', k.nome, 'descricao', k.descricao, 'escopo', k.escopo,
        'candidatos', coalesce((select jsonb_agg(ppl.idx order by ppl.idx)
                                from cand join ppl on ppl.id = cand.candidato_id
                                where cand.categoria = k.codigo), '[]'::jsonb)
      ) order by k.ordem) from categorias k)
  ) into res;
  return res;
end $$;

create or replace function public.registrar_cedula(p_token uuid, p_escolhas jsonb)
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions as $$
declare
  generica constant text := 'Não foi possível validar seus dados ou seu voto já foi registrado. Procure o RH.';
  invalida constant text := 'Cédula inválida. Atualize a página e tente novamente.';
  s sessoes_voto;
  v pessoas;
  maxc int;
  n int;
  uuid_re constant text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
begin
  select * into s from sessoes_voto where token = p_token;
  if not found or s.expira_em < now() then
    return jsonb_build_object('ok', false, 'codigo', 'sessao_expirada', 'mensagem', 'Sua sessão expirou. Identifique-se novamente.');
  end if;

  select * into v from pessoas where id = s.pessoa_id for update;   -- duas abas / duplo clique serializam aqui

  if v.id is null or not coalesce(interno.votacao_aberta(v.empresa), false) then
    return jsonb_build_object('ok', false, 'codigo', 'fechada', 'mensagem', 'A votação não está aberta no momento.');
  end if;
  if v.ja_votou or not v.ativo or not v.elegivel then
    delete from sessoes_voto where pessoa_id = s.pessoa_id;
    return jsonb_build_object('ok', false, 'codigo', 'recusado', 'mensagem', generica);
  end if;

  select max_por_categoria into maxc from config where empresa = v.empresa;

  if p_escolhas is null or jsonb_typeof(p_escolhas) <> 'object' then
    return jsonb_build_object('ok', false, 'codigo', 'cedula_invalida', 'mensagem', invalida);
  end if;
  if exists (select 1 from jsonb_object_keys(p_escolhas) k where k not in (select codigo from categorias)) then
    return jsonb_build_object('ok', false, 'codigo', 'cedula_invalida', 'mensagem', invalida);
  end if;
  if exists (select 1 from jsonb_each(p_escolhas) e
             where jsonb_typeof(e.value) <> 'array' or jsonb_array_length(e.value) > maxc) then
    return jsonb_build_object('ok', false, 'codigo', 'cedula_invalida', 'mensagem', invalida);
  end if;
  if exists (select 1 from jsonb_each(p_escolhas) e, jsonb_array_elements(e.value) x
             where jsonb_typeof(x) <> 'string' or (x #>> '{}') !~ uuid_re) then
    return jsonb_build_object('ok', false, 'codigo', 'cedula_invalida', 'mensagem', invalida);
  end if;
  if exists (select 1 from interno.escolhas(p_escolhas) group by categoria, candidato_id having count(*) > 1) then
    return jsonb_build_object('ok', false, 'codigo', 'cedula_invalida', 'mensagem', invalida);
  end if;
  if exists (select 1 from interno.escolhas(p_escolhas) e
             where not exists (select 1 from interno.candidatos(v.id) c
                               where c.categoria = e.categoria and c.candidato_id = e.candidato_id)) then
    return jsonb_build_object('ok', false, 'codigo', 'cedula_invalida', 'mensagem', invalida);
  end if;
  select count(*) into n from interno.escolhas(p_escolhas);
  if n < 1 then
    return jsonb_build_object('ok', false, 'codigo', 'cedula_vazia', 'mensagem', 'Escolha ao menos uma pessoa antes de confirmar.');
  end if;

  insert into votos (empresa, categoria, candidato_id, unidade_apuracao)
  select v.empresa, e.categoria, e.candidato_id,
         case when k.escopo = 'unidade' then p.unidade else 'GERAL' end
  from interno.escolhas(p_escolhas) e
  join categorias k on k.codigo = e.categoria
  join pessoas p on p.id = e.candidato_id
  order by random();

  update pessoas set ja_votou = true, votou_dia = (now() at time zone 'America/Sao_Paulo')::date where id = v.id;
  delete from sessoes_voto where pessoa_id = v.id;

  return jsonb_build_object('ok', true,
    'protocolo', upper(substr(encode(gen_random_bytes(5), 'hex'), 1, 5) || '-' || substr(encode(gen_random_bytes(5), 'hex'), 1, 5)));
end $$;

-- ---------------------------------------------------------------- RPCs de admin
create or replace function public.importar_ativos(p_empresa text, p_linhas jsonb, p_simular boolean default true)
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions as $$
declare
  emp text;
  cfg config;
  pep text;
  res jsonb;
  n_ativos_antes int;
begin
  perform interno.exigir_admin();
  emp := interno.empresa_valida(p_empresa);
  if p_linhas is null or jsonb_typeof(p_linhas) <> 'array' or jsonb_array_length(p_linhas) = 0 then
    raise exception 'planilha vazia';
  end if;
  if jsonb_array_length(p_linhas) > 20000 then raise exception 'planilha grande demais'; end if;
  select * into cfg from config where empresa = emp;
  pep := interno.pepper();
  select count(*) into n_ativos_antes from pessoas where empresa = emp and ativo;

  drop table if exists pg_temp._imp;
  create temp table _imp on commit drop as
  select
    t.ord::int                                               as linha,
    interno.cpf_digitos(t.l->>'cpf')                         as cpf,
    nullif(btrim(regexp_replace(coalesce(t.l->>'nome', ''), '\s+', ' ', 'g')), '') as nome,
    interno.data_iso(t.l->>'nascimento')                     as nasc,
    interno.data_iso(t.l->>'admissao')                       as adm,
    nullif(btrim(t.l->>'matricula'), '')                     as matricula,
    nullif(btrim(t.l->>'cargo'), '')                         as cargo,
    nullif(btrim(t.l->>'setor'), '')                         as setor,
    nullif(btrim(t.l->>'unidade'), '')                       as unidade_original,
    nullif(btrim(t.l->>'vinculo'), '')                       as vinculo_planilha,
    nullif(btrim(t.l->>'situacao'), '')                      as situacao,
    null::text as motivo_ignorado, null::text as cpf_hash, null::text as nasc_hash, null::text as unidade,
    null::text as motivo_inelegivel, null::text as vinculo, false as desligado, null::text as acao
  from jsonb_array_elements(p_linhas) with ordinality t(l, ord);

  update _imp set motivo_ignorado = case
      when not interno.cpf_valido(cpf) then 'CPF inválido'
      when nome is null then 'Sem nome'
      when nasc is null then 'Data de nascimento inválida'
      when adm is null then 'Data de admissão inválida'
    end
  where true;   -- o Supabase (pg_safeupdate) recusa UPDATE sem WHERE

  update _imp i set motivo_ignorado = 'CPF repetido na planilha'
  from (select linha, row_number() over (partition by cpf order by linha) rn from _imp where motivo_ignorado is null) d
  where d.linha = i.linha and d.rn > 1;

  update _imp set
    cpf_hash  = encode(hmac(convert_to(cpf, 'UTF8'), convert_to(pep, 'UTF8'), 'sha256'), 'hex'),
    nasc_hash = encode(hmac(convert_to(cpf || '|' || to_char(nasc, 'YYYY-MM-DD'), 'UTF8'), convert_to(pep, 'UTF8'), 'sha256'), 'hex'),
    unidade   = interno.normalizar_unidade(unidade_original, emp),
    desligado = interno.situacao_desligado(situacao),
    motivo_inelegivel = coalesce(
      interno.motivo_vinculo(vinculo_planilha, cargo),
      case when interno.chave(setor) ~ 'apinvalidez|aposentad'
             or interno.chave(cargo) ~ 'aposentad' then 'Aposentadoria por invalidez' end,
      case when adm > cfg.data_corte then 'Admitido após ' || to_char(cfg.data_corte, 'DD/MM/YYYY') end),
    vinculo = coalesce(vinculo_planilha,
      case when interno.motivo_vinculo(null, cargo) like 'Aprendiz%' then 'Aprendiz'
           when interno.motivo_vinculo(null, cargo) like 'Estagi%' then 'Estagiário'
           else 'Efetivo (CLT)' end)
  where motivo_ignorado is null;

  update _imp set cpf = null where true;   -- CPF em texto não é mais necessário

  update _imp i set acao = case
      when i.desligado then 'desligado_planilha'
      when p.id is null then 'novo'
      when not p.ativo then 'reativado'
      else 'atualizado' end
  from _imp i2
  left join pessoas p on p.empresa = emp and p.cpf_hash = i2.cpf_hash
  where i2.linha = i.linha and i.motivo_ignorado is null;

  with desl as (
    select p.id, p.nome, p.unidade from pessoas p
    where p.empresa = emp and p.ativo and not exists (
      select 1 from _imp i where i.cpf_hash = p.cpf_hash and i.motivo_ignorado is null and not i.desligado)
  )
  select jsonb_build_object(
    'empresa', emp,
    'simulado', p_simular,
    'total_linhas', (select count(*) from _imp),
    'novos', (select count(*) from _imp where acao = 'novo'),
    'atualizados', (select count(*) from _imp where acao = 'atualizado'),
    'reativados', (select count(*) from _imp where acao = 'reativado'),
    'desligados', (select count(*) from desl),
    'ignorados', (select count(*) from _imp where motivo_ignorado is not null),
    'inelegiveis', (select count(*) from _imp where acao in ('novo','atualizado','reativado') and motivo_inelegivel is not null),
    'elegiveis', (select count(*) from _imp where acao in ('novo','atualizado','reativado') and motivo_inelegivel is null),
    'ativos_antes', n_ativos_antes,
    'alerta_desligamentos', n_ativos_antes > 0 and (select count(*) from desl) > greatest(10, n_ativos_antes * 0.2),
    'por_unidade', (select coalesce(jsonb_agg(x order by x->>'unidade'), '[]'::jsonb) from (
        select jsonb_build_object('unidade', unidade, 'total', count(*),
          'elegiveis', count(*) filter (where motivo_inelegivel is null),
          'admitidos_12m', count(*) filter (where motivo_inelegivel is null and adm between cfg.vim_para_ficar_desde and cfg.data_corte)) x
        from _imp where acao in ('novo','atualizado','reativado') group by unidade) s),
    'unidades', (select coalesce(jsonb_agg(x order by x->>'final', x->>'original'), '[]'::jsonb) from (
        select jsonb_build_object('original', coalesce(unidade_original, '(vazio)'), 'final', unidade, 'qtd', count(*)) x
        from _imp where motivo_ignorado is null group by unidade_original, unidade) s),
    'motivos_inelegiveis', (select coalesce(jsonb_object_agg(motivo_inelegivel, n), '{}'::jsonb) from (
        select motivo_inelegivel, count(*) n from _imp
        where acao in ('novo','atualizado','reativado') and motivo_inelegivel is not null group by 1) s),
    'lista_inelegiveis', (select coalesce(jsonb_agg(jsonb_build_object('linha', linha, 'nome', nome, 'unidade', unidade, 'motivo', motivo_inelegivel) order by linha), '[]'::jsonb)
        from _imp where acao in ('novo','atualizado','reativado') and motivo_inelegivel is not null),
    'lista_ignorados', (select coalesce(jsonb_agg(jsonb_build_object('linha', linha, 'nome', nome, 'motivo', motivo_ignorado) order by linha), '[]'::jsonb)
        from _imp where motivo_ignorado is not null),
    'lista_desligados', (select coalesce(jsonb_agg(jsonb_build_object('nome', nome, 'unidade', unidade) order by nome), '[]'::jsonb) from desl),
    'lista_reativados', (select coalesce(jsonb_agg(jsonb_build_object('nome', nome, 'unidade', unidade) order by nome), '[]'::jsonb)
        from _imp where acao = 'reativado')
  ) into res;

  if p_simular then return res; end if;

  insert into pessoas (empresa, cpf_hash, nasc_hash, nome, matricula, cargo, setor, unidade_original, unidade,
                       data_admissao, vinculo, elegivel, motivo_inelegivel)
  select emp, cpf_hash, nasc_hash, nome, matricula, cargo, setor, unidade_original, unidade,
         adm, vinculo, motivo_inelegivel is null, motivo_inelegivel
  from _imp where acao = 'novo';

  update pessoas p set
    nasc_hash = i.nasc_hash, nome = i.nome, matricula = i.matricula, cargo = i.cargo, setor = i.setor,
    unidade_original = i.unidade_original, unidade = i.unidade, data_admissao = i.adm,
    vinculo = i.vinculo, elegivel = i.motivo_inelegivel is null, motivo_inelegivel = i.motivo_inelegivel,
    ativo = true, desligado_em = null
  from _imp i
  where p.empresa = emp and i.acao in ('atualizado', 'reativado') and p.cpf_hash = i.cpf_hash;

  -- Desligamento lógico SÓ dentro da empresa importada. Nada é apagado.
  update pessoas p set ativo = false, desligado_em = now()
  where p.empresa = emp and p.ativo and not exists (
    select 1 from _imp i where i.cpf_hash = p.cpf_hash and i.motivo_ignorado is null and not i.desligado);

  insert into importacoes (empresa, feito_por, tipo, novos, atualizados, desligados, ignorados, detalhes)
  values (emp, auth.uid(), 'ativos',
    (res->>'novos')::int, (res->>'atualizados')::int + (res->>'reativados')::int,
    (res->>'desligados')::int, (res->>'ignorados')::int,
    jsonb_build_object('total_linhas', res->'total_linhas', 'reativados', res->'reativados',
      'elegiveis', res->'elegiveis', 'inelegiveis', res->'inelegiveis',
      'motivos_inelegiveis', res->'motivos_inelegiveis', 'por_unidade', res->'por_unidade'));
  return res;
end $$;

create or replace function public.importar_hipo(p_empresa text, p_linhas jsonb, p_simular boolean default true)
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions as $$
declare emp text; pep text; res jsonb;
begin
  perform interno.exigir_admin();
  emp := interno.empresa_valida(p_empresa);
  if p_linhas is null or jsonb_typeof(p_linhas) <> 'array' or jsonb_array_length(p_linhas) = 0 then
    raise exception 'lista vazia';
  end if;
  pep := interno.pepper();

  drop table if exists pg_temp._hipo;
  create temp table _hipo on commit drop as
  select t.ord::int as linha, interno.cpf_digitos(t.l->>'cpf') as cpf,
         nullif(btrim(t.l->>'matricula'), '') as matricula, nullif(btrim(t.l->>'nome'), '') as nome,
         null::uuid as pessoa_id, null::text as problema
  from jsonb_array_elements(p_linhas) with ordinality t(l, ord);

  update _hipo h set pessoa_id = p.id
  from pessoas p
  where p.empresa = emp and interno.cpf_valido(h.cpf)
    and p.cpf_hash = encode(hmac(convert_to(h.cpf, 'UTF8'), convert_to(pep, 'UTF8'), 'sha256'), 'hex');
  update _hipo set cpf = null where true;

  update _hipo h set pessoa_id = m.id
  from (select matricula, min(id::text)::uuid id, count(*) n from pessoas
        where empresa = emp and ativo and matricula is not null group by matricula) m
  where h.pessoa_id is null and h.matricula is not null and m.matricula = h.matricula and m.n = 1;

  update _hipo h set problema = 'Matrícula repetida na base: informe o CPF'
  where h.pessoa_id is null and h.matricula is not null
    and (select count(*) from pessoas p where p.empresa = emp and p.ativo and p.matricula = h.matricula) > 1;
  update _hipo set problema = 'Não encontrado na base de ativos' where pessoa_id is null and problema is null;

  select jsonb_build_object(
    'empresa', emp, 'simulado', p_simular,
    'total_linhas', (select count(*) from _hipo),
    'encontrados', (select count(distinct pessoa_id) from _hipo where pessoa_id is not null),
    'elegiveis', (select count(distinct h.pessoa_id) from _hipo h join pessoas p on p.id = h.pessoa_id where p.ativo and p.elegivel),
    'lista_nao_encontrados', (select coalesce(jsonb_agg(jsonb_build_object('linha', linha, 'nome', nome, 'matricula', matricula, 'motivo', problema) order by linha), '[]'::jsonb)
        from _hipo where pessoa_id is null),
    'lista_nao_elegiveis', (select coalesce(jsonb_agg(jsonb_build_object('nome', p.nome, 'unidade', p.unidade,
          'motivo', case when not p.ativo then 'Desligado' else coalesce(p.motivo_inelegivel, 'Inelegível') end) order by p.nome), '[]'::jsonb)
        from (select distinct pessoa_id from _hipo where pessoa_id is not null) h join pessoas p on p.id = h.pessoa_id
        where not (p.ativo and p.elegivel)),
    'lista_participantes', (select coalesce(jsonb_agg(jsonb_build_object('nome', p.nome, 'unidade', p.unidade) order by p.nome), '[]'::jsonb)
        from (select distinct pessoa_id from _hipo where pessoa_id is not null) h join pessoas p on p.id = h.pessoa_id
        where p.ativo and p.elegivel)
  ) into res;

  if p_simular then return res; end if;

  update pessoas set high_potential = false where empresa = emp and high_potential;
  update pessoas set high_potential = true where id in (select pessoa_id from _hipo where pessoa_id is not null);

  insert into importacoes (empresa, feito_por, tipo, novos, atualizados, desligados, ignorados, detalhes)
  values (emp, auth.uid(), 'hipo', (res->>'encontrados')::int, 0, 0, jsonb_array_length(res->'lista_nao_encontrados'),
          jsonb_build_object('total_linhas', res->'total_linhas', 'elegiveis', res->'elegiveis',
                             'nao_elegiveis', jsonb_array_length(res->'lista_nao_elegiveis')));
  return res;
end $$;

create or replace function public.configurar(p_empresa text, p jsonb)
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions as $$
declare emp text; c config;
begin
  perform interno.exigir_admin();
  emp := interno.empresa_valida(p_empresa);
  select * into c from config where empresa = emp for update;
  if c.status = 'aberta' and p ? 'permitir_auto_voto'
     and (p->>'permitir_auto_voto')::boolean is distinct from c.permitir_auto_voto then
    raise exception 'não é possível mudar a regra de auto-voto com a votação aberta';
  end if;
  update config set
    nome_eleicao = coalesce(nullif(btrim(p->>'nome_eleicao'), ''), nome_eleicao),
    inicio = case when p ? 'inicio' then (p->>'inicio')::timestamptz else inicio end,
    fim    = case when p ? 'fim' then (p->>'fim')::timestamptz else fim end,
    permitir_auto_voto = coalesce((p->>'permitir_auto_voto')::boolean, permitir_auto_voto)
  where empresa = emp;
  insert into importacoes (empresa, feito_por, tipo, detalhes)
  values (emp, auth.uid(), 'config', (select to_jsonb(x) from config x where empresa = emp));
  return (select to_jsonb(x) from config x where empresa = emp);
end $$;

create or replace function public.alterar_status(p_empresa text, p_status text)
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions as $$
declare emp text; c config;
begin
  perform interno.exigir_admin();
  emp := interno.empresa_valida(p_empresa);
  select * into c from config where empresa = emp for update;
  if not ((c.status = 'rascunho' and p_status = 'aberta')
       or (c.status = 'aberta' and p_status = 'encerrada')
       or (c.status = 'encerrada' and p_status = 'aberta')) then
    raise exception 'transição de status não permitida: % → %', c.status, p_status;
  end if;
  if p_status = 'aberta' then
    if c.inicio is null or c.fim is null then raise exception 'defina início e fim antes de abrir'; end if;
    if not exists (select 1 from pessoas where empresa = emp and ativo and elegivel) then
      raise exception 'importe a base de ativos antes de abrir';
    end if;
  end if;
  update config set status = p_status where empresa = emp;
  insert into importacoes (empresa, feito_por, tipo, detalhes)
  values (emp, auth.uid(), 'status', jsonb_build_object('de', c.status, 'para', p_status));
  return (select to_jsonb(x) from config x where empresa = emp);
end $$;

create or replace function interno.apuracao(p_empresa text)
returns jsonb language sql stable
set search_path = '' as $$
  with cfg as (select * from public.config where empresa = p_empresa),
  ncat as (select count(*)::int n from public.categorias),
  grupos as (
    select k.codigo as categoria, k.nome as categoria_nome, k.ordem, u.unidade as unidade_apuracao
    from public.categorias k
    join (select distinct unidade from public.pessoas where empresa = p_empresa and ativo and elegivel) u on k.escopo = 'unidade'
    union
    select k.codigo, k.nome, k.ordem, 'GERAL' from public.categorias k where k.escopo = 'geral'
    union
    select distinct v.categoria, k.nome, k.ordem, v.unidade_apuracao
    from public.votos v join public.categorias k on k.codigo = v.categoria where v.empresa = p_empresa
  ),
  cont as (
    select categoria, unidade_apuracao, candidato_id, count(*)::int n
    from public.votos where empresa = p_empresa group by 1, 2, 3
  ),
  rk as (
    select c.categoria, c.unidade_apuracao, c.candidato_id, c.n, p.nome, p.setor,
           rank() over (partition by c.categoria, c.unidade_apuracao order by c.n desc)::int pos
    from cont c join public.pessoas p on p.id = c.candidato_id where p.ativo
  ),
  anul as (
    select c.categoria, c.unidade_apuracao, sum(c.n)::int anulados, count(*)::int candidatos
    from cont c join public.pessoas p on p.id = c.candidato_id where not p.ativo group by 1, 2
  ),
  part as (
    select unidade, count(*)::int elegiveis, count(*) filter (where ja_votou)::int votaram
    from public.pessoas where empresa = p_empresa and ativo and elegivel group by unidade
  ),
  tot as (
    select (select count(*)::int from public.pessoas where empresa = p_empresa and ja_votou) cedulas,
           (select count(*)::int from public.votos where empresa = p_empresa) votos
  )
  select jsonb_build_object(
    'empresa', p_empresa,
    'empresa_nome', (select nome from public.empresas where codigo = p_empresa),
    'gerado_em', now(),
    'status', (select status from cfg),
    'grupos', (select coalesce(jsonb_agg(jsonb_build_object(
        'categoria', g.categoria, 'categoria_nome', g.categoria_nome, 'unidade', g.unidade_apuracao,
        'votos_validos', coalesce((select sum(n)::int from rk where rk.categoria = g.categoria and rk.unidade_apuracao = g.unidade_apuracao), 0),
        'anulados', coalesce(a.anulados, 0),
        'candidatos_anulados', coalesce(a.candidatos, 0),
        'empate', (select count(*) from rk where rk.categoria = g.categoria and rk.unidade_apuracao = g.unidade_apuracao and pos = 1) > 1,
        'vencedor', case when (select count(*) from rk where rk.categoria = g.categoria and rk.unidade_apuracao = g.unidade_apuracao and pos = 1) = 1
                    then (select jsonb_build_object('id', candidato_id, 'nome', nome, 'setor', setor, 'votos', n)
                          from rk where rk.categoria = g.categoria and rk.unidade_apuracao = g.unidade_apuracao and pos = 1) end,
        'ranking', coalesce((select jsonb_agg(jsonb_build_object('id', candidato_id, 'nome', nome, 'setor', setor, 'votos', n, 'posicao', pos)
                             order by n desc, nome)
                             from rk where rk.categoria = g.categoria and rk.unidade_apuracao = g.unidade_apuracao), '[]'::jsonb)
      ) order by g.ordem, g.unidade_apuracao), '[]'::jsonb)
      from grupos g left join anul a on a.categoria = g.categoria and a.unidade_apuracao = g.unidade_apuracao),
    'participacao', (select coalesce(jsonb_agg(jsonb_build_object('unidade', unidade, 'elegiveis', elegiveis, 'votaram', votaram,
        'percentual', round(100.0 * votaram / nullif(elegiveis, 0), 1)) order by unidade), '[]'::jsonb) from part),
    'participacao_geral', (select jsonb_build_object('elegiveis', coalesce(sum(elegiveis), 0), 'votaram', coalesce(sum(votaram), 0),
        'percentual', round(100.0 * sum(votaram) / nullif(sum(elegiveis), 0), 1)) from part),
    'por_dia', (select coalesce(jsonb_agg(jsonb_build_object('dia', votou_dia, 'cedulas', n) order by votou_dia), '[]'::jsonb)
        from (select votou_dia, count(*)::int n from public.pessoas
              where empresa = p_empresa and ja_votou and votou_dia is not null group by 1) d),
    'cedulas', (select cedulas from tot),
    'total_votos', (select votos from tot),
    'limite_votos', (select cedulas from tot) * (select max_por_categoria from cfg) * (select n from ncat),
    'sanidade_ok', (select votos from tot) <= (select cedulas from tot) * (select max_por_categoria from cfg) * (select n from ncat)
  )
$$;

create or replace function public.apurar(p_empresa text)
returns jsonb language plpgsql stable security definer
set search_path = public, extensions as $$
begin
  perform interno.exigir_admin();
  return interno.apuracao(interno.empresa_valida(p_empresa));
end $$;

create or replace function public.exportar_ata(p_empresa text)
returns jsonb language plpgsql stable security definer
set search_path = public, extensions as $$
declare emp text;
begin
  perform interno.exigir_admin();
  emp := interno.empresa_valida(p_empresa);
  return interno.apuracao(emp) || jsonb_build_object(
    'eleicao', (select to_jsonb(c) from config c where empresa = emp),
    'gerado_em_local', to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'),
    'gerado_por', (select email from auth.users where id = auth.uid()),
    'importacoes', (select coalesce(jsonb_agg(jsonb_build_object('feito_em', feito_em, 'tipo', tipo, 'novos', novos,
        'atualizados', atualizados, 'desligados', desligados, 'ignorados', ignorados) order by feito_em), '[]'::jsonb)
        from importacoes where empresa = emp and tipo in ('ativos', 'hipo', 'status', 'zeragem')));
end $$;

create or replace function public.painel_admin(p_empresa text)
returns jsonb language plpgsql stable security definer
set search_path = public, extensions as $$
declare emp text;
begin
  perform interno.exigir_admin();
  emp := interno.empresa_valida(p_empresa);
  return jsonb_build_object(
    'empresa', emp,
    'empresas', (select jsonb_agg(jsonb_build_object('codigo', e.codigo, 'nome', e.nome, 'status', c.status,
                   'aberta_agora', interno.votacao_aberta(e.codigo)) order by e.ordem)
                 from empresas e join config c on c.empresa = e.codigo),
    'config', (select to_jsonb(c) from config c where empresa = emp),
    'aberta_agora', interno.votacao_aberta(emp),
    'pessoas', (select count(*) from pessoas where empresa = emp),
    'ativos', (select count(*) from pessoas where empresa = emp and ativo),
    'elegiveis', (select count(*) from pessoas where empresa = emp and ativo and elegivel),
    'hipo', (select count(*) from pessoas where empresa = emp and ativo and elegivel and high_potential),
    'cedulas', (select count(*) from pessoas where empresa = emp and ja_votou),
    'por_unidade', (select coalesce(jsonb_agg(x order by x->>'unidade'), '[]'::jsonb) from (
        select jsonb_build_object('unidade', p.unidade, 'elegiveis', count(*),
          'admitidos_12m', count(*) filter (where p.data_admissao between c.vim_para_ficar_desde and c.data_corte),
          'hipo', count(*) filter (where p.high_potential)) x
        from pessoas p join config c on c.empresa = p.empresa
        where p.empresa = emp and p.ativo and p.elegivel group by p.unidade) s),
    'importacoes', (select coalesce(jsonb_agg(jsonb_build_object('feito_em', i.feito_em, 'tipo', i.tipo,
        'por', u.email, 'novos', i.novos, 'atualizados', i.atualizados, 'desligados', i.desligados,
        'ignorados', i.ignorados, 'detalhes', i.detalhes) order by i.feito_em desc), '[]'::jsonb)
        from (select * from importacoes where empresa = emp order by feito_em desc limit 50) i
        left join auth.users u on u.id = i.feito_por)
  );
end $$;

create or replace function public.zerar_votacao(p_empresa text, p_confirmacao text)
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions as $$
declare emp text; n int;
begin
  perform interno.exigir_admin();
  emp := interno.empresa_valida(p_empresa);
  if p_confirmacao is distinct from 'ZERAR VOTOS' then raise exception 'confirmação incorreta'; end if;
  if (select status from config where empresa = emp) = 'aberta' then raise exception 'encerre a votação antes de zerar'; end if;
  select count(*) into n from votos where empresa = emp;
  delete from votos where empresa = emp;
  delete from sessoes_voto s using pessoas p where p.id = s.pessoa_id and p.empresa = emp;
  update pessoas set ja_votou = false, votou_dia = null, tentativas_falhas = 0, bloqueado_ate = null
  where empresa = emp and (ja_votou or tentativas_falhas > 0 or bloqueado_ate is not null);
  update config set status = 'rascunho' where empresa = emp;
  insert into importacoes (empresa, feito_por, tipo, detalhes) values (emp, auth.uid(), 'zeragem', jsonb_build_object('votos_apagados', n));
  return jsonb_build_object('ok', true, 'votos_apagados', n);
end $$;

create or replace function public.anonimizar_base(p_empresa text, p_confirmacao text)
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions as $$
declare emp text; n int;
begin
  perform interno.exigir_admin();
  emp := interno.empresa_valida(p_empresa);
  if p_confirmacao is distinct from 'ANONIMIZAR' then raise exception 'confirmação incorreta'; end if;
  if (select status from config where empresa = emp) <> 'encerrada' then
    raise exception 'só é possível anonimizar com a votação encerrada';
  end if;
  update pessoas set cpf_hash = gen_random_uuid()::text, nasc_hash = '', matricula = null,
                     tentativas_falhas = 0, bloqueado_ate = null, votou_dia = null
  where empresa = emp;
  get diagnostics n = row_count;
  delete from sessoes_voto s using pessoas p where p.id = s.pessoa_id and p.empresa = emp;
  insert into importacoes (empresa, feito_por, tipo, detalhes) values (emp, auth.uid(), 'anonimizacao', jsonb_build_object('pessoas', n));
  return jsonb_build_object('ok', true, 'pessoas_anonimizadas', n);
end $$;

-- ---------------------------------------------------------------- permissões
revoke all on all functions in schema public from public;
revoke all on all functions in schema interno from public;
do $$ begin
  execute 'revoke all on all functions in schema public from anon, authenticated';
  execute 'revoke all on all functions in schema interno from anon, authenticated';
exception when undefined_object then null; end $$;

grant execute on function public.info_publica(text)                      to anon, authenticated;
grant execute on function public.iniciar_votacao(text, text, date)       to anon, authenticated;
grant execute on function public.registrar_cedula(uuid, jsonb)           to anon, authenticated;
grant execute on function public.sou_admin()                             to authenticated;
grant execute on function public.importar_ativos(text, jsonb, boolean)   to authenticated;
grant execute on function public.importar_hipo(text, jsonb, boolean)     to authenticated;
grant execute on function public.configurar(text, jsonb)                 to authenticated;
grant execute on function public.alterar_status(text, text)              to authenticated;
grant execute on function public.apurar(text)                            to authenticated;
grant execute on function public.exportar_ata(text)                      to authenticated;
grant execute on function public.painel_admin(text)                      to authenticated;
grant execute on function public.zerar_votacao(text, text)               to authenticated;
grant execute on function public.anonimizar_base(text, text)             to authenticated;

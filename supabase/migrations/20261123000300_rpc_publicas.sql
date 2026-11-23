-- =====================================================================
-- RPCs públicas (anon): info_publica, iniciar_votacao, registrar_cedula
-- Nenhum RAISE/log contém CPF, nascimento ou candidato escolhido.
-- =====================================================================

create or replace function public.info_publica()
returns jsonb language sql stable security definer
set search_path = public, extensions as $$
  select jsonb_build_object(
    'nome_eleicao', c.nome_eleicao,
    'status', c.status,
    'aberta_agora', interno.votacao_aberta(),
    'inicio', c.inicio,
    'fim', c.fim,
    'data_corte', c.data_corte,
    'max_por_categoria', c.max_por_categoria,
    'categorias', (select coalesce(jsonb_agg(jsonb_build_object(
        'codigo', k.codigo, 'nome', k.nome, 'descricao', k.descricao, 'escopo', k.escopo
      ) order by k.ordem), '[]'::jsonb) from categorias k))
  from config c where c.id = 1
$$;

-- ---------------------------------------------------------------------
create or replace function public.iniciar_votacao(p_cpf text, p_nascimento date)
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions as $$
declare
  generica constant text := 'Não foi possível validar seus dados ou seu voto já foi registrado. Procure o RH.';
  d text;
  v pessoas;
  tok uuid;
  exp timestamptz := now() + interval '20 minutes';
  res jsonb;
begin
  if not coalesce(interno.votacao_aberta(), false) then
    return jsonb_build_object('ok', false, 'codigo', 'fechada',
      'mensagem', 'A votação não está aberta no momento.');
  end if;

  d := regexp_replace(coalesce(p_cpf, ''), '\D', '', 'g');
  if not interno.cpf_valido(d) then
    return jsonb_build_object('ok', false, 'codigo', 'cpf_invalido',
      'mensagem', 'CPF inválido. Confira os números digitados.');
  end if;

  select * into v from pessoas where cpf_hash = interno.hmac(d) for update;
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

  -- Payload enxuto: cada candidato aparece 1 vez em "pessoas" ([id, nome, setor]);
  -- as categorias trazem só os índices dessa lista.
  with cand as (
    select * from interno.candidatos(v.id)
  ), ppl as (
    select p.id, p.nome, coalesce(p.setor, '') as setor,
           (row_number() over (order by interno.chave(p.nome), p.id) - 1)::int as idx
    from pessoas p
    where p.id in (select candidato_id from cand)
  )
  select jsonb_build_object(
    'ok', true,
    'token', tok,
    'expira_em', exp,
    'primeiro_nome', initcap(lower(split_part(btrim(v.nome), ' ', 1))),
    'unidade', v.unidade,
    'max_por_categoria', (select max_por_categoria from config where id = 1),
    'pessoas', coalesce((select jsonb_agg(jsonb_build_array(ppl.id, ppl.nome, ppl.setor) order by ppl.idx) from ppl), '[]'::jsonb),
    'categorias', (
      select jsonb_agg(jsonb_build_object(
        'codigo', k.codigo, 'nome', k.nome, 'descricao', k.descricao, 'escopo', k.escopo,
        'candidatos', coalesce((
          select jsonb_agg(ppl.idx order by ppl.idx)
          from cand join ppl on ppl.id = cand.candidato_id
          where cand.categoria = k.codigo), '[]'::jsonb)
      ) order by k.ordem)
      from categorias k)
  ) into res;

  return res;
end $$;

-- ---------------------------------------------------------------------
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
    return jsonb_build_object('ok', false, 'codigo', 'sessao_expirada',
      'mensagem', 'Sua sessão expirou. Identifique-se novamente.');
  end if;

  -- Trava o eleitor: duas abas / duplo clique serializam aqui.
  select * into v from pessoas where id = s.pessoa_id for update;

  if not coalesce(interno.votacao_aberta(), false) then
    return jsonb_build_object('ok', false, 'codigo', 'fechada',
      'mensagem', 'A votação não está aberta no momento.');
  end if;

  if v.id is null or v.ja_votou or not v.ativo or not v.elegivel then
    delete from sessoes_voto where pessoa_id = s.pessoa_id;
    return jsonb_build_object('ok', false, 'codigo', 'recusado', 'mensagem', generica);
  end if;

  select max_por_categoria into maxc from config where id = 1;

  -- Formato
  if p_escolhas is null or jsonb_typeof(p_escolhas) <> 'object' then
    return jsonb_build_object('ok', false, 'codigo', 'cedula_invalida', 'mensagem', invalida);
  end if;
  if exists (select 1 from jsonb_object_keys(p_escolhas) k
             where k not in (select codigo from categorias)) then
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

  -- Repetidos na mesma categoria
  if exists (select 1 from interno.escolhas(p_escolhas) group by categoria, candidato_id having count(*) > 1) then
    return jsonb_build_object('ok', false, 'codigo', 'cedula_invalida', 'mensagem', invalida);
  end if;

  -- Candidato permitido para este eleitor nesta categoria (unidade, regra, ativo, auto-voto)
  if exists (select 1 from interno.escolhas(p_escolhas) e
             where not exists (select 1 from interno.candidatos(v.id) c
                               where c.categoria = e.categoria and c.candidato_id = e.candidato_id)) then
    return jsonb_build_object('ok', false, 'codigo', 'cedula_invalida', 'mensagem', invalida);
  end if;

  select count(*) into n from interno.escolhas(p_escolhas);
  if n < 1 then
    return jsonb_build_object('ok', false, 'codigo', 'cedula_vazia',
      'mensagem', 'Escolha ao menos uma pessoa antes de confirmar.');
  end if;

  -- Grava em ordem aleatória, sem nada que aponte para o eleitor.
  insert into votos (categoria, candidato_id, unidade_apuracao)
  select e.categoria, e.candidato_id,
         case when k.escopo = 'unidade' then p.unidade else 'GERAL' end
  from interno.escolhas(p_escolhas) e
  join categorias k on k.codigo = e.categoria
  join pessoas p on p.id = e.candidato_id
  order by random();

  update pessoas
     set ja_votou = true,
         votou_dia = (now() at time zone 'America/Sao_Paulo')::date
   where id = v.id;
  delete from sessoes_voto where pessoa_id = v.id;

  return jsonb_build_object('ok', true,
    'protocolo', upper(substr(encode(gen_random_bytes(5), 'hex'), 1, 5) || '-' || substr(encode(gen_random_bytes(5), 'hex'), 1, 5)));
end $$;

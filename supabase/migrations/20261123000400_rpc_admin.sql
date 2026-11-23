-- =====================================================================
-- RPCs de admin (authenticated + presente em admins)
-- Admins só veem AGREGADOS de voto. Nenhuma função devolve CPF.
-- =====================================================================

create or replace function interno.data_iso(p text)
returns date language plpgsql immutable
set search_path = '' as $$
begin
  if p is null or p !~ '^\d{4}-\d{2}-\d{2}$' then return null; end if;
  return p::date;
exception when others then
  return null;
end $$;
revoke all on function interno.data_iso(text) from public;

-- ---------------------------------------------------------------------
create or replace function public.sou_admin()
returns boolean language sql stable security definer
set search_path = public, extensions as $$
  select auth.uid() is not null and exists (select 1 from admins where user_id = auth.uid())
$$;

-- ---------------------------------------------------------------------
-- Importa a planilha de ativos. p_simular = true devolve só a prévia.
create or replace function public.importar_ativos(p_linhas jsonb, p_simular boolean default true)
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions as $$
declare
  cfg config;
  pep text;
  res jsonb;
  n_ativos_antes int;
begin
  perform interno.exigir_admin();
  if p_linhas is null or jsonb_typeof(p_linhas) <> 'array' or jsonb_array_length(p_linhas) = 0 then
    raise exception 'planilha vazia';
  end if;
  if jsonb_array_length(p_linhas) > 20000 then
    raise exception 'planilha grande demais';
  end if;
  select * into cfg from config where id = 1;
  pep := interno.pepper();
  select count(*) into n_ativos_antes from pessoas where ativo;

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
    null::text    as motivo_ignorado,
    null::text    as cpf_hash,
    null::text    as nasc_hash,
    null::text    as unidade,
    null::text    as motivo_inelegivel,
    null::text    as vinculo,
    false         as desligado,
    null::text    as acao
  from jsonb_array_elements(p_linhas) with ordinality t(l, ord);

  update _imp set motivo_ignorado = case
      when not interno.cpf_valido(cpf) then 'CPF inválido'
      when nome is null then 'Sem nome'
      when nasc is null then 'Data de nascimento inválida'
      when adm is null then 'Data de admissão inválida'
    end
  where true;   -- o Supabase (pg_safeupdate) recusa UPDATE sem WHERE

  update _imp i set motivo_ignorado = 'CPF repetido na planilha'
  from (select linha, row_number() over (partition by cpf order by linha) rn
        from _imp where motivo_ignorado is null) d
  where d.linha = i.linha and d.rn > 1;

  update _imp set
    cpf_hash  = encode(hmac(convert_to(cpf, 'UTF8'), convert_to(pep, 'UTF8'), 'sha256'), 'hex'),
    nasc_hash = encode(hmac(convert_to(cpf || '|' || to_char(nasc, 'YYYY-MM-DD'), 'UTF8'), convert_to(pep, 'UTF8'), 'sha256'), 'hex'),
    unidade   = interno.normalizar_unidade(unidade_original),
    desligado = interno.situacao_desligado(situacao),
    motivo_inelegivel = coalesce(
      interno.motivo_vinculo(vinculo_planilha, cargo),
      -- Aposentados por invalidez (centro de custo "ApInvalidez") não participam.
      case when interno.chave(setor) ~ 'apinvalidez|aposentad'
             or interno.chave(cargo) ~ 'aposentad' then 'Aposentadoria por invalidez' end,
      case when adm > cfg.data_corte then 'Admitido após ' || to_char(cfg.data_corte, 'DD/MM/YYYY') end),
    vinculo = coalesce(vinculo_planilha,
      case when interno.motivo_vinculo(null, cargo) like 'Aprendiz%' then 'Aprendiz'
           when interno.motivo_vinculo(null, cargo) like 'Estagi%' then 'Estagiário'
           else 'Efetivo (CLT)' end)
  where motivo_ignorado is null;

  -- O CPF em texto não é mais necessário.
  update _imp set cpf = null where true;

  update _imp i set acao = case
      when i.desligado then 'desligado_planilha'
      when p.id is null then 'novo'
      when not p.ativo then 'reativado'
      else 'atualizado' end
  from _imp i2
  left join pessoas p on p.cpf_hash = i2.cpf_hash
  where i2.linha = i.linha and i.motivo_ignorado is null;

  with desl as (
    select p.id, p.nome, p.unidade from pessoas p
    where p.ativo and not exists (
      select 1 from _imp i where i.cpf_hash = p.cpf_hash and i.motivo_ignorado is null and not i.desligado)
  )
  select jsonb_build_object(
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

  if p_simular then
    return res;
  end if;

  insert into pessoas (cpf_hash, nasc_hash, nome, matricula, cargo, setor, unidade_original, unidade,
                       data_admissao, vinculo, elegivel, motivo_inelegivel)
  select cpf_hash, nasc_hash, nome, matricula, cargo, setor, unidade_original, unidade,
         adm, vinculo, motivo_inelegivel is null, motivo_inelegivel
  from _imp where acao = 'novo';

  update pessoas p set
    nasc_hash = i.nasc_hash, nome = i.nome, matricula = i.matricula, cargo = i.cargo, setor = i.setor,
    unidade_original = i.unidade_original, unidade = i.unidade, data_admissao = i.adm,
    vinculo = i.vinculo, elegivel = i.motivo_inelegivel is null, motivo_inelegivel = i.motivo_inelegivel,
    ativo = true, desligado_em = null
  from _imp i
  where i.acao in ('atualizado', 'reativado') and p.cpf_hash = i.cpf_hash;

  -- Desligamento lógico: nada é apagado. Votos recebidos viram "anulados" na apuração.
  update pessoas p set ativo = false, desligado_em = now()
  where p.ativo and not exists (
    select 1 from _imp i where i.cpf_hash = p.cpf_hash and i.motivo_ignorado is null and not i.desligado);

  insert into importacoes (feito_por, tipo, novos, atualizados, desligados, ignorados, detalhes)
  values (auth.uid(), 'ativos',
    (res->>'novos')::int, (res->>'atualizados')::int + (res->>'reativados')::int,
    (res->>'desligados')::int, (res->>'ignorados')::int,
    jsonb_build_object('total_linhas', res->'total_linhas', 'reativados', res->'reativados',
      'elegiveis', res->'elegiveis', 'inelegiveis', res->'inelegiveis',
      'motivos_inelegiveis', res->'motivos_inelegiveis', 'por_unidade', res->'por_unidade'));

  return res;
end $$;

-- ---------------------------------------------------------------------
-- Lista do programa High Potential 2026 (por CPF ou matrícula).
create or replace function public.importar_hipo(p_linhas jsonb, p_simular boolean default true)
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions as $$
declare
  pep text;
  res jsonb;
begin
  perform interno.exigir_admin();
  if p_linhas is null or jsonb_typeof(p_linhas) <> 'array' or jsonb_array_length(p_linhas) = 0 then
    raise exception 'lista vazia';
  end if;
  pep := interno.pepper();

  drop table if exists pg_temp._hipo;
  create temp table _hipo on commit drop as
  select t.ord::int as linha,
         interno.cpf_digitos(t.l->>'cpf') as cpf,
         nullif(btrim(t.l->>'matricula'), '') as matricula,
         nullif(btrim(t.l->>'nome'), '') as nome,
         null::uuid as pessoa_id,
         null::text as problema
  from jsonb_array_elements(p_linhas) with ordinality t(l, ord);

  -- 1) por CPF
  update _hipo h set pessoa_id = p.id
  from pessoas p
  where interno.cpf_valido(h.cpf)
    and p.cpf_hash = encode(hmac(convert_to(h.cpf, 'UTF8'), convert_to(pep, 'UTF8'), 'sha256'), 'hex');
  update _hipo set cpf = null where true;

  -- 2) por matrícula (só se for única entre os ativos)
  update _hipo h set pessoa_id = m.id
  from (select matricula, min(id::text)::uuid id, count(*) n from pessoas where ativo and matricula is not null group by matricula) m
  where h.pessoa_id is null and h.matricula is not null and m.matricula = h.matricula and m.n = 1;

  update _hipo h set problema = 'Matrícula repetida na base: informe o CPF'
  where h.pessoa_id is null and h.matricula is not null
    and (select count(*) from pessoas p where p.ativo and p.matricula = h.matricula) > 1;
  update _hipo set problema = 'Não encontrado na base de ativos' where pessoa_id is null and problema is null;

  select jsonb_build_object(
    'simulado', p_simular,
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

  update pessoas set high_potential = false where high_potential;
  update pessoas set high_potential = true where id in (select pessoa_id from _hipo where pessoa_id is not null);

  insert into importacoes (feito_por, tipo, novos, atualizados, desligados, ignorados, detalhes)
  values (auth.uid(), 'hipo', (res->>'encontrados')::int, 0, 0,
          jsonb_array_length(res->'lista_nao_encontrados'),
          jsonb_build_object('total_linhas', res->'total_linhas', 'elegiveis', res->'elegiveis',
                             'nao_elegiveis', jsonb_array_length(res->'lista_nao_elegiveis')));
  return res;
end $$;

-- ---------------------------------------------------------------------
create or replace function public.configurar(p jsonb)
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions as $$
declare c config;
begin
  perform interno.exigir_admin();
  select * into c from config where id = 1 for update;
  if c.status = 'aberta' and p ? 'permitir_auto_voto'
     and (p->>'permitir_auto_voto')::boolean is distinct from c.permitir_auto_voto then
    raise exception 'não é possível mudar a regra de auto-voto com a votação aberta';
  end if;
  update config set
    nome_eleicao = coalesce(nullif(btrim(p->>'nome_eleicao'), ''), nome_eleicao),
    inicio = case when p ? 'inicio' then (p->>'inicio')::timestamptz else inicio end,
    fim    = case when p ? 'fim' then (p->>'fim')::timestamptz else fim end,
    permitir_auto_voto = coalesce((p->>'permitir_auto_voto')::boolean, permitir_auto_voto)
  where id = 1;
  insert into importacoes (feito_por, tipo, detalhes)
  values (auth.uid(), 'config', (select to_jsonb(x) - 'id' from config x where id = 1));
  return (select to_jsonb(x) from config x where id = 1);
end $$;

create or replace function public.alterar_status(p_status text)
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions as $$
declare c config;
begin
  perform interno.exigir_admin();
  select * into c from config where id = 1 for update;
  if not ((c.status = 'rascunho' and p_status = 'aberta')
       or (c.status = 'aberta' and p_status = 'encerrada')
       or (c.status = 'encerrada' and p_status = 'aberta')) then
    raise exception 'transição de status não permitida: % → %', c.status, p_status;
  end if;
  if p_status = 'aberta' then
    if c.inicio is null or c.fim is null then
      raise exception 'defina início e fim antes de abrir';
    end if;
    if not exists (select 1 from pessoas where ativo and elegivel) then
      raise exception 'importe a base de ativos antes de abrir';
    end if;
  end if;
  update config set status = p_status where id = 1;
  insert into importacoes (feito_por, tipo, detalhes)
  values (auth.uid(), 'status', jsonb_build_object('de', c.status, 'para', p_status));
  return (select to_jsonb(x) from config x where id = 1);
end $$;

-- ---------------------------------------------------------------------
-- Apuração (sempre na hora da consulta; desligados viram "anulados").
create or replace function interno.apuracao()
returns jsonb language sql stable
set search_path = '' as $$
  with cfg as (select * from public.config where id = 1),
  ncat as (select count(*)::int n from public.categorias),
  grupos as (
    select k.codigo as categoria, k.nome as categoria_nome, k.ordem, u.unidade as unidade_apuracao
    from public.categorias k
    join (select distinct unidade from public.pessoas where ativo and elegivel) u on k.escopo = 'unidade'
    union
    select k.codigo, k.nome, k.ordem, 'GERAL' from public.categorias k where k.escopo = 'geral'
    union
    select distinct v.categoria, k.nome, k.ordem, v.unidade_apuracao
    from public.votos v join public.categorias k on k.codigo = v.categoria
  ),
  cont as (
    select categoria, unidade_apuracao, candidato_id, count(*)::int n
    from public.votos group by 1, 2, 3
  ),
  rk as (
    select c.categoria, c.unidade_apuracao, c.candidato_id, c.n, p.nome, p.setor,
           rank() over (partition by c.categoria, c.unidade_apuracao order by c.n desc)::int pos
    from cont c join public.pessoas p on p.id = c.candidato_id
    where p.ativo
  ),
  anul as (
    select c.categoria, c.unidade_apuracao, sum(c.n)::int anulados, count(*)::int candidatos
    from cont c join public.pessoas p on p.id = c.candidato_id
    where not p.ativo group by 1, 2
  ),
  part as (
    select unidade, count(*)::int elegiveis, count(*) filter (where ja_votou)::int votaram
    from public.pessoas where ativo and elegivel group by unidade
  ),
  tot as (
    select (select count(*)::int from public.pessoas where ja_votou) cedulas,
           (select count(*)::int from public.votos) votos
  )
  select jsonb_build_object(
    'gerado_em', now(),
    'status', (select status from cfg),
    'grupos', (select coalesce(jsonb_agg(jsonb_build_object(
        'categoria', g.categoria,
        'categoria_nome', g.categoria_nome,
        'unidade', g.unidade_apuracao,
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
        from (select votou_dia, count(*)::int n from public.pessoas where ja_votou and votou_dia is not null group by 1) d),
    'cedulas', (select cedulas from tot),
    'total_votos', (select votos from tot),
    'limite_votos', (select cedulas from tot) * (select max_por_categoria from cfg) * (select n from ncat),
    'sanidade_ok', (select votos from tot) <= (select cedulas from tot) * (select max_por_categoria from cfg) * (select n from ncat)
  )
$$;
revoke all on function interno.apuracao() from public;

create or replace function public.apurar()
returns jsonb language plpgsql stable security definer
set search_path = public, extensions as $$
begin
  perform interno.exigir_admin();
  return interno.apuracao();
end $$;

create or replace function public.exportar_ata()
returns jsonb language plpgsql stable security definer
set search_path = public, extensions as $$
begin
  perform interno.exigir_admin();
  return interno.apuracao() || jsonb_build_object(
    'eleicao', (select to_jsonb(c) - 'id' from config c where id = 1),
    'gerado_em_local', to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'),
    'gerado_por', (select email from auth.users where id = auth.uid()),
    'importacoes', (select coalesce(jsonb_agg(jsonb_build_object('feito_em', feito_em, 'tipo', tipo, 'novos', novos,
        'atualizados', atualizados, 'desligados', desligados, 'ignorados', ignorados) order by feito_em), '[]'::jsonb)
        from importacoes where tipo in ('ativos', 'hipo', 'status', 'zeragem')));
end $$;

-- ---------------------------------------------------------------------
create or replace function public.painel_admin()
returns jsonb language plpgsql stable security definer
set search_path = public, extensions as $$
begin
  perform interno.exigir_admin();
  return jsonb_build_object(
    'config', (select to_jsonb(c) from config c where id = 1),
    'aberta_agora', interno.votacao_aberta(),
    'pessoas', (select count(*) from pessoas),
    'ativos', (select count(*) from pessoas where ativo),
    'elegiveis', (select count(*) from pessoas where ativo and elegivel),
    'hipo', (select count(*) from pessoas where ativo and elegivel and high_potential),
    'cedulas', (select count(*) from pessoas where ja_votou),
    'por_unidade', (select coalesce(jsonb_agg(x order by x->>'unidade'), '[]'::jsonb) from (
        select jsonb_build_object('unidade', unidade, 'elegiveis', count(*),
          'admitidos_12m', count(*) filter (where data_admissao between (select vim_para_ficar_desde from config) and (select data_corte from config)),
          'hipo', count(*) filter (where high_potential)) x
        from pessoas where ativo and elegivel group by unidade) s),
    'importacoes', (select coalesce(jsonb_agg(jsonb_build_object('feito_em', i.feito_em, 'tipo', i.tipo,
        'por', u.email, 'novos', i.novos, 'atualizados', i.atualizados, 'desligados', i.desligados,
        'ignorados', i.ignorados, 'detalhes', i.detalhes) order by i.feito_em desc), '[]'::jsonb)
        from (select * from importacoes order by feito_em desc limit 50) i left join auth.users u on u.id = i.feito_por)
  );
end $$;

-- ---------------------------------------------------------------------
-- Piloto: zera votos e ja_votou (nunca com a votação aberta).
create or replace function public.zerar_votacao(p_confirmacao text)
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions as $$
declare n int;
begin
  perform interno.exigir_admin();
  if p_confirmacao is distinct from 'ZERAR VOTOS' then raise exception 'confirmação incorreta'; end if;
  if (select status from config where id = 1) = 'aberta' then
    raise exception 'encerre a votação antes de zerar';
  end if;
  select count(*) into n from votos;
  delete from votos where true;
  delete from sessoes_voto where true;
  update pessoas set ja_votou = false, votou_dia = null, tentativas_falhas = 0, bloqueado_ate = null
  where ja_votou or tentativas_falhas > 0 or bloqueado_ate is not null;
  update config set status = 'rascunho' where id = 1;
  insert into importacoes (feito_por, tipo, detalhes)
  values (auth.uid(), 'zeragem', jsonb_build_object('votos_apagados', n));
  return jsonb_build_object('ok', true, 'votos_apagados', n);
end $$;

-- Encerramento (LGPD): troca os hashes por valores aleatórios. Só com a votação encerrada.
create or replace function public.anonimizar_base(p_confirmacao text)
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions as $$
declare n int;
begin
  perform interno.exigir_admin();
  if p_confirmacao is distinct from 'ANONIMIZAR' then raise exception 'confirmação incorreta'; end if;
  if (select status from config where id = 1) <> 'encerrada' then
    raise exception 'só é possível anonimizar com a votação encerrada';
  end if;
  update pessoas set cpf_hash = gen_random_uuid()::text, nasc_hash = '', matricula = null,
                     tentativas_falhas = 0, bloqueado_ate = null, votou_dia = null
  where true;
  get diagnostics n = row_count;
  delete from sessoes_voto where true;
  insert into importacoes (feito_por, tipo, detalhes)
  values (auth.uid(), 'anonimizacao', jsonb_build_object('pessoas', n));
  return jsonb_build_object('ok', true, 'pessoas_anonimizadas', n);
end $$;

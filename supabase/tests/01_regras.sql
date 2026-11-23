-- =====================================================================
-- Testes de aceite (banco). Roda tudo numa transação e desfaz no fim.
-- Dados 100% sintéticos. Uso: colar no SQL Editor / execute_sql, ou
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/01_regras.sql
-- Cada bloco imprime 'OK <n>' via a tabela de resultados no final.
-- =====================================================================
begin;

create temp table t_ok (n text primary key, descr text);
create temp table t_ctx (k text primary key, v text);

create function pg_temp.cpf(n int) returns text language plpgsql as $$
declare b text := lpad((123000000 + n * 7919)::text, 9, '0'); s int := 0; d int; i int;
begin
  for i in 1..9 loop s := s + substr(b, i, 1)::int * (11 - i); end loop;
  d := (s * 10) % 11; if d = 10 then d := 0; end if; b := b || d; s := 0;
  for i in 1..10 loop s := s + substr(b, i, 1)::int * (12 - i); end loop;
  d := (s * 10) % 11; if d = 10 then d := 0; end if;
  return b || d;
end $$;

create function pg_temp.como_admin() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select v from t_ctx where k = 'admin'), 'role', 'authenticated')::text, true);
end $$;

create function pg_temp.como_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
end $$;

create function pg_temp.pid(p_nome text) returns uuid language sql as $$
  select id from public.pessoas where nome = p_nome
$$;

-- Planilha sintética
create function pg_temp.planilha(sem text default null) returns jsonb language sql as $$
  select jsonb_agg(l) from (values
    (1,  'ANA ALVES',      '1990-01-10', '2020-01-01', 'WAP - ANTONIO SINGER', 'ANALISTA',       null),
    (2,  'BRUNO BRAGA',    '1991-02-11', '2026-03-01', 'HOME OFFICE',          'ANALISTA',       null),
    (3,  'CARLA CASTRO',   '1992-03-12', '2025-11-30', 'WAP EXTERNO',          'VENDEDOR',       null),
    (4,  'DIEGO DIAS',     '1993-04-13', '2025-12-01', 'WAP - AFONSO PENA',    'OPERADOR',       null),
    (5,  'EVA ESTEVES',    '1994-05-14', '2026-06-01', 'WAP - SERRA',          'OPERADOR',       null),
    (6,  'FABIO FARIAS',   '1995-06-15', '2019-01-01', 'WAP - SERRA',          'SUPERVISOR',     null),
    (7,  'GIL GOMES',      '1996-07-16', '2018-01-01', 'WAP 103 - FORTALEZA',  'OPERADOR',       null),
    (8,  'HUGO HENRIQUES', '2008-08-17', '2026-02-01', 'WAP - ANTONIO SINGER', 'JOVEM APRENDIZ', null),
    (9,  'IRIS ISIDORO',   '1997-09-18', '2026-12-01', 'WAP - ANTONIO SINGER', 'ANALISTA',       null),
    (10, 'JOAO JARDIM',    '1998-10-19', '2026-01-01', 'Antônio Singer/ Matriz','OPERADOR',      'Temporário'),
    (11, 'KARINA KLEIN',   '1980-01-01', '2015-01-01', 'Matriz',               'GERENTE',        null),
    (12, 'LUCAS LIMA',     '1980-01-02', '2015-01-01', 'Matriz',               'ANALISTA',       null),
    (13, 'MARIA MOURA',    '1980-01-03', '2015-01-01', 'Matriz',               'ANALISTA',       null),
    (14, 'NINA NUNES',     '1980-01-04', '2015-01-01', 'Matriz',               'ANALISTA',       null),
    (15, 'OTAVIO OLIVEIRA','1960-01-05', '2010-01-01', 'WAP - SERRA',          'OPERADOR',       null)
  ) as t(n, nome, nasc, adm, unidade, cargo, vinculo)
  cross join lateral (select jsonb_build_object(
      'cpf', pg_temp.cpf(n), 'nome', nome, 'nascimento', nasc, 'admissao', adm,
      'unidade', unidade, 'cargo', cargo, 'setor', case when n = 15 then 'ApInvalidez' else 'Setor ' || n end, 'matricula', (1000 + n)::text,
      'vinculo', vinculo) l) x
  where sem is null or nome <> sem
$$;

-- Admin sintético
do $$
declare uid uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email)
  values (uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'admin-teste@example.invalid');
  insert into public.admins (user_id) values (uid);
  insert into t_ctx values ('admin', uid::text);
end $$;

-- Base vazia para o teste
delete from public.votos; delete from public.sessoes_voto; delete from public.pessoas;
update public.config set inicio = now() - interval '1 day', fim = now() + interval '1 day',
  status = 'aberta', permitir_auto_voto = false, max_por_categoria = 3 where id = 1;

-- ---------------------------------------------------------------- import
do $$
declare r jsonb;
begin
  perform pg_temp.como_admin();
  r := public.importar_ativos(pg_temp.planilha(), true);
  assert (r->>'novos')::int = 15, 'simulação: novos=' || (r->>'novos');
  assert not exists (select 1 from public.pessoas), 'simulação gravou dados';
  r := public.importar_ativos(pg_temp.planilha(), false);
  assert (select count(*) from public.pessoas) = 15, 'import não gravou';
  assert (r->>'inelegiveis')::int = 4, 'inelegíveis esperado 4 (aprendiz, após corte, temporário, ApInvalidez): ' || (r->>'inelegiveis');
  assert (select motivo_inelegivel from public.pessoas where nome = 'OTAVIO OLIVEIRA') = 'Aposentadoria por invalidez', 'ApInvalidez elegível';
  r := public.importar_hipo(jsonb_build_array(
         jsonb_build_object('cpf', pg_temp.cpf(1)),
         jsonb_build_object('matricula', '1006'),
         jsonb_build_object('cpf', pg_temp.cpf(8))), false);
  assert (r->>'encontrados')::int = 3, 'hipo encontrados';
  assert jsonb_array_length(r->'lista_nao_elegiveis') = 1, 'hipo deve avisar o aprendiz';
  insert into t_ok values ('import', 'importação, simulação e HiPo');
end $$;

-- ---------------------------------------------------------------- 6 unidades
do $$
begin
  assert interno.normalizar_unidade('Home Office') = 'Matriz';
  assert interno.normalizar_unidade('  externos ') = 'Matriz';
  assert interno.normalizar_unidade('WAP EXTERNO') = 'Matriz';
  assert interno.normalizar_unidade('Afonso   Pena') = 'Matriz';
  assert interno.normalizar_unidade('ANTÔNIO SINGER') = 'Matriz';
  assert interno.normalizar_unidade('Antonio Singer/ Matriz') = 'Matriz';
  assert interno.normalizar_unidade('Antonio Singer/Matriz') = 'Matriz';
  assert interno.normalizar_unidade('MATRIZ') = 'Matriz';
  assert interno.normalizar_unidade('WAP - SERRA') = 'Serra';
  assert interno.normalizar_unidade('WAP 103 - FORTALEZA') = 'Fortaleza';
  assert interno.normalizar_unidade('wap - linhares') = 'Linhares';
  assert (select unidade from public.pessoas where nome = 'JOAO JARDIM') = 'Matriz';
  insert into t_ok values ('6a', 'normalização de unidades');
end $$;

-- ---------------------------------------------------------------- 1, 2
do $$
declare r jsonb; g text := 'Não foi possível validar seus dados ou seu voto já foi registrado. Procure o RH.';
begin
  perform pg_temp.como_anon();
  r := public.iniciar_votacao('123.456.789-00', '1990-01-10');
  assert r->>'codigo' = 'cpf_invalido', '1: CPF inválido aceito';
  assert not interno.cpf_valido('11111111111');
  insert into t_ok values ('1', 'CPF inválido recusado no banco');

  r := public.iniciar_votacao(pg_temp.cpf(999), '1990-01-10');            -- fora da base
  assert r->>'mensagem' = g, '2: fora da base';
  r := public.iniciar_votacao(pg_temp.cpf(2), '2000-01-01');              -- nascimento errado
  assert r->>'mensagem' = g, '2: nascimento errado';
  r := public.iniciar_votacao(pg_temp.cpf(8), '2008-08-17');              -- aprendiz
  assert r->>'mensagem' = g, '2: aprendiz';
  r := public.iniciar_votacao(pg_temp.cpf(9), '1997-09-18');              -- admitido após corte
  assert r->>'mensagem' = g, '2: após corte';
  r := public.iniciar_votacao(pg_temp.cpf(10), '1998-10-19');             -- temporário
  assert r->>'mensagem' = g, '2: temporário';
  insert into t_ok values ('2', 'mesma mensagem genérica para todas as recusas de identidade');
end $$;

-- ---------------------------------------------------------------- 3 bloqueio
do $$
declare r jsonb; i int;
begin
  perform pg_temp.como_anon();
  update public.pessoas set tentativas_falhas = 0 where nome = 'BRUNO BRAGA';
  for i in 1..5 loop
    r := public.iniciar_votacao(pg_temp.cpf(2), '2000-01-01');
  end loop;
  assert (select bloqueado_ate > now() + interval '14 minutes' from public.pessoas where nome = 'BRUNO BRAGA'), '3: não bloqueou';
  r := public.iniciar_votacao(pg_temp.cpf(2), '1991-02-11');               -- data certa, mas bloqueado
  assert (r->>'ok')::boolean is false, '3: bloqueado conseguiu entrar';
  update public.pessoas set bloqueado_ate = null where nome = 'BRUNO BRAGA';
  insert into t_ok values ('3', '5 falhas bloqueiam por 15 min');
end $$;

-- ---------------------------------------------------------------- 6b, 7, 8, 10 (listas)
do $$
declare r jsonb; nomes jsonb; cat jsonb; lst text[];
begin
  perform pg_temp.como_anon();
  -- CPF com máscara
  r :=public.iniciar_votacao(substr(pg_temp.cpf(1),1,3)||'.'||substr(pg_temp.cpf(1),4,3)||'.'||substr(pg_temp.cpf(1),7,3)||'-'||substr(pg_temp.cpf(1),10,2), '1990-01-10');
  assert (r->>'ok')::boolean, 'Ana deveria entrar: ' || r::text;
  assert r->>'unidade' = 'Matriz';
  insert into t_ctx values ('tok_ana', r->>'token');
  nomes := r->'pessoas';

  for cat in select * from jsonb_array_elements(r->'categorias') loop
    select array_agg(nomes->(i::int)->>1 order by nomes->(i::int)->>1) into lst from jsonb_array_elements_text(cat->'candidatos') i;
    lst := coalesce(lst, '{}');
    if cat->>'codigo' = 'VIM_PARA_FICAR' then
      assert lst = array['BRUNO BRAGA', 'DIEGO DIAS'], '7: VIM = ' || lst::text;
    elsif cat->>'codigo' in ('LIDERANCA', 'PATROCINADOR') then
      assert lst = array['BRUNO BRAGA','CARLA CASTRO','DIEGO DIAS','KARINA KLEIN','LUCAS LIMA','MARIA MOURA','NINA NUNES'],
        '6b: ' || (cat->>'codigo') || ' = ' || lst::text;
    elsif cat->>'codigo' = 'OURO' then
      assert 'EVA ESTEVES' = any(lst) and 'GIL GOMES' = any(lst), '8: OURO sem outras unidades';
      assert not ('ANA ALVES' = any(lst)), '10: auto-voto na lista';
      assert not ('HUGO HENRIQUES' = any(lst)) and not ('IRIS ISIDORO' = any(lst)) and not ('JOAO JARDIM' = any(lst)), '8: inelegível em OURO';
      assert array_length(lst, 1) = 10, '8: OURO deveria ter 10, tem ' || array_length(lst, 1);
    elsif cat->>'codigo' = 'HIPO' then
      assert lst = array['FABIO FARIAS'], '8: HIPO = ' || lst::text;  -- Ana é HiPo mas é a eleitora; Hugo é inelegível
    end if;
  end loop;
  insert into t_ok values ('6b', 'eleitor da Matriz vê só a Matriz nas categorias por unidade');
  insert into t_ok values ('7', 'Vim para ficar só com admitidos entre 01/12/2025 e 30/11/2026');
  insert into t_ok values ('8', 'OURO com todas as unidades; HIPO só com a lista');
end $$;

-- ---------------------------------------------------------------- 9, 10 (payload manipulado)
do $$
declare r jsonb; tok uuid := (select v::uuid from t_ctx where k = 'tok_ana');
begin
  perform pg_temp.como_anon();
  r := public.registrar_cedula(tok, jsonb_build_object('LIDERANCA', jsonb_build_array(
        pg_temp.pid('BRUNO BRAGA'), pg_temp.pid('CARLA CASTRO'), pg_temp.pid('DIEGO DIAS'), pg_temp.pid('KARINA KLEIN'))));
  assert r->>'codigo' = 'cedula_invalida', '9: 4 escolhas aceitas';
  r := public.registrar_cedula(tok, jsonb_build_object('LIDERANCA', jsonb_build_array(pg_temp.pid('BRUNO BRAGA'), pg_temp.pid('BRUNO BRAGA'))));
  assert r->>'codigo' = 'cedula_invalida', '9: repetido aceito';
  r := public.registrar_cedula(tok, jsonb_build_object('LIDERANCA', jsonb_build_array(pg_temp.pid('EVA ESTEVES'))));
  assert r->>'codigo' = 'cedula_invalida', '9: outra unidade aceita';
  r := public.registrar_cedula(tok, jsonb_build_object('VIM_PARA_FICAR', jsonb_build_array(pg_temp.pid('KARINA KLEIN'))));
  assert r->>'codigo' = 'cedula_invalida', '9: VIM com admitido antigo aceito';
  r := public.registrar_cedula(tok, jsonb_build_object('HIPO', jsonb_build_array(pg_temp.pid('EVA ESTEVES'))));
  assert r->>'codigo' = 'cedula_invalida', '9: HIPO fora da lista aceito';
  r := public.registrar_cedula(tok, jsonb_build_object('OURO', jsonb_build_array(pg_temp.pid('HUGO HENRIQUES'))));
  assert r->>'codigo' = 'cedula_invalida', '9: inelegível aceito';
  r := public.registrar_cedula(tok, jsonb_build_object('XYZ', jsonb_build_array(pg_temp.pid('BRUNO BRAGA'))));
  assert r->>'codigo' = 'cedula_invalida', '9: categoria inexistente aceita';
  r := public.registrar_cedula(tok, jsonb_build_object('OURO', jsonb_build_array('nao-e-uuid')));
  assert r->>'codigo' = 'cedula_invalida', '9: id inválido aceito';
  r := public.registrar_cedula(tok, '{}'::jsonb);
  assert r->>'codigo' = 'cedula_vazia', '9: cédula vazia aceita';
  r := public.registrar_cedula(tok, jsonb_build_object('OURO', jsonb_build_array(pg_temp.pid('ANA ALVES'))));
  assert r->>'codigo' = 'cedula_invalida', '10: auto-voto aceito';
  assert not exists (select 1 from public.votos), '9: algo foi gravado';
  insert into t_ok values ('9', '4ª escolha, repetidos, outra unidade e categoria errada recusados');
  insert into t_ok values ('10', 'auto-voto recusado');
end $$;

-- ---------------------------------------------------------------- 4 (dupla sessão / duplo envio)
do $$
declare r jsonb; tok1 uuid := (select v::uuid from t_ctx where k = 'tok_ana'); tok2 uuid;
  ced jsonb;
begin
  perform pg_temp.como_anon();
  r := public.iniciar_votacao(pg_temp.cpf(1), '1990-01-10');     -- segunda aba
  tok2 := (r->>'token')::uuid;
  ced := jsonb_build_object(
    'LIDERANCA', jsonb_build_array(pg_temp.pid('KARINA KLEIN'), pg_temp.pid('LUCAS LIMA')),
    'PATROCINADOR', jsonb_build_array(pg_temp.pid('KARINA KLEIN')),
    'VIM_PARA_FICAR', jsonb_build_array(pg_temp.pid('DIEGO DIAS')),
    'OURO', jsonb_build_array(pg_temp.pid('EVA ESTEVES'), pg_temp.pid('KARINA KLEIN')),
    'HIPO', jsonb_build_array(pg_temp.pid('FABIO FARIAS')));
  r := public.registrar_cedula(tok1, ced);
  assert (r->>'ok')::boolean, '4: 1º envio falhou ' || r::text;
  assert r->>'protocolo' ~ '^[0-9A-F]{5}-[0-9A-F]{5}$', '4: protocolo';
  r := public.registrar_cedula(tok1, ced);
  assert (r->>'ok')::boolean is false, '4: duplo clique gravou 2x';
  r := public.registrar_cedula(tok2, ced);
  assert (r->>'ok')::boolean is false, '4: segunda aba gravou';
  r := public.iniciar_votacao(pg_temp.cpf(1), '1990-01-10');
  assert (r->>'ok')::boolean is false, '4: quem votou entrou de novo';
  assert (select count(*) from public.votos) = 7, '4: votos = ' || (select count(*) from public.votos);
  insert into t_ok values ('4', 'duas abas e duplo clique: 1 cédula só');
end $$;

-- Mais cédulas para a apuração
do $$
declare r jsonb;
begin
  perform pg_temp.como_anon();
  r := public.iniciar_votacao(pg_temp.cpf(12), '1980-01-02');           -- Lucas
  r := public.registrar_cedula((r->>'token')::uuid, jsonb_build_object(
        'LIDERANCA', jsonb_build_array(pg_temp.pid('KARINA KLEIN')),
        'OURO', jsonb_build_array(pg_temp.pid('KARINA KLEIN'))));
  assert (r->>'ok')::boolean;
  r := public.iniciar_votacao(pg_temp.cpf(13), '1980-01-03');           -- Maria
  r := public.registrar_cedula((r->>'token')::uuid, jsonb_build_object(
        'LIDERANCA', jsonb_build_array(pg_temp.pid('LUCAS LIMA'))));
  assert (r->>'ok')::boolean;
end $$;

-- ---------------------------------------------------------------- apuração
do $$
declare a jsonb; g jsonb;
begin
  perform pg_temp.como_admin();
  a := public.apurar();
  assert (a->>'cedulas')::int = 3, 'cédulas';
  assert (a->>'total_votos')::int = 10, 'total votos ' || (a->>'total_votos');
  assert (a->>'sanidade_ok')::boolean;
  select x into g from jsonb_array_elements(a->'grupos') x where x->>'categoria' = 'LIDERANCA' and x->>'unidade' = 'Matriz';
  assert jsonb_typeof(g->'vencedor') = 'null' and (g->>'empate')::boolean, 'LIDERANCA Matriz deveria empatar 2x2';
  select x into g from jsonb_array_elements(a->'grupos') x where x->>'categoria' = 'OURO' and x->>'unidade' = 'GERAL';
  assert g->'vencedor'->>'nome' = 'KARINA KLEIN' and (g->'vencedor'->>'votos')::int = 2, 'OURO vencedor';
  insert into t_ok values ('apuracao', 'apuração, empate e sanidade');
end $$;

-- ---------------------------------------------------------------- 11, 12 desligamento / volta
do $$
declare a jsonb; g jsonb; r jsonb;
begin
  perform pg_temp.como_admin();
  r := public.importar_ativos(pg_temp.planilha('KARINA KLEIN'), false);
  assert (r->>'desligados')::int = 1, '11: desligados';
  assert exists (select 1 from public.pessoas where nome = 'KARINA KLEIN' and not ativo and desligado_em is not null), '11: não marcou';
  a := public.apurar();
  select x into g from jsonb_array_elements(a->'grupos') x where x->>'categoria' = 'OURO' and x->>'unidade' = 'GERAL';
  assert (g->>'anulados')::int = 2, '11: anulados OURO';
  assert g->'vencedor'->>'nome' = 'EVA ESTEVES', '11: recálculo';
  select x into g from jsonb_array_elements(a->'grupos') x where x->>'categoria' = 'LIDERANCA' and x->>'unidade' = 'Matriz';
  assert g->'vencedor'->>'nome' = 'LUCAS LIMA' and not (g->>'empate')::boolean, '11: LIDERANCA recalculada';

  perform pg_temp.como_anon();
  r := public.iniciar_votacao(pg_temp.cpf(12), '1980-01-02');           -- Lucas votou na Karina
  assert (r->>'ok')::boolean is false, '11: quem votou no desligado votou de novo';
  r := public.iniciar_votacao(pg_temp.cpf(11), '1980-01-01');           -- a própria desligada
  assert (r->>'ok')::boolean is false, '11: desligado votou';
  insert into t_ok values ('11', 'desligado: votos anulados, recálculo, sem novo voto');

  perform pg_temp.como_admin();
  r := public.importar_ativos(pg_temp.planilha(), false);
  assert (r->>'reativados')::int = 1, '12: reativados';
  a := public.apurar();
  select x into g from jsonb_array_elements(a->'grupos') x where x->>'categoria' = 'OURO' and x->>'unidade' = 'GERAL';
  assert (g->>'anulados')::int = 0 and g->'vencedor'->>'nome' = 'KARINA KLEIN', '12: votos não voltaram';
  insert into t_ok values ('12', 'reativação devolve os votos');
end $$;

-- ---------------------------------------------------------------- 13 acesso anônimo
do $$
declare ok boolean;
begin
  perform pg_temp.como_anon();
  begin perform public.apurar(); ok := false; exception when others then ok := true; end;
  assert ok, '13: anon apurou';
  begin perform public.importar_ativos('[{}]'::jsonb, true); ok := false; exception when others then ok := true; end;
  assert ok, '13: anon importou';
  assert not has_function_privilege('anon', 'public.apurar()', 'execute'), '13: anon tem EXECUTE em apurar';
  assert not has_function_privilege('anon', 'public.importar_ativos(jsonb, boolean)', 'execute'), '13: EXECUTE importar';
  assert not has_function_privilege('anon', 'public.exportar_ata()', 'execute'), '13: EXECUTE ata';
  assert not has_table_privilege('anon', 'public.pessoas', 'select'), '13: anon SELECT pessoas';
  assert not has_table_privilege('anon', 'public.votos', 'select'), '13: anon SELECT votos';
  assert not has_table_privilege('authenticated', 'public.votos', 'select'), '13: authenticated SELECT votos';
  assert not has_table_privilege('anon', 'public.votos', 'insert'), '13: anon INSERT votos';
  assert has_function_privilege('anon', 'public.iniciar_votacao(text, date)', 'execute'), 'anon precisa iniciar';
  assert (select bool_and(relrowsecurity) from pg_class where oid in
          ('public.config'::regclass, 'public.categorias'::regclass, 'public.pessoas'::regclass, 'public.sessoes_voto'::regclass,
           'public.votos'::regclass, 'public.admins'::regclass, 'public.importacoes'::regclass)), '13: RLS';
  assert not exists (select 1 from pg_policies where schemaname = 'public'), '13: existe policy';
  -- usuário autenticado que NÃO é admin
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  begin perform public.apurar(); ok := false; exception when others then ok := true; end;
  assert ok, '13: autenticado não-admin apurou';
  insert into t_ok values ('13', 'anon e não-admin sem acesso');
end $$;

-- Também como papel anon de verdade (como a API REST faz)
set local role anon;
do $$
declare ok boolean;
begin
  begin perform 1 from public.pessoas limit 1; ok := false; exception when insufficient_privilege then ok := true; end;
  assert ok, '13: SELECT direto em pessoas como anon';
  begin perform 1 from public.votos limit 1; ok := false; exception when insufficient_privilege then ok := true; end;
  assert ok, '13: SELECT direto em votos como anon';
  begin perform public.apurar(); ok := false; exception when insufficient_privilege then ok := true; end;
  assert ok, '13: anon executou apurar';
end $$;
reset role;

-- ---------------------------------------------------------------- 14 anonimato
do $$
declare cols text[];
begin
  select array_agg(column_name::text order by column_name) into cols
  from information_schema.columns where table_schema = 'public' and table_name = 'votos';
  assert cols = array['candidato_id','categoria','dia','id','unidade_apuracao'], '14: colunas de votos ' || cols::text;
  assert (select data_type from information_schema.columns where table_schema='public' and table_name='votos' and column_name='dia') = 'date', '14: dia não é date';
  assert (select data_type from information_schema.columns where table_schema='public' and table_name='votos' and column_name='id') = 'uuid', '14: id não é uuid';
  assert not exists (select 1 from information_schema.columns where table_schema='public' and table_name='pessoas'
                     and column_name in ('cpf','nascimento','votou_em')), '14: coluna proibida em pessoas';
  assert not exists (select 1 from public.pessoas where cpf_hash ~ '^\d{11}$'), '14: CPF em texto';
  assert not exists (select 1 from pg_constraint where conrelid = 'public.votos'::regclass and contype = 'f'
                     and confrelid = 'public.sessoes_voto'::regclass), '14: FK para sessão';
  insert into t_ok values ('14', 'votos sem ligação com o eleitor');
end $$;

-- ---------------------------------------------------------------- votação fechada
do $$
declare r jsonb;
begin
  update public.config set fim = now() - interval '1 minute' where id = 1;
  perform pg_temp.como_anon();
  r := public.iniciar_votacao(pg_temp.cpf(14), '1980-01-04');
  assert r->>'codigo' = 'fechada', 'fora do período deveria fechar';
  insert into t_ok values ('fechada', 'fora do período a votação recusa com mensagem própria');
end $$;

-- Termina com uma exceção proposital: mostra a lista de testes aprovados e
-- garante que NADA fique gravado (a transação inteira é desfeita).
do $$ begin raise exception 'TODOS_OK: %', (select string_agg(n, ',' order by n) from t_ok); end $$;

rollback;

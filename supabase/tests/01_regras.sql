-- =====================================================================
-- Testes de aceite (banco), multiempresa (WAP + Freso).
-- Roda tudo numa transação e termina com a exceção proposital
-- "TODOS_OK: <lista>", que desfaz tudo. Dados 100% sintéticos.
-- =====================================================================
begin;

create temp table t_ok (n text primary key);
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
begin perform set_config('request.jwt.claims', json_build_object('sub', (select v from t_ctx where k = 'admin'), 'role', 'authenticated')::text, true); end $$;
create function pg_temp.como_anon() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '{"role":"anon"}', true); end $$;
create function pg_temp.pid(p_nome text) returns uuid language sql as $$ select id from public.pessoas where nome = p_nome $$;

-- Planilha WAP sintética
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
      'unidade', unidade, 'cargo', cargo, 'setor', case when n = 15 then 'ApInvalidez' else 'Setor ' || n end,
      'matricula', (1000 + n)::text, 'vinculo', vinculo) l) x
  where sem is null or nome <> sem
$$;

-- Planilha Freso sintética (CPF 1 = a mesma pessoa física da WAP, para testar o isolamento)
create function pg_temp.planilha_freso() returns jsonb language sql as $$
  select jsonb_agg(l) from (values
    (1,   'ANA ALVES FRESO', '1990-01-10', '2020-01-01', 'Home Office'),
    (101, 'PEDRO PRADO',     '1985-05-05', '2016-01-01', 'Freso - Fabrica'),
    (102, 'QUITERIA QUEIROZ','1986-06-06', '2026-04-01', 'Freso - Fabrica'),
    (103, 'RITA RAMOS',      '1987-07-07', '2014-01-01', 'Home Office')
  ) as t(n, nome, nasc, adm, unidade)
  cross join lateral (select jsonb_build_object('cpf', pg_temp.cpf(n), 'nome', nome, 'nascimento', nasc,
      'admissao', adm, 'unidade', unidade, 'cargo', 'ANALISTA', 'setor', 'Setor F') l) x
$$;

do $$
declare uid uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email) values (uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'admin-teste@example.invalid');
  insert into public.admins (user_id) values (uid);
  insert into t_ctx values ('admin', uid::text);
end $$;

delete from public.votos where true; delete from public.sessoes_voto where true; delete from public.pessoas where true;
update public.config set inicio = now() - interval '1 day', fim = now() + interval '1 day',
  status = 'aberta', permitir_auto_voto = false, max_por_categoria = 3 where true;

-- ---------------------------------------------------------------- importação
do $$
declare r jsonb;
begin
  perform pg_temp.como_admin();
  r := public.importar_ativos('WAP', pg_temp.planilha(), true);
  assert (r->>'novos')::int = 15, 'simulação: novos=' || (r->>'novos');
  assert not exists (select 1 from public.pessoas), 'simulação gravou dados';
  r := public.importar_ativos('WAP', pg_temp.planilha(), false);
  assert (select count(*) from public.pessoas where empresa = 'WAP') = 15, 'import WAP';
  assert (r->>'inelegiveis')::int = 4, 'inelegíveis (aprendiz, após corte, temporário, ApInvalidez): ' || (r->>'inelegiveis');
  assert (select motivo_inelegivel from public.pessoas where nome = 'OTAVIO OLIVEIRA') = 'Aposentadoria por invalidez', 'ApInvalidez';
  r := public.importar_hipo('WAP', jsonb_build_array(jsonb_build_object('cpf', pg_temp.cpf(1)), jsonb_build_object('matricula', '1006'), jsonb_build_object('cpf', pg_temp.cpf(8))), false);
  assert (r->>'encontrados')::int = 3, 'hipo encontrados';
  assert jsonb_array_length(r->'lista_nao_elegiveis') = 1, 'hipo avisa o aprendiz';
  r := public.importar_ativos('FRESO', pg_temp.planilha_freso(), false);
  assert (r->>'novos')::int = 4 and (r->>'desligados')::int = 0, 'import Freso ' || r::text;
  assert (select count(*) from public.pessoas where empresa = 'WAP' and ativo) = 15, 'import Freso mexeu na WAP';
  assert (select unidade from public.pessoas where nome = 'RITA RAMOS') = 'Home Office', 'Freso: Home Office não vira Matriz';
  assert (select unidade from public.pessoas where nome = 'PEDRO PRADO') = 'Fabrica', 'Freso: prefixo';
  begin perform public.importar_ativos('XPTO', pg_temp.planilha(), true); assert false, 'empresa inválida aceita';
  exception when others then if sqlerrm not like '%empresa inválida%' then raise; end if; end;
  insert into t_ok values ('import');
end $$;

do $$
begin
  assert interno.normalizar_unidade('Home Office', 'WAP') = 'Matriz';
  assert interno.normalizar_unidade('  externos ', 'WAP') = 'Matriz';
  assert interno.normalizar_unidade('WAP EXTERNO', 'WAP') = 'Matriz';
  assert interno.normalizar_unidade('Afonso   Pena', 'WAP') = 'Matriz';
  assert interno.normalizar_unidade('ANTÔNIO SINGER', 'WAP') = 'Matriz';
  assert interno.normalizar_unidade('Antonio Singer/ Matriz', 'WAP') = 'Matriz';
  assert interno.normalizar_unidade('Antonio Singer/Matriz', 'WAP') = 'Matriz';
  assert interno.normalizar_unidade('MATRIZ', 'WAP') = 'Matriz';
  assert interno.normalizar_unidade('WAP - SERRA', 'WAP') = 'Serra';
  assert interno.normalizar_unidade('WAP 103 - FORTALEZA', 'WAP') = 'Fortaleza';
  assert interno.normalizar_unidade('Home Office', 'FRESO') = 'Home Office';
  assert (select unidade from public.pessoas where nome = 'JOAO JARDIM') = 'Matriz';
  insert into t_ok values ('6a');
end $$;

-- ---------------------------------------------------------------- 1, 2, 3
do $$
declare r jsonb; g text := 'Não foi possível validar seus dados ou seu voto já foi registrado. Procure o RH.'; i int;
begin
  perform pg_temp.como_anon();
  r := public.iniciar_votacao('WAP', '123.456.789-00', '1990-01-10'); assert r->>'codigo' = 'cpf_invalido', '1';
  insert into t_ok values ('1');
  r := public.iniciar_votacao('WAP', pg_temp.cpf(999), '1990-01-10'); assert r->>'mensagem' = g, '2: fora da base';
  r := public.iniciar_votacao('WAP', pg_temp.cpf(2), '2000-01-01');   assert r->>'mensagem' = g, '2: nascimento';
  r := public.iniciar_votacao('WAP', pg_temp.cpf(8), '2008-08-17');   assert r->>'mensagem' = g, '2: aprendiz';
  r := public.iniciar_votacao('WAP', pg_temp.cpf(9), '1997-09-18');   assert r->>'mensagem' = g, '2: após corte';
  r := public.iniciar_votacao('WAP', pg_temp.cpf(10), '1998-10-19');  assert r->>'mensagem' = g, '2: temporário';
  r := public.iniciar_votacao('WAP', pg_temp.cpf(15), '1960-01-05');  assert r->>'mensagem' = g, '2: ApInvalidez';
  r := public.iniciar_votacao('WAP', pg_temp.cpf(101), '1985-05-05'); assert r->>'mensagem' = g, '2: pessoa da Freso na votação WAP';
  insert into t_ok values ('2');
  for i in 1..5 loop r := public.iniciar_votacao('WAP', pg_temp.cpf(2), '2000-01-01'); end loop;
  assert (select bloqueado_ate > now() + interval '14 minutes' from public.pessoas where nome = 'BRUNO BRAGA'), '3';
  r := public.iniciar_votacao('WAP', pg_temp.cpf(2), '1991-02-11'); assert (r->>'ok')::boolean is false, '3: bloqueado entrou';
  update public.pessoas set bloqueado_ate = null where nome = 'BRUNO BRAGA';
  insert into t_ok values ('3');
end $$;

-- ---------------------------------------------------------------- listas (6b, 7, 8, 10)
do $$
declare r jsonb; nomes jsonb; cat jsonb; lst text[];
begin
  perform pg_temp.como_anon();
  r := public.iniciar_votacao('WAP', substr(pg_temp.cpf(1),1,3)||'.'||substr(pg_temp.cpf(1),4,3)||'.'||substr(pg_temp.cpf(1),7,3)||'-'||substr(pg_temp.cpf(1),10,2), '1990-01-10');
  assert (r->>'ok')::boolean, 'Ana WAP deveria entrar: ' || r::text;
  assert r->>'unidade' = 'Matriz';
  insert into t_ctx values ('tok_ana', r->>'token');
  nomes := r->'pessoas';
  for cat in select * from jsonb_array_elements(r->'categorias') loop
    select array_agg(nomes->(i::int)->>1 order by nomes->(i::int)->>1) into lst from jsonb_array_elements_text(cat->'candidatos') i;
    lst := coalesce(lst, '{}');
    if cat->>'codigo' = 'VIM_PARA_FICAR' then assert lst = array['BRUNO BRAGA', 'DIEGO DIAS'], '7: ' || lst::text;
    elsif cat->>'codigo' in ('LIDERANCA', 'PATROCINADOR') then
      assert lst = array['BRUNO BRAGA','CARLA CASTRO','DIEGO DIAS','KARINA KLEIN','LUCAS LIMA','MARIA MOURA','NINA NUNES'], '6b: ' || lst::text;
    elsif cat->>'codigo' = 'OURO' then
      assert 'EVA ESTEVES' = any(lst) and 'GIL GOMES' = any(lst), '8: OURO';
      assert not ('ANA ALVES' = any(lst)), '10: auto-voto na lista';
      assert array_length(lst, 1) = 10, '8: OURO WAP deveria ter 10 (sem Freso), tem ' || array_length(lst, 1);
    elsif cat->>'codigo' = 'HIPO' then assert lst = array['FABIO FARIAS'], '8: HIPO ' || lst::text;
    end if;
  end loop;
  insert into t_ok values ('6b'), ('7'), ('8');

  -- Freso: a mesma pessoa física (CPF 1) vota separado e só vê gente da Freso
  r := public.iniciar_votacao('FRESO', pg_temp.cpf(1), '1990-01-10');
  assert (r->>'ok')::boolean, 'Ana Freso deveria entrar: ' || r::text;
  insert into t_ctx values ('tok_ana_freso', r->>'token');
  assert (select array_agg(x->>1 order by x->>1) from jsonb_array_elements(r->'pessoas') x)
         = array['PEDRO PRADO','QUITERIA QUEIROZ','RITA RAMOS'], 'Freso vê pessoas de fora: ' || (r->'pessoas')::text;
  insert into t_ok values ('isolamento_lista');
end $$;

-- ---------------------------------------------------------------- 9, 10
do $$
declare r jsonb; tok uuid := (select v::uuid from t_ctx where k = 'tok_ana');
begin
  perform pg_temp.como_anon();
  r := public.registrar_cedula(tok, jsonb_build_object('LIDERANCA', jsonb_build_array(pg_temp.pid('BRUNO BRAGA'), pg_temp.pid('CARLA CASTRO'), pg_temp.pid('DIEGO DIAS'), pg_temp.pid('KARINA KLEIN'))));
  assert r->>'codigo' = 'cedula_invalida', '9: 4';
  r := public.registrar_cedula(tok, jsonb_build_object('LIDERANCA', jsonb_build_array(pg_temp.pid('BRUNO BRAGA'), pg_temp.pid('BRUNO BRAGA'))));
  assert r->>'codigo' = 'cedula_invalida', '9: repetido';
  r := public.registrar_cedula(tok, jsonb_build_object('LIDERANCA', jsonb_build_array(pg_temp.pid('EVA ESTEVES'))));
  assert r->>'codigo' = 'cedula_invalida', '9: outra unidade';
  r := public.registrar_cedula(tok, jsonb_build_object('VIM_PARA_FICAR', jsonb_build_array(pg_temp.pid('KARINA KLEIN'))));
  assert r->>'codigo' = 'cedula_invalida', '9: VIM antigo';
  r := public.registrar_cedula(tok, jsonb_build_object('HIPO', jsonb_build_array(pg_temp.pid('EVA ESTEVES'))));
  assert r->>'codigo' = 'cedula_invalida', '9: HIPO fora';
  r := public.registrar_cedula(tok, jsonb_build_object('OURO', jsonb_build_array(pg_temp.pid('HUGO HENRIQUES'))));
  assert r->>'codigo' = 'cedula_invalida', '9: inelegível';
  r := public.registrar_cedula(tok, jsonb_build_object('OURO', jsonb_build_array(pg_temp.pid('PEDRO PRADO'))));
  assert r->>'codigo' = 'cedula_invalida', 'isolamento: WAP votou em pessoa da Freso';
  r := public.registrar_cedula(tok, jsonb_build_object('XYZ', jsonb_build_array(pg_temp.pid('BRUNO BRAGA'))));
  assert r->>'codigo' = 'cedula_invalida', '9: categoria';
  r := public.registrar_cedula(tok, jsonb_build_object('OURO', jsonb_build_array('nao-e-uuid')));
  assert r->>'codigo' = 'cedula_invalida', '9: id';
  r := public.registrar_cedula(tok, '{}'::jsonb);
  assert r->>'codigo' = 'cedula_vazia', '9: vazia';
  r := public.registrar_cedula(tok, jsonb_build_object('OURO', jsonb_build_array(pg_temp.pid('ANA ALVES'))));
  assert r->>'codigo' = 'cedula_invalida', '10: auto-voto';
  assert not exists (select 1 from public.votos), '9: algo gravado';
  insert into t_ok values ('9'), ('10'), ('isolamento_cedula');
end $$;

-- ---------------------------------------------------------------- 4
do $$
declare r jsonb; tok1 uuid := (select v::uuid from t_ctx where k = 'tok_ana'); tok2 uuid; ced jsonb;
begin
  perform pg_temp.como_anon();
  r := public.iniciar_votacao('WAP', pg_temp.cpf(1), '1990-01-10'); tok2 := (r->>'token')::uuid;
  ced := jsonb_build_object(
    'LIDERANCA', jsonb_build_array(pg_temp.pid('KARINA KLEIN'), pg_temp.pid('LUCAS LIMA')),
    'PATROCINADOR', jsonb_build_array(pg_temp.pid('KARINA KLEIN')),
    'VIM_PARA_FICAR', jsonb_build_array(pg_temp.pid('DIEGO DIAS')),
    'OURO', jsonb_build_array(pg_temp.pid('EVA ESTEVES'), pg_temp.pid('KARINA KLEIN')),
    'HIPO', jsonb_build_array(pg_temp.pid('FABIO FARIAS')));
  r := public.registrar_cedula(tok1, ced); assert (r->>'ok')::boolean, '4: 1º envio ' || r::text;
  assert r->>'protocolo' ~ '^[0-9A-F]{5}-[0-9A-F]{5}$', '4: protocolo';
  r := public.registrar_cedula(tok1, ced); assert (r->>'ok')::boolean is false, '4: duplo clique';
  r := public.registrar_cedula(tok2, ced); assert (r->>'ok')::boolean is false, '4: segunda aba';
  r := public.iniciar_votacao('WAP', pg_temp.cpf(1), '1990-01-10'); assert (r->>'ok')::boolean is false, '4: entrou de novo';
  assert (select count(*) from public.votos where empresa = 'WAP') = 7, '4: votos';
  -- A mesma pessoa física continua podendo votar na Freso (cadastro separado)
  r := public.registrar_cedula((select v::uuid from t_ctx where k = 'tok_ana_freso'),
         jsonb_build_object('OURO', jsonb_build_array(pg_temp.pid('PEDRO PRADO'))));
  assert (r->>'ok')::boolean, 'Freso: voto da Ana ' || r::text;
  assert (select count(*) from public.votos where empresa = 'FRESO') = 1, 'Freso: votos';
  insert into t_ok values ('4');
end $$;

do $$
declare r jsonb;
begin
  perform pg_temp.como_anon();
  r := public.iniciar_votacao('WAP', pg_temp.cpf(12), '1980-01-02');
  r := public.registrar_cedula((r->>'token')::uuid, jsonb_build_object('LIDERANCA', jsonb_build_array(pg_temp.pid('KARINA KLEIN')), 'OURO', jsonb_build_array(pg_temp.pid('KARINA KLEIN'))));
  assert (r->>'ok')::boolean;
  r := public.iniciar_votacao('WAP', pg_temp.cpf(13), '1980-01-03');
  r := public.registrar_cedula((r->>'token')::uuid, jsonb_build_object('LIDERANCA', jsonb_build_array(pg_temp.pid('LUCAS LIMA'))));
  assert (r->>'ok')::boolean;
end $$;

-- ---------------------------------------------------------------- apuração por empresa
do $$
declare a jsonb; g jsonb;
begin
  perform pg_temp.como_admin();
  a := public.apurar('WAP');
  assert (a->>'cedulas')::int = 3 and (a->>'total_votos')::int = 10 and (a->>'sanidade_ok')::boolean, 'apuração WAP ' || (a->>'cedulas') || '/' || (a->>'total_votos');
  select x into g from jsonb_array_elements(a->'grupos') x where x->>'categoria' = 'LIDERANCA' and x->>'unidade' = 'Matriz';
  assert jsonb_typeof(g->'vencedor') = 'null' and (g->>'empate')::boolean, 'empate';
  select x into g from jsonb_array_elements(a->'grupos') x where x->>'categoria' = 'OURO' and x->>'unidade' = 'GERAL';
  assert g->'vencedor'->>'nome' = 'KARINA KLEIN' and (g->'vencedor'->>'votos')::int = 2, 'OURO vencedor';
  a := public.apurar('FRESO');
  assert (a->>'cedulas')::int = 1 and (a->>'total_votos')::int = 1, 'apuração Freso misturou: ' || (a->>'cedulas') || '/' || (a->>'total_votos');
  select x into g from jsonb_array_elements(a->'grupos') x where x->>'categoria' = 'OURO';
  assert g->'vencedor'->>'nome' = 'PEDRO PRADO', 'Freso vencedor';
  assert not exists (select 1 from jsonb_array_elements(a->'participacao') x where x->>'unidade' = 'Matriz'), 'Freso com unidade da WAP';
  insert into t_ok values ('apuracao'), ('isolamento_apuracao');
end $$;

-- ---------------------------------------------------------------- 11, 12
do $$
declare a jsonb; g jsonb; r jsonb;
begin
  perform pg_temp.como_admin();
  r := public.importar_ativos('WAP', pg_temp.planilha('KARINA KLEIN'), false);
  assert (r->>'desligados')::int = 1, '11: desligados';
  assert (select count(*) from public.pessoas where empresa = 'FRESO' and ativo) = 4, '11: reimport WAP desligou gente da Freso';
  a := public.apurar('WAP');
  select x into g from jsonb_array_elements(a->'grupos') x where x->>'categoria' = 'OURO' and x->>'unidade' = 'GERAL';
  assert (g->>'anulados')::int = 2 and g->'vencedor'->>'nome' = 'EVA ESTEVES', '11: anulados/recálculo';
  perform pg_temp.como_anon();
  r := public.iniciar_votacao('WAP', pg_temp.cpf(12), '1980-01-02'); assert (r->>'ok')::boolean is false, '11: votou de novo';
  r := public.iniciar_votacao('WAP', pg_temp.cpf(11), '1980-01-01'); assert (r->>'ok')::boolean is false, '11: desligado votou';
  insert into t_ok values ('11');
  perform pg_temp.como_admin();
  r := public.importar_ativos('WAP', pg_temp.planilha(), false);
  assert (r->>'reativados')::int = 1, '12';
  a := public.apurar('WAP');
  select x into g from jsonb_array_elements(a->'grupos') x where x->>'categoria' = 'OURO' and x->>'unidade' = 'GERAL';
  assert (g->>'anulados')::int = 0 and g->'vencedor'->>'nome' = 'KARINA KLEIN', '12: votos não voltaram';
  insert into t_ok values ('12');
end $$;

-- ---------------------------------------------------------------- status independente por empresa
do $$
declare r jsonb;
begin
  perform pg_temp.como_admin();
  perform public.alterar_status('FRESO', 'encerrada');
  assert (select status from public.config where empresa = 'WAP') = 'aberta', 'encerrar Freso afetou a WAP';
  perform pg_temp.como_anon();
  r := public.iniciar_votacao('FRESO', pg_temp.cpf(101), '1985-05-05'); assert r->>'codigo' = 'fechada', 'Freso deveria estar fechada';
  perform pg_temp.como_admin();
  r := public.zerar_votacao('FRESO', 'ZERAR VOTOS');
  assert (r->>'votos_apagados')::int = 1 and (select count(*) from public.votos where empresa = 'WAP') = 10, 'zerar Freso mexeu na WAP';
  insert into t_ok values ('status_por_empresa');
end $$;

-- ---------------------------------------------------------------- 13
do $$
declare ok boolean;
begin
  perform pg_temp.como_anon();
  begin perform public.apurar('WAP'); ok := false; exception when others then ok := true; end; assert ok, '13: anon apurou';
  begin perform public.importar_ativos('WAP', '[{}]'::jsonb, true); ok := false; exception when others then ok := true; end; assert ok, '13: anon importou';
  assert not has_function_privilege('anon', 'public.apurar(text)', 'execute'), '13: EXECUTE apurar';
  assert not has_function_privilege('anon', 'public.importar_ativos(text, jsonb, boolean)', 'execute'), '13: EXECUTE importar';
  assert not has_function_privilege('anon', 'public.exportar_ata(text)', 'execute'), '13: EXECUTE ata';
  assert not has_function_privilege('anon', 'public.painel_admin(text)', 'execute'), '13: EXECUTE painel';
  assert not has_table_privilege('anon', 'public.pessoas', 'select'), '13: SELECT pessoas';
  assert not has_table_privilege('anon', 'public.votos', 'select'), '13: SELECT votos';
  assert not has_table_privilege('anon', 'public.empresas', 'select'), '13: SELECT empresas';
  assert not has_table_privilege('authenticated', 'public.votos', 'select'), '13: auth SELECT votos';
  assert has_function_privilege('anon', 'public.iniciar_votacao(text, text, date)', 'execute'), 'anon precisa iniciar';
  assert (select bool_and(relrowsecurity) from pg_class c join pg_namespace n on n.oid = c.relnamespace
          where n.nspname = 'public' and c.relkind = 'r'), '13: RLS em todas as tabelas';
  assert not exists (select 1 from pg_policies where schemaname = 'public'), '13: policy';
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  begin perform public.apurar('WAP'); ok := false; exception when others then ok := true; end; assert ok, '13: não-admin';
  insert into t_ok values ('13');
end $$;
set local role anon;
do $$
declare ok boolean;
begin
  begin perform 1 from public.pessoas limit 1; ok := false; exception when insufficient_privilege then ok := true; end; assert ok, '13: SELECT pessoas';
  begin perform 1 from public.votos limit 1; ok := false; exception when insufficient_privilege then ok := true; end; assert ok, '13: SELECT votos';
  begin perform public.apurar('WAP'); ok := false; exception when insufficient_privilege then ok := true; end; assert ok, '13: apurar';
end $$;
reset role;

-- ---------------------------------------------------------------- 14
do $$
declare cols text[];
begin
  select array_agg(column_name::text order by column_name) into cols from information_schema.columns where table_schema = 'public' and table_name = 'votos';
  assert cols = array['candidato_id','categoria','dia','empresa','id','unidade_apuracao'], '14: colunas ' || cols::text;
  assert not exists (select 1 from public.pessoas where cpf_hash ~ '^\d{11}$'), '14: CPF em texto';
  insert into t_ok values ('14');
end $$;

do $$
declare r jsonb;
begin
  update public.config set fim = now() - interval '1 minute' where empresa = 'WAP';
  perform pg_temp.como_anon();
  r := public.iniciar_votacao('WAP', pg_temp.cpf(14), '1980-01-04');
  assert r->>'codigo' = 'fechada', 'fechada';
  insert into t_ok values ('fechada');
end $$;

-- Exceção proposital: lista os aprovados e desfaz TUDO.
do $$ begin raise exception 'TODOS_OK: %', (select string_agg(n, ',' order by n) from t_ok); end $$;

rollback;

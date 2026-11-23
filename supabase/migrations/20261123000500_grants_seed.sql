-- =====================================================================
-- Permissões das RPCs + carga inicial (categorias e config)
-- =====================================================================

-- Por padrão o Supabase dá EXECUTE a anon/authenticated em funções novas do
-- schema public. Revoga tudo e libera só o necessário.
revoke all on all functions in schema public from public;
do $$ begin
  execute 'revoke all on all functions in schema public from anon, authenticated';
exception when undefined_object then null; end $$;

grant execute on function public.info_publica()                      to anon, authenticated;
grant execute on function public.iniciar_votacao(text, date)         to anon, authenticated;
grant execute on function public.registrar_cedula(uuid, jsonb)       to anon, authenticated;

grant execute on function public.sou_admin()                         to authenticated;
grant execute on function public.importar_ativos(jsonb, boolean)     to authenticated;
grant execute on function public.importar_hipo(jsonb, boolean)       to authenticated;
grant execute on function public.configurar(jsonb)                   to authenticated;
grant execute on function public.alterar_status(text)                to authenticated;
grant execute on function public.apurar()                            to authenticated;
grant execute on function public.exportar_ata()                      to authenticated;
grant execute on function public.painel_admin()                      to authenticated;
grant execute on function public.zerar_votacao(text)                 to authenticated;
grant execute on function public.anonimizar_base(text)               to authenticated;

-- Evita que funções criadas no futuro nasçam executáveis por anon.
alter default privileges in schema public revoke execute on functions from public;
do $$ begin
  execute 'alter default privileges in schema public revoke execute on functions from anon, authenticated';
exception when undefined_object then null; end $$;

-- ---------------------------------------------------------------------
insert into public.config (id, nome_eleicao, data_corte, vim_para_ficar_desde, inicio, fim, status)
values (1, 'Destaques do Ano 2026', '2026-11-30', '2025-12-01',
        '2026-12-09 00:00:00-03', '2026-12-23 23:59:59-03', 'rascunho')
on conflict (id) do nothing;

insert into public.categorias (codigo, nome, descricao, escopo, regra, ordem) values
 ('VIM_PARA_FICAR', 'Vim para ficar',
  'Aquele Legendário que chegou e rapidamente conquistou seu espaço. Demonstrou valor, comprometimento e já se tornou peça essencial para o time.',
  'unidade', 'admitidos_12m', 1),
 ('LIDERANCA', 'Liderança Inspiradora',
  'Não precisa ocupar uma posição de gestor para ser um líder nato. Esse legendário inspira quem está à sua volta, direciona os ambientes com confiança e influencia positivamente todos ao seu redor.',
  'unidade', 'todos', 2),
 ('PATROCINADOR', 'Patrocinador da Mudança',
  'Esse legendário não apenas apoia mudanças e melhorias, ele as impulsiona. Sugere, provoca e faz acontecer. Está sempre à frente, puxando transformações e desafiando, com uma visão de evolução que realmente faz a diferença.',
  'unidade', 'todos', 3),
 ('OURO', 'Colaborador de Ouro',
  'Esse legendário é a personificação dos nossos valores. Se pensamos em liderança de arrimo, mão na massa, sonhar grande, obsessão por resultados e foco no cliente, ele é o exemplo perfeito. Sua determinação e resiliência são evidentes e fazem toda a diferença.',
  'geral', 'todos', 4),
 ('HIPO', 'High Potential',
  'Esse legendário foi destaque e entrou para a lista dos High Potential 2026. Mesmo em meio a um grupo de talentos, conseguiu se sobressair ainda mais, demonstrando um potencial e comprometimento acima da média.',
  'geral', 'hipo', 5)
on conflict (codigo) do update set nome = excluded.nome, descricao = excluded.descricao,
  escopo = excluded.escopo, regra = excluded.regra, ordem = excluded.ordem;

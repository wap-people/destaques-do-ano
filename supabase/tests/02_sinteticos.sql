-- =====================================================================
-- Base 100% SINTÉTICA para HOMOLOGAÇÃO (nunca rodar em produção).
-- Gera 1.100 pessoas com CPF válido determinístico:
--   pessoa i (1..1100): CPF = 9 dígitos (900000000 + i) + 2 dígitos verificadores
--                       nascimento = 1970-01-01 + (i*37 mod 12000) dias
-- O teste de carga (scripts/carga.ps1) recalcula os mesmos valores.
-- =====================================================================
do $$
declare n int := 1100;
begin
  if exists (select 1 from public.pessoas where nome not like '% SINT %') then
    raise exception 'Há pessoas reais na base: este script é só para homologação vazia.';
  end if;
end $$;

create or replace function pg_temp.cpf_sint(i int) returns text language plpgsql as $$
declare b text := (900000000 + i)::text; s int := 0; d int; k int;
begin
  for k in 1..9 loop s := s + substr(b, k, 1)::int * (11 - k); end loop;
  d := (s * 10) % 11; if d = 10 then d := 0; end if; b := b || d; s := 0;
  for k in 1..10 loop s := s + substr(b, k, 1)::int * (12 - k); end loop;
  d := (s * 10) % 11; if d = 10 then d := 0; end if;
  return b || d;
end $$;

delete from public.votos where true;
delete from public.sessoes_voto where true;
delete from public.pessoas where true;

insert into public.pessoas (cpf_hash, nasc_hash, nome, matricula, cargo, setor, unidade_original, unidade,
                            data_admissao, vinculo, elegivel, motivo_inelegivel, high_potential)
select interno.hmac(c.cpf),
       interno.hmac(c.cpf || '|' || to_char(c.nasc, 'YYYY-MM-DD')),
       (array['ANA','BRUNO','CARLA','DIEGO','EVA','FABIO','GABRIELA','HUGO','ISABELA','JOAO','KAREN','LUCAS','MARINA','NELSON','OLIVIA','PAULO','RAFAEL','SOFIA','TIAGO','VITOR'])[1 + i % 20]
         || ' SINT ' || (array['SILVA','SOUZA','LIMA','COSTA','GOMES','ALMEIDA','ROCHA','MARTINS','DIAS','RIBEIRO','ARAUJO'])[1 + (i / 20) % 11]
         || ' ' || i,
       (20000 + i)::text,
       case when i % 40 = 0 then 'JOVEM APRENDIZ' else 'ANALISTA' end,
       (array['Produção','Qualidade','Logística','TI','Vendas','Marketing','Financeiro','People','P&D','Suprimentos'])[1 + i % 10],
       u.orig, interno.normalizar_unidade(u.orig),
       c.adm,
       case when i % 40 = 0 then 'Aprendiz' else 'Efetivo (CLT)' end,
       i % 40 <> 0,
       case when i % 40 = 0 then 'Aprendiz (pelo cargo)' end,
       i % 37 = 0
from generate_series(1, 1100) i
cross join lateral (select pg_temp.cpf_sint(i) cpf,
                           date '1970-01-01' + (i * 37 % 12000) nasc,
                           case when i % 9 < 4 then date '2025-12-01' + (i % 364)
                                else date '2008-01-01' + (i * 13 % 6000) end adm) c
cross join lateral (select case
    when i % 20 < 8  then 'WAP - ANTONIO SINGER'
    when i % 20 < 12 then 'WAP - AFONSO PENA'
    when i % 20 < 15 then 'WAP - LINHARES'
    when i % 20 < 18 then 'WAP - SERRA'
    when i % 20 = 18 then 'WAP 103 - FORTALEZA'
    else 'HOME OFFICE' end orig) u;

select unidade, count(*) total, count(*) filter (where elegivel) elegiveis,
       count(*) filter (where high_potential) hipo
from public.pessoas group by 1 order by 1;

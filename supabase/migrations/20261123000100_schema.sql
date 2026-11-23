-- =====================================================================
-- Destaques do Ano 2026 (WAP) - esquema
-- Requisito duro: NENHUMA ligação entre eleitor e voto (ver README).
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- Funções internas ficam fora do schema exposto pela API REST.
create schema if not exists interno;
revoke all on schema interno from public;
do $$ begin
  execute 'revoke all on schema interno from anon, authenticated';
exception when undefined_object then null; end $$;

-- ---------------------------------------------------------------------
create table public.config (
  id int primary key default 1 check (id = 1),
  nome_eleicao text not null default 'Destaques do Ano 2026',
  data_corte date not null default '2026-11-30',
  vim_para_ficar_desde date not null default '2025-12-01',
  inicio timestamptz,
  fim timestamptz,
  status text not null default 'rascunho'
    check (status in ('rascunho','aberta','encerrada')),
  permitir_auto_voto boolean not null default false,
  max_por_categoria int not null default 3 check (max_por_categoria between 1 and 10),
  check (fim is null or inicio is null or fim > inicio)
);

create table public.categorias (
  codigo text primary key,
  nome text not null,
  descricao text not null,
  escopo text not null check (escopo in ('unidade','geral')),
  regra text not null check (regra in ('todos','admitidos_12m','hipo')),
  ordem int not null
);

-- Eleitores = candidatos. CPF e nascimento só como HMAC.
create table public.pessoas (
  id uuid primary key default gen_random_uuid(),
  cpf_hash text unique not null,
  nasc_hash text not null,
  nome text not null,
  matricula text,
  cargo text,
  setor text,
  unidade_original text,
  unidade text not null,
  data_admissao date not null,
  vinculo text not null,
  elegivel boolean not null,
  motivo_inelegivel text,
  high_potential boolean not null default false,
  ativo boolean not null default true,
  desligado_em timestamptz,
  ja_votou boolean not null default false,
  votou_dia date,                 -- só a data (participação diária), nunca a hora
  tentativas_falhas int not null default 0,
  bloqueado_ate timestamptz
);
create index pessoas_unidade_ativos_idx on public.pessoas (unidade) where ativo and elegivel;
create index pessoas_matricula_idx on public.pessoas (matricula);

-- Token curto entre identificação e envio da cédula. Apagado no envio.
create table public.sessoes_voto (
  token uuid primary key default gen_random_uuid(),
  pessoa_id uuid not null references public.pessoas(id) on delete cascade,
  expira_em timestamptz not null
);
create index sessoes_voto_pessoa_idx on public.sessoes_voto (pessoa_id);
create index sessoes_voto_expira_idx on public.sessoes_voto (expira_em);

-- SEM referência ao eleitor, sem hora, sem sequencial.
create table public.votos (
  id uuid primary key default gen_random_uuid(),
  categoria text not null references public.categorias(codigo),
  candidato_id uuid not null references public.pessoas(id),
  unidade_apuracao text not null,
  dia date not null default ((now() at time zone 'America/Sao_Paulo')::date)
);
create index votos_apuracao_idx on public.votos (categoria, unidade_apuracao, candidato_id);
create index votos_candidato_idx on public.votos (candidato_id);

create table public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

create table public.importacoes (
  id bigint generated always as identity primary key,
  feito_em timestamptz not null default now(),
  feito_por uuid,
  tipo text not null,             -- 'ativos' | 'hipo' | 'zeragem' | 'status' | 'config' | 'anonimizacao'
  novos int, atualizados int, desligados int, ignorados int,
  detalhes jsonb                  -- só contagens e motivos, nunca CPF
);

-- RLS em tudo, nenhuma policy: o único acesso é pelas RPCs SECURITY DEFINER.
alter table public.config       enable row level security;
alter table public.categorias   enable row level security;
alter table public.pessoas      enable row level security;
alter table public.sessoes_voto enable row level security;
alter table public.votos        enable row level security;
alter table public.admins       enable row level security;
alter table public.importacoes  enable row level security;

-- Defesa em profundidade: tira também os privilégios de tabela.
revoke all on table public.config, public.categorias, public.pessoas, public.sessoes_voto,
  public.votos, public.admins, public.importacoes from public;
do $$ begin
  execute 'revoke all on table public.config, public.categorias, public.pessoas, public.sessoes_voto,
    public.votos, public.admins, public.importacoes from anon, authenticated';
  execute 'revoke all on sequence public.importacoes_id_seq from anon, authenticated';
exception when undefined_object then null; end $$;

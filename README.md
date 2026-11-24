# Destaques do Ano 2026

Sistema de votação anônima do grupo (WAP e Freso): site estático no **GitHub Pages** e backend no **Supabase Free**.

Atende **duas empresas do grupo: WAP e Freso**. A votação é separada (página, marca, base, HiPo,
status e apuração próprios); admins e telas de apuração são unificados, com seletor de empresa.

| Página | Acesso | Para quê |
|---|---|---|
| `index.html` | público | página neutra de escolha (sem JS), aponta para `/wap/` e `/freso/` |
| `wap/index.html` | público | votação **WAP** (DS "WAP Group") |
| `freso/index.html` | público | votação **Freso** (azul #1F39F9, cereja #C00033, Poppins) |
| `teste/wap/` e `teste/freso/` | público | votação **de teste**: mesma tela e regras, nomes fictícios, sem Supabase (simulador-teste.js, `connect-src 'none'`); nada é registrado |
| `resultado.html` | login (comissão) | apuração ao vivo por empresa (polling 30 s), CSV e ata |
| `admin.html` | login (admins) | por empresa: importar planilhas, configurar, abrir/encerrar |

Endereços: `https://wap-people.github.io/destaques-do-ano/wap/` (WAP) e `.../freso/` (Freso).
Repositório `wap-people/destaques-do-ano` (renomeado de `votacao-destaques-wap` em 24/11/2026).
Projetos Supabase: produção `votacao-destaques-prod` e homologação `votacao-destaques-homolog`
(o `assets/js/config.js` aponta para a produção; a homologação está comentada no mesmo arquivo).

### Multiempresa
- Tabela `empresas` (WAP, FRESO). `config`, `pessoas`, `votos` e `importacoes` têm a coluna `empresa`.
- O mesmo CPF pode existir nas duas empresas (cadastros independentes, `unique (empresa, cpf_hash)`).
- `interno.candidatos()` só devolve pessoas da mesma empresa do eleitor; importar uma empresa nunca desliga ninguém da outra.
- A regra "vira Matriz" (seção 1.2) vale só para a WAP.
- Todas as RPCs recebem `p_empresa` (exceto `registrar_cedula`, que deduz a empresa pela sessão).

Manual do RH: [MANUAL_OPERACAO.md](MANUAL_OPERACAO.md). Escopo, situação atual e pendências para quem continua o desenvolvimento: [CONTINUIDADE.md](CONTINUIDADE.md).

## Arquitetura

```
GitHub Pages (HTML + CSS + JS puro, sem build)
  libs por CDN com versão fixa e SRI:
    @supabase/supabase-js 2.45.4 (jsDelivr) · SheetJS 0.20.3 (cdn.sheetjs.com, só no admin)
        │ HTTPS: URL do projeto + chave anon/publishable (assets/js/config.js)
        ▼
Supabase Free
  Postgres com RLS em TODAS as tabelas e nenhuma policy
  RPCs SECURITY DEFINER (search_path fixo) = única porta de leitura/escrita
  Auth e-mail+senha só para admins · Vault guarda o pepper do HMAC
```

### Anonimato (requisito duro)
- `votos` tem só `id uuid` aleatório, `categoria`, `candidato_id`, `unidade_apuracao` e `dia` (data, sem hora). Nenhuma FK, id ou timestamp que leve ao eleitor.
- O eleitor só guarda `ja_votou` e `votou_dia` (data). Os votos de uma cédula são inseridos em ordem aleatória.
- CPF nunca é salvo: só `HMAC-SHA256(cpf, pepper)`; nascimento = `HMAC(cpf|aaaa-mm-dd, pepper)`. O pepper é gerado dentro do banco (migration) e fica no **Vault**.
- Nenhum `RAISE`/log com CPF, nascimento ou escolha. Admins só veem agregados.
- Limitação: um superusuário do banco poderia tentar correlacionar a ordem física das linhas. Mitigação: acesso ao painel Supabase restrito a 1–2 pessoas e anonimização no encerramento.

### Funções RPC
| Função | Papel | Descrição |
|---|---|---|
| `info_publica()` | anon | nome, status, período, categorias |
| `iniciar_votacao(cpf, nascimento)` | anon | valida, bloqueia 15 min após 5 erros, cria sessão de 20 min e devolve a cédula já filtrada |
| `registrar_cedula(token, escolhas)` | anon | valida tudo no servidor, grava em 1 transação com `FOR UPDATE` no eleitor |
| `importar_ativos(linhas, simular)` | admin | upsert por hash, normaliza unidade, calcula elegibilidade, desliga quem saiu |
| `importar_hipo(linhas, simular)` | admin | lista High Potential 2026 por CPF ou matrícula |
| `configurar(p)` / `alterar_status(s)` | admin | período, auto-voto; rascunho→aberta→encerrada→aberta |
| `apurar()` / `exportar_ata()` | admin | rankings, anulados, empates, participação, conferência |
| `painel_admin()` | admin | contagens e histórico |
| `zerar_votacao('ZERAR VOTOS')` | admin | piloto: apaga votos e `ja_votou` (nunca com votação aberta) |
| `anonimizar_base('ANONIMIZAR')` | admin | LGPD: troca os hashes por valores aleatórios (só encerrada) |

A regra "quem pode receber voto de quem" está num único lugar: `interno.candidatos(eleitor)`, usada pela cédula e pela validação.

## Estrutura

```
index.html (escolha) · wap/index.html · freso/index.html · resultado.html · admin.html
assets/css/tokens.css   tokens do DS "WAP Group" (cores do símbolo, cinzas, Inter)
assets/css/app.css      Liquid Glass + fallbacks (transparência, movimento, contraste, sem backdrop-filter)
                        combo de efeitos: entrada zoom+desfoque, hover de mola, varredura de luz,
                        gotas do fundo com blur CSS (paradas abaixo de 600 px)
                        movimento: Liquid Morph nas abas, Bubble Reveal nos botões,
                        Scroll Float nas barras flutuantes (comum.js: abasLiquidas, sairBolha)
                        cédula: pop no check, pulso no contador, deslize entre categorias,
                        confete no comprovante (comum.js: pulsar, animar, confete) e skeleton no carregamento
assets/js/              comum, voto, auth, admin, resultado, config
assets/img/             logos oficiais WAP WAAW e símbolo de barras
supabase/migrations/    esquema, funções internas, RPCs, grants e carga inicial
supabase/tests/01_regras.sql      testes de aceite em SQL (rodam em transação e desfazem)
supabase/tests/02_sinteticos.sql  base sintética de 1.100 pessoas (só homologação)
scripts/carga.ps1                 teste de carga em PowerShell/.NET (sem instalar nada)
scripts/servidor-local.ps1        servidor estático local para testes
```

## Implantação

1. **Supabase** (projeto Free, região `sa-east-1`):
   ```
   npx supabase login
   npx supabase link --project-ref <ref>
   npx supabase db push
   ```
   (ou aplicar os arquivos de `supabase/migrations/` em ordem no SQL Editor / MCP).
2. Em **Authentication → URL Configuration**, coloque a URL do GitHub Pages em *Site URL* e em *Redirect URLs* (`.../admin.html` e `.../resultado.html`). Desative *Allow new users to sign up*.
3. Preencha `assets/js/config.js` com a URL do projeto e a chave **anon/publishable** (nunca a `service_role`).
4. Admins: convide pelo painel (Authentication → Users → Invite) e rode
   `insert into public.admins (user_id) select id from auth.users where email = '...';`
5. GitHub Pages: Settings → Pages → Deploy from branch `main` / root.

## Testes

- **Banco:** `supabase/tests/01_regras.sql` (SQL Editor de homologação ou MCP). Termina com a exceção proposital `TODOS_OK: ...` listando os testes aprovados e desfazendo tudo; qualquer falha aborta antes com a mensagem do `assert`.
- **Carga:** rodar `supabase/tests/02_sinteticos.sql` na homologação, abrir a votação e então
  `powershell -ExecutionPolicy Bypass -File scripts/carga.ps1 -Url https://<ref>.supabase.co -Key <anon>`.
  (Substitui o k6, que não pôde ser instalado na máquina; mesmos critérios: 0 erros, p95 < 2 s.)
- **Front:** `powershell -ExecutionPolicy Bypass -File scripts/servidor-local.ps1` e abrir `http://localhost:8080`.

### Resultados em homologação (23/11/2026)
- Testes de aceite SQL: 17 blocos aprovados (itens 1–14 da especificação, apuração/empate, votação fechada, importação/HiPo/ApInvalidez).
- REST como anônimo: 401 em todas as tabelas, em `apurar`, `painel_admin`, `exportar_ata`, `importar_ativos` e em insert direto em `votos`.
- Concorrência (mesma pessoa, 3 envios simultâneos com 2 sessões): 1 cédula gravada.
- Carga: 1.000 eleitores em rampa de 60 s (pico de 50 simultâneos em sessão), 1.000 cédulas, 0 erros, 0 duplicados
  (49 reenvios recusados). `iniciar_votacao` p50 66 ms / p95 291 ms; `registrar_cedula` p50 38 ms / p95 157 ms.
  Conferência no banco: cédulas e votos idênticos ao enviado.
- Cédula de um eleitor da Matriz com 1.072 elegíveis: ~93 KB (limite de atenção: 300 KB).
- Advisors: sem alertas críticos. Avisos esperados: "RLS sem policy" (proposital) e "SECURITY DEFINER executável"
  (as RPCs são a API; as de admin checam `admins` internamente).

Dados reais (Excel, CSV) **nunca** entram no repositório (`.gitignore`).

### Publicar uma alteração no front
O GitHub Pages manda o navegador guardar os arquivos por 10 minutos. Ao mudar qualquer JS, troque a
versão `?v=AAAAMMDDx` nos `import` de `assets/js/*.js` e no `<script type="module">` de cada HTML
(é o mesmo valor em todos os lugares), para todo mundo receber a versão nova na hora.

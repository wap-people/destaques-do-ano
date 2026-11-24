# Continuidade do projeto · Destaques do Ano 2026

Documento de passagem para quem assume o desenvolvimento. Leia junto com o [README.md](README.md)
(arquitetura e RPCs) e o [MANUAL_OPERACAO.md](MANUAL_OPERACAO.md) (operação pelo RH).
Situação registrada em **24/11/2026**.

---

## 1. Escopo

Votação **anônima** dos *Destaques do Ano 2026* para duas empresas do grupo, **WAP** e **Freso**,
com votações separadas (base, lista HiPo, status, período e apuração próprios).

- **Quem vota:** colaborador ativo e elegível da própria empresa, identificado por **CPF + data de nascimento**. Vota uma única vez.
- **Quem não vota nem recebe voto:** aprendiz, estagiário, temporário, admitido depois da data de corte (30/11/2026), desligado e aposentado por invalidez (ApInvalidez).
- **Cédula:** até **3 indicações por categoria**, sem votar em si mesmo (configurável).
- **Categorias** (mesmos textos nas duas empresas):

| Código | Nome | Escopo | Quem pode receber voto |
|---|---|---|---|
| `VIM_PARA_FICAR` | Vim para ficar | unidade | admitidos entre 01/12/2025 e 30/11/2026 |
| `LIDERANCA` | Liderança Inspiradora | unidade | todos os elegíveis |
| `PATROCINADOR` | Patrocinador da Mudança | unidade | todos os elegíveis |
| `OURO` | Colaborador de Ouro | geral | todos os elegíveis |
| `HIPO` | High Potential | geral | só quem está na lista High Potential 2026 |

- **Escopo "unidade":** o eleitor só vê colegas da mesma unidade. Na WAP, Antonio Singer, Afonso Pena, Externo e Home Office contam como **Matriz**. Essa regra não vale para a Freso.
- **Período padrão:** de 09/12/2026 00:00 a 23/12/2026 23:59 (Brasília).
- **Resultado:** rankings por categoria e unidade, empates sinalizados (quem decide é a comissão), CSV e ata para imprimir.

### Requisitos que não podem ser quebrados
1. **Anonimato:** nenhum dado liga o voto a quem votou. Os detalhes estão no README, em "Anonimato".
2. **CPF e nascimento nunca são guardados em claro.** Só são guardados como HMAC-SHA256 com o *pepper*, que fica no Vault do Supabase.
3. **RLS ligado em todas as tabelas e nenhuma policy.** O front só usa as RPCs `SECURITY DEFINER`. As RPCs de admin conferem a tabela `admins`.
4. **A `service_role` nunca vai para o front nem para o git.** Em `assets/js/config.js` só ficam a URL e a chave anon.
5. **Planilhas (Excel/CSV) e dados pessoais nunca vão para o git.** O `.gitignore` já bloqueia esses arquivos.
6. **Só planos gratuitos:** GitHub Pages e Supabase Free.
7. Interface em **pt-BR**, responsiva (celular e PC) e acessível (movimento reduzido, alto contraste).

---

## 2. Onde está cada coisa

| Item | Onde |
|---|---|
| Código | GitHub `wap-people/destaques-do-ano` (branch `main`, publicado pelo Pages a partir da raiz) |
| Site | `https://wap-people.github.io/destaques-do-ano/` (escolha), `/wap/`, `/freso/`, `/admin.html`, `/resultado.html` |
| Banco de produção | Supabase `votacao-destaques-prod` (ref `ldevfxatmnrlgedltfrl`, região sa-east-1) |
| Banco de homologação | Supabase `votacao-destaques-homolog` (ref `zpoishwsmiijfqaevpfc`), só com dados sintéticos |
| Migrations | `supabase/migrations/` (aplicadas nas duas bases, na ordem dos nomes) |
| Testes SQL | `supabase/tests/01_regras.sql` (aceite) e `02_sinteticos.sql` (1.100 pessoas fictícias, **só homologação**) |
| Votação de teste (pública, fictícia) | `/teste/wap/` e `/teste/freso/`: mesmo `voto.js` com `<html data-teste>` e `assets/js/simulador-teste.js`. Não carrega o Supabase e a CSP bloqueia conexões; a sessão usa chave própria (`-TESTE`) |
| Teste de carga | `scripts/carga.ps1` |
| Servidor local | `scripts/servidor-local.ps1` (porta 8080) |

Para conceder ou remover admin, crie o usuário em Supabase → Authentication → Users e depois rode:
```sql
insert into public.admins (user_id) select id from auth.users where lower(email) = '<email>' on conflict do nothing;
```

---

## 3. Situação em 24/11/2026

| | WAP | Freso |
|---|---|---|
| Base de ativos | importada: 834 linhas, 812 elegíveis | **falta importar** (aguardando a planilha) |
| Lista High Potential | **falta importar** | **falta importar** |
| Status | rascunho, piloto já zerado (0 votos) | rascunho |
| Período | 09/12 a 23/12 | 09/12 a 23/12 |

O front publicado é a versão `20261124a`, com o combo de efeitos Liquid Glass. Há 2 admins cadastrados na produção.

### Pendências
- [ ] **Supabase de produção → Authentication → URL Configuration:**
  - Site URL: `https://wap-people.github.io/destaques-do-ano/admin.html`.
  - Redirect URLs: `.../admin.html` e `.../resultado.html`.
  - Desligar **Allow new users to sign up**.
  - Ainda não foi confirmado que isso já foi feito.
- [ ] Importar a base da Freso pelo admin, com **Freso** selecionado no seletor.
- [ ] Importar a lista High Potential de cada empresa.
- [ ] Confirmar com o RH as premissas adotadas:
  - a Freso usa as mesmas categorias e textos;
  - a data de corte é 30/11/2026;
  - "vira Matriz" vale só para a WAP.
- [ ] Um ou dois dias antes de 09/12, conferir se o projeto Supabase não foi pausado (o plano Free pausa após 7 dias sem uso).
- [ ] **09/12:** abrir a votação de cada empresa pelo admin.
- [ ] **Depois de 23/12:**
  - encerrar a votação;
  - gerar a ata e o CSV;
  - fazer backup;
  - decidir sobre a LGPD: `Anonimizar base` no admin, que troca os hashes por valores aleatórios.

---

## 4. Como trabalhar no projeto

### Preparar a máquina
1. Aceite os convites do **GitHub** (repositório) e do **Supabase** (organização), que chegam por e-mail.
2. Clone o repositório:
   ```powershell
   git clone https://github.com/wap-people/destaques-do-ano.git
   ```
3. Não há build nem dependências: é HTML, CSS e JS puro. As bibliotecas vêm por CDN, com versão fixa e SRI.
4. *(Opcional)* No Claude Code, conecte o conector do Supabase com a sua própria conta. Assim é possível rodar SQL e aplicar migrations nas duas bases.

### Rodar localmente
```powershell
powershell -ExecutionPolicy Bypass -File scripts/servidor-local.ps1 -Porta 8080
```
Abra `http://localhost:8080/wap/index.html`. O servidor local não resolve `index.html` sozinho em subpastas; no Pages, `/wap/` funciona.

**Atenção:** o `config.js` aponta para a **produção**. Para testar sem risco, troque localmente para a homologação (os dados estão comentados no próprio arquivo) e **não faça commit dessa troca**.

O pacote de continuidade (enviado à parte, fora do git) traz três arquivos:
- `.claude/launch.json`: configuração do servidor local para o painel de preview do Claude Code.
- `preview.local.html` + `assets/js/mock.local.js`: tela de votação com RPCs simuladas e nomes fictícios, para mexer no visual sem banco.
- `dados/manual-freso.pdf`: manual da marca Freso, usado no tema.

Os nomes com `.local.` e a pasta `.claude/` são ignorados pelo git de propósito.

### Publicar uma alteração no front
1. Mudou JS ou CSS? Troque a versão `?v=AAAAMMDDx` em **todos** os lugares: os imports de `assets/js/*.js`, o `<script type="module">` e os `<link>` de CSS de cada HTML. O valor é o mesmo em todos. A versão atual é `20261124d`.
2. Faça commit e push na `main`. O Pages publica em cerca de 1 minuto.
3. Confira o site publicado (a versão nova deve carregar) nos temas claro e escuro e no celular.

### Detalhes que já causaram problema
- **CSP rígida em todos os HTML:** não há `<style>` inline nem atributo `style=""`, porque eles são bloqueados. O CSS fica em arquivo. Atribuir `element.style` via JS é permitido.
- A página raiz (`index.html`) não roda JS (`script-src 'none'`).
- O Supabase tem **pg_safeupdate**: todo `UPDATE` e `DELETE` precisa de `WHERE`.
- `interno.votacao_aberta(empresa)` exige status `aberta` **e** a hora atual dentro do período. Só abrir não basta se o período não tiver começado.
- Na tabela `pessoas`, as colunas de situação são `ativo` e `elegivel`; a data em `importacoes` é `feito_em`.
- As animações das gotas do fundo ficam desligadas abaixo de 600 px, por desempenho. Não use filtro SVG (`url(#...)`) no fundo: o Chrome o redesenha por software e a nitidez muda depois de cliques.
- Não anime `opacity` ou `filter` num elemento que **contém** painéis `.glass`: enquanto a animação roda, o `backdrop-filter` dos painéis para de desfocar o fundo e "volta" de uma vez no fim (era a troca de nitidez ~1 s após o clique no admin). Anime o próprio painel.

### Mudanças no banco
- Toda alteração entra como **nova migration** em `supabase/migrations/` (`AAAAMMDDHHMMSS_nome.sql`). Nunca edite uma migration já aplicada.
- Aplique primeiro na **homologação**, rode `supabase/tests/01_regras.sql` (precisa terminar em `TODOS_OK`) e só então aplique na produção.
- Com a votação **aberta**, evite qualquer mudança de esquema na produção.
- Antes de qualquer ação destrutiva (zerar, anonimizar, reimportar base), alinhe com o RH.

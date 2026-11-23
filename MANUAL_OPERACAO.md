# Manual de operação · Destaques do Ano 2026

Guia para o RH e a comissão. Endereços (preencher após a publicação):

- Votação: `https://<conta>.github.io/<repositorio>/`
- Resultado (comissão): `.../resultado.html`
- Administração: `.../admin.html`

---

## 1. Antes de abrir

### 1.1 Acordar o projeto (plano gratuito)
O Supabase Free **pausa o projeto após 7 dias sem uso**. Um ou dois dias antes da abertura, entre no painel do Supabase e confira se o projeto está ativo (se estiver pausado, clique em *Restore*). Faça o mesmo se a votação ficar parada por muitos dias.

### 1.2 Importar a base de ativos
1. Abra `admin.html` e entre com seu e-mail e senha.
2. Aba **Base de ativos** → escolha a planilha (ex.: *base atualizada - forms.xlsx*).
3. Confira o **mapeamento de colunas**. O sistema já reconhece: Matrícula, Nome, Data Admissão, Local Pgto-Descrição (unidade), Cargo Básico-Descrição, Centro Custo-Descrição (setor), ID Federal (CPF) e Data Nascimento.
4. Clique em **Gerar prévia** e confira:
   - novos / atualizados / reativados / **desligados** / inelegíveis / ignorados;
   - a tabela **Normalização das unidades** (Antonio Singer, Afonso Pena, Externo e Home Office viram **Matriz**);
   - a lista de inelegíveis com o motivo (aprendiz, estagiário, temporário, admitido após 30/11/2026).
5. Se aparecer o alerta vermelho de **muitos desligamentos**, pare e confira se é a planilha certa.
6. Clique em **Confirmar importação**.

> A planilha é lida só no navegador. Ela não é enviada para o GitHub nem fica salva no site. O CPF é transformado em um código irreversível (hash) dentro do banco.

### 1.3 Importar a lista High Potential 2026
Aba **High Potential** → planilha com CPF **ou** matrícula. A prévia avisa quem está na lista mas não é elegível e quem não foi encontrado. Cada importação **substitui** a lista anterior.

> Use o CPF quando puder: a base tem matrículas repetidas entre empresas, e nesses casos a matrícula sozinha não identifica a pessoa.

### 1.4 Conferir a configuração
Aba **Configuração**: período (horário de Brasília) e regra de auto-voto (padrão: **não** pode votar em si mesmo).

### 1.5 Piloto
1. Abra a votação (ver 2.1) só para o grupo do piloto e peça que votem.
2. Confira o resultado em `resultado.html`.
3. Encerre e use **Painel → Zona de cuidado → Zerar votos do piloto** (digite `ZERAR VOTOS`). A votação volta para *rascunho* e todos podem votar de novo.

---

## 2. Durante a votação

### 2.1 Abrir / encerrar / reabrir
**Painel** → botão **Abrir votação** (ou Encerrar / Reabrir). São duas confirmações; na segunda é preciso digitar a palavra pedida. A votação só aceita votos com status *Aberta* **e** dentro do período configurado.

### 2.2 Atualizar a base (admissões, desligamentos)
Pode reimportar a planilha a qualquer momento, pelo mesmo fluxo do item 1.2.
- Quem **sumiu** da planilha é marcado como desligado (nada é apagado).
  - Os votos que essa pessoa **recebeu** passam a aparecer como *Anulados (desligado)* e o ranking é recalculado na hora.
  - Quem votou nela **não** pode votar de novo.
  - Se ela ainda não tinha votado, não consegue mais votar. Se já votou, os votos dela continuam valendo (não há como identificá-los).
- Se alguém foi desligado por erro, basta reimportar com a pessoa de volta: os votos dela voltam a contar.

### 2.3 Dúvidas dos colaboradores
- *"Diz que não foi possível validar meus dados"*: a mensagem é a mesma para CPF fora da base, data de nascimento errada, inelegível, desligado ou quem já votou (isso protege a privacidade). Confira com a pessoa se ela está na planilha, se é efetiva e se a data de nascimento está certa no cadastro.
- *"Errei a data várias vezes"*: depois de 5 erros o CPF fica bloqueado por 15 minutos.
- *"Minha sessão expirou"*: a cédula vale 20 minutos depois da identificação; é só se identificar de novo (enquanto não confirmar, nada é gravado).
- *"Quero mudar meu voto"*: não é possível; cada pessoa vota uma única vez.

---

## 3. Resultado e ata
- `resultado.html` atualiza sozinho a cada 30 segundos. Filtre por categoria e unidade.
- **Empate** no 1º lugar aparece sinalizado: a decisão é da comissão.
- **Exportar CSV**: baixa a apuração completa.
- **Gerar ata**: abre a página da ata; use *Imprimir / salvar PDF* do navegador.
- A linha *Conferência* deve estar **OK** (a soma de indicações nunca passa de cédulas × 15).

---

## 4. Encerramento (nesta ordem)
1. **Encerrar** a votação no Painel.
2. **Gerar a ata** (PDF) e **Exportar CSV**. Guarde os dois em local seguro do RH.
3. **Backup**: o plano gratuito não faz backup automático. Peça ao responsável técnico um `supabase db dump` ou guarde o CSV.
4. **Limpeza LGPD** (decisão do RH): **Painel → Zona de cuidado → Anonimizar base** (digite `ANONIMIZAR`). Os códigos de CPF e nascimento viram valores aleatórios e as sessões são apagadas. Depois disso ninguém consegue mais entrar. Não pode ser desfeito.
   - Alternativa mais forte: o responsável técnico apaga as tabelas `votos` e `pessoas` depois que a ata estiver congelada.

---

## 5. Segurança e privacidade
- O voto é anônimo: o banco não guarda ligação entre quem votou e em quem votou.
- Restrinja o acesso ao painel do Supabase a **1 ou 2 pessoas**. Quem tem acesso de superusuário ao banco poderia, em teoria, tentar correlacionar a ordem física das linhas; por isso a anonimização no encerramento.
- Nunca compartilhe a chave `service_role` do Supabase nem coloque planilhas no repositório.
- Admins são cadastrados pelo responsável técnico (convite por e-mail). Cada admin define a própria senha pelo link do convite.

## 6. Limitações do plano gratuito
- Pausa após 7 dias sem uso (ver 1.1).
- Sem backup automático (ver 4.3).
- Até 2 projetos ativos: homologação e produção.

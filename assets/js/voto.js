// Página de votação (pública).
import {
  criarCliente, rpc, h, $, limpar, icone, toast, confirmar, carregando,
  cpfValido, mascaraCpf, mascaraData, dataBrParaIso, soDigitos,
  fmtDataHora, nomeBonito, iniciais, chave, CORES_CATEGORIA,
} from './comum.js?v=20261123c';

const REGRAS = 'A votação é exclusiva para colaboradores efetivos admitidos até 30/11/2026. ' +
  'Colaboradores temporários ou terceiros não podem participar. Cada colaborador pode escolher até três pessoas ' +
  'em cada categoria, representando quem mais se destacou ao longo do ano. O voto é anônimo.';
// Cada página de votação declara a empresa em <html data-empresa="WAP|FRESO">.
const EMPRESA = (document.documentElement.dataset.empresa || 'WAP').toUpperCase();
const CHAVE_SESSAO = 'destaques-cedula-' + EMPRESA;
// Caminho do símbolo da marca, relativo a este arquivo (funciona na raiz e em /freso/).
const SIMBOLO = document.documentElement.dataset.simbolo || new URL('../img/simbolo-barras.svg', import.meta.url).href;
const SELO = document.documentElement.dataset.selo || 'Time Legendário';

const app = $('#app');
let cliente;
let info = null;          // info_publica()
let ced = null;           // { token, expira_em, primeiro_nome, unidade, max, pessoas, categorias }
let escolhas = {};        // { COD: [id, ...] }
let passo = 0;            // índice da categoria; categorias.length = revisão
let enviando = false;

// ------------------------------------------------------------------ estado local (só sessionStorage, nunca localStorage)
function salvarEstado() {
  try { sessionStorage.setItem(CHAVE_SESSAO, JSON.stringify({ ced, escolhas, passo })); } catch { /* sem armazenamento: segue em memória */ }
}
function limparEstado() {
  ced = null; escolhas = {}; passo = 0;
  try { sessionStorage.removeItem(CHAVE_SESSAO); } catch { /* nada */ }
}
function restaurarEstado() {
  try {
    const s = JSON.parse(sessionStorage.getItem(CHAVE_SESSAO) || 'null');
    if (s && s.ced && new Date(s.ced.expira_em) > new Date()) { ced = s.ced; escolhas = s.escolhas || {}; passo = s.passo || 0; return true; }
  } catch { /* nada */ }
  limparEstado();
  return false;
}

function mostrar(...secoes) {
  limpar(app).append(...secoes);
  window.scrollTo(0, 0);
  const atual = app.querySelector('.stepper [aria-current="step"]');
  if (atual) { const st = atual.parentElement; st.scrollLeft = atual.offsetLeft - (st.clientWidth - atual.offsetWidth) / 2; }
  const foco = app.querySelector('[data-foco]') || app.querySelector('h1, h2');
  if (foco) { foco.setAttribute('tabindex', '-1'); foco.focus({ preventScroll: true }); }
}

function titulo(texto, nivel = 'h1') {
  return h('div', { class: 'titulo-barras' },
    h('img', { class: 'barras', src: SIMBOLO, alt: '', width: 40, height: 22 }),
    h(nivel, { class: nivel === 'h1' ? 'display' : '' }, texto));
}

// ------------------------------------------------------------------ 1. Boas-vindas
function telaBoasVindas() {
  const aberta = info.aberta_agora;
  const agora = new Date();
  let situacao;
  if (aberta) situacao = h('div', { class: 'alert alert-ok' }, h('strong', {}, 'Votação aberta'), `Até ${fmtDataHora(info.fim)}.`);
  else if (info.status === 'encerrada' || (info.fim && new Date(info.fim) < agora))
    situacao = h('div', { class: 'alert' }, h('strong', {}, 'Votação encerrada'), 'Obrigado a todos que participaram!');
  else situacao = h('div', { class: 'alert alert-aviso' }, h('strong', {}, 'A votação ainda não começou'),
    info.inicio ? `Abre em ${fmtDataHora(info.inicio)} e vai até ${fmtDataHora(info.fim)}.` : 'Aguarde o comunicado do RH.');

  mostrar(h('section', { class: 'glass panel fade-in stack' },
    h('p', { class: 'label' }, SELO),
    titulo(info.nome_eleicao),
    h('p', {}, 'Chegou a hora de reconhecer quem fez a diferença em 2026. Escolha quem mais se destacou em cada categoria.'),
    situacao,
    h('div', { class: 'alert' }, h('strong', {}, 'Regras'), REGRAS),
    h('div', { class: 'stack' },
      h('h2', {}, 'Categorias'),
      ...info.categorias.map((c, i) => h('details', { class: 'box' },
        h('summary', {}, h('span', { class: 'cat-num', style: { background: CORES_CATEGORIA[i % 5], width: '6px', height: '1.2em', marginRight: '10px', display: 'inline-block', borderRadius: '3px' } }), c.nome),
        h('p', { class: 'muted small' }, c.descricao)))),
    aberta ? h('div', { class: 'row row-end' },
      h('button', { class: 'btn', type: 'button', onclick: telaIdentificacao }, 'Quero votar', icone('seta'))) : null,
  ));
}

// ------------------------------------------------------------------ 2. Identificação
function telaIdentificacao(msgErro) {
  if (msgErro instanceof Event) msgErro = null;
  const inCpf = h('input', { class: 'input', id: 'cpf', name: 'cpf', inputmode: 'numeric', autocomplete: 'off', placeholder: '000.000.000-00', maxlength: 14, required: true, 'aria-describedby': 'cpf-erro', 'data-foco': true });
  const erCpf = h('div', { class: 'erro-campo', id: 'cpf-erro', 'aria-live': 'polite' });
  const inNasc = h('input', { class: 'input', id: 'nasc', name: 'nasc', inputmode: 'numeric', autocomplete: 'off', placeholder: 'dd/mm/aaaa', maxlength: 10, required: true, 'aria-describedby': 'nasc-erro' });
  const erNasc = h('div', { class: 'erro-campo', id: 'nasc-erro', 'aria-live': 'polite' });
  const erGeral = h('div', { role: 'alert' });
  const btn = h('button', { class: 'btn btn-block', type: 'submit' }, 'Continuar');

  const valCpf = (final) => {
    const d = soDigitos(inCpf.value);
    let msg = '';
    if (d.length === 11 && !cpfValido(d)) msg = 'CPF inválido. Confira os números.';
    else if (final && d.length < 11) msg = 'Digite os 11 números do CPF.';
    erCpf.textContent = msg; inCpf.setAttribute('aria-invalid', msg ? 'true' : 'false');
    return !msg && d.length === 11;
  };
  const valNasc = (final) => {
    const v = inNasc.value;
    let msg = '';
    if ((final || v.length === 10) && !dataBrParaIso(v)) msg = 'Data inválida. Use dd/mm/aaaa.';
    erNasc.textContent = msg; inNasc.setAttribute('aria-invalid', msg ? 'true' : 'false');
    return !msg && !!dataBrParaIso(v);
  };
  inCpf.addEventListener('input', () => { inCpf.value = mascaraCpf(inCpf.value); valCpf(false); if (soDigitos(inCpf.value).length === 11 && cpfValido(inCpf.value)) inNasc.focus(); });
  inNasc.addEventListener('input', () => { inNasc.value = mascaraData(inNasc.value); valNasc(false); });

  const form = h('form', { class: 'stack', novalidate: true, onsubmit: async (e) => {
    e.preventDefault();
    limpar(erGeral);
    const ok1 = valCpf(true), ok2 = valNasc(true);
    if (!ok1) return inCpf.focus();
    if (!ok2) return inNasc.focus();
    carregando(btn, true);
    try {
      const r = await rpc(cliente, 'iniciar_votacao', { p_empresa: EMPRESA, p_cpf: soDigitos(inCpf.value), p_nascimento: dataBrParaIso(inNasc.value) });
      if (!r || !r.ok) {
        erGeral.append(h('div', { class: 'alert alert-erro' }, (r && r.mensagem) || 'Não foi possível continuar.'));
        if (r && r.codigo === 'fechada') { info = await rpc(cliente, 'info_publica', { p_empresa: EMPRESA }); }
        return;
      }
      ced = {
        token: r.token, expira_em: r.expira_em, primeiro_nome: r.primeiro_nome, unidade: r.unidade,
        max: r.max_por_categoria || 3, pessoas: r.pessoas, categorias: r.categorias,
      };
      escolhas = Object.fromEntries(ced.categorias.map((c) => [c.codigo, []]));
      passo = 0;
      inCpf.value = ''; inNasc.value = '';
      salvarEstado();
      telaCategoria();
    } catch (err) {
      erGeral.append(h('div', { class: 'alert alert-erro' }, err.message));
    } finally {
      if (btn.isConnected) carregando(btn, false, 'Continuar');
    }
  } },
    h('div', { class: 'field' }, h('label', { for: 'cpf' }, 'CPF'), inCpf, erCpf),
    h('div', { class: 'field' }, h('label', { for: 'nasc' }, 'Data de nascimento'), inNasc, erNasc),
    h('div', { class: 'alert small' }, h('strong', {}, 'Seus dados estão protegidos (LGPD)'),
      'O CPF e a data de nascimento servem só para garantir um voto por pessoa. Eles não ficam ligados às suas escolhas: o voto é anônimo.'),
    erGeral,
    msgErro ? h('div', { class: 'alert alert-erro', role: 'alert' }, msgErro) : null,
    btn,
    h('button', { class: 'btn btn-ghost btn-block', type: 'button', onclick: telaBoasVindas }, icone('voltar'), 'Voltar'),
  );

  mostrar(h('section', { class: 'glass panel fade-in' },
    titulo('Identificação', 'h1'),
    h('p', { class: 'muted' }, 'Informe seus dados para liberar a cédula.'),
    form));
}

// ------------------------------------------------------------------ 3. Cédula
function stepper() {
  const total = ced.categorias.length;
  return h('nav', { class: 'stepper glass', 'aria-label': 'Etapas da votação' },
    ...ced.categorias.map((c, i) => h('button', {
      type: 'button', 'aria-current': i === passo ? 'step' : null,
      onclick: () => { passo = i; salvarEstado(); telaCategoria(); },
    }, c.nome, h('span', { class: 'n', 'aria-label': `${escolhas[c.codigo].length} escolhidos` }, escolhas[c.codigo].length))),
    h('button', { type: 'button', 'aria-current': passo === total ? 'step' : null, onclick: () => { passo = total; salvarEstado(); telaRevisao(); } }, 'Revisão'));
}

function verificarExpiracao() {
  if (ced && new Date(ced.expira_em) <= new Date()) {
    limparEstado();
    telaIdentificacao('Sua sessão expirou (20 minutos). Identifique-se novamente.');
    return true;
  }
  return false;
}

function telaCategoria() {
  if (verificarExpiracao()) return;
  if (passo >= ced.categorias.length) return telaRevisao();
  const cat = ced.categorias[passo];
  const cor = CORES_CATEGORIA[passo % 5];
  const sel = escolhas[cat.codigo];
  const max = ced.max;

  const contador = h('span', { class: 'contador', 'aria-live': 'polite' });
  const chips = h('div', { class: 'chips', 'aria-label': 'Escolhidos' });
  const lista = h('ul', { class: 'lista', role: 'list' });
  const busca = h('input', { class: 'input', type: 'search', placeholder: 'Buscar por nome ou setor', 'aria-label': 'Buscar por nome ou setor', autocomplete: 'off' });

  const candidatos = cat.candidatos.map((idx) => {
    const [id, nome, setor] = ced.pessoas[idx];
    return { id, nome, setor, k: chave(nome + ' ' + setor) };
  });
  const porId = new Map(candidatos.map((c) => [c.id, c]));
  const botoes = new Map();

  function atualizar() {
    contador.textContent = `${sel.length} de ${max}`;
    contador.classList.toggle('cheio', sel.length >= max);
    limpar(chips).append(...sel.map((id) => h('span', { class: 'chip' }, nomeBonito(porId.get(id)?.nome),
      h('button', { type: 'button', 'aria-label': `Remover ${nomeBonito(porId.get(id)?.nome)}`, onclick: () => alternar(id) }, '×'))));
    for (const [id, b] of botoes) {
      const marcado = sel.includes(id);
      b.setAttribute('aria-pressed', marcado ? 'true' : 'false');
      b.disabled = !marcado && sel.length >= max;
    }
    const n = $('.stepper [aria-current="step"] .n');
    if (n) n.textContent = sel.length;
  }
  function alternar(id) {
    const i = sel.indexOf(id);
    if (i >= 0) sel.splice(i, 1);
    else if (sel.length >= max) { toast(`Você já escolheu ${max} pessoas nesta categoria.`); return; }
    else sel.push(id);
    salvarEstado();
    atualizar();
  }
  function filtrar() {
    const q = chave(busca.value);
    let vis = 0;
    for (const c of candidatos) {
      const li = botoes.get(c.id).parentElement;
      const ok = !q || c.k.includes(q);
      li.hidden = !ok; if (ok) vis++;
    }
    semRes.hidden = vis > 0;
  }

  const frag = document.createDocumentFragment();
  for (const c of candidatos) {
    const b = h('button', { class: 'cand', type: 'button', 'aria-pressed': 'false', onclick: () => alternar(c.id) },
      h('span', { class: 'ini', 'aria-hidden': 'true' }, iniciais(c.nome)),
      h('span', {}, h('span', { class: 'nm' }, nomeBonito(c.nome)), c.setor ? h('span', { class: 'st' }, c.setor) : null),
      h('span', { class: 'chk', 'aria-hidden': 'true' }, icone('check')));
    botoes.set(c.id, b);
    frag.append(h('li', {}, b));
  }
  const semRes = h('li', { class: 'vazio', hidden: true }, 'Ninguém encontrado com esse nome.');
  if (!candidatos.length) lista.append(h('li', { class: 'vazio' }, 'Não há pessoas elegíveis nesta categoria para você. Siga para a próxima.'));
  else { lista.append(frag, semRes); busca.addEventListener('input', filtrar); }

  const ultimo = passo === ced.categorias.length - 1;
  mostrar(
    stepper(),
    h('section', { class: 'glass panel fade-in stack' },
      h('div', { class: 'cat-head' },
        h('span', { class: 'cat-num', style: { background: cor } }),
        h('div', {},
          h('p', { class: 'label' }, `Categoria ${passo + 1} de ${ced.categorias.length}`),
          h('h1', { 'data-foco': true }, cat.nome),
          h('p', { class: 'cat-desc' }, cat.descricao))),
      h('div', { class: 'row' },
        h('span', { class: 'muted small' }, cat.escopo === 'unidade'
          ? ['Mostrando colaboradores da unidade ', h('strong', {}, ced.unidade)]
          : (cat.codigo === 'HIPO' ? 'Participantes do programa High Potential 2026, de todas as unidades' : 'Colaboradores de todas as unidades')),
        h('span', { class: 'spacer' }),
        h('span', { class: 'muted small' }, 'Escolhidos: '), contador),
      chips,
      candidatos.length ? h('div', { class: 'busca' }, icone('busca'), busca) : null,
      lista,
      h('p', { class: 'muted small' }, `Escolha até ${max} pessoas. Pode deixar em branco se preferir.`)),
    h('div', { class: 'barra-acoes glass' },
      h('button', { class: 'btn btn-ghost', type: 'button', disabled: passo === 0, onclick: () => { passo--; salvarEstado(); telaCategoria(); } }, icone('voltar'), 'Anterior'),
      h('span', { class: 'muted small saudacao' }, `Olá, ${ced.primeiro_nome}`),
      h('button', { class: 'btn', type: 'button', onclick: () => { passo++; salvarEstado(); ultimo ? telaRevisao() : telaCategoria(); } },
        ultimo ? 'Revisar' : 'Próxima', icone('seta'))),
  );
  atualizar();
}

// ------------------------------------------------------------------ 4. Revisão
function telaRevisao() {
  if (verificarExpiracao()) return;
  passo = ced.categorias.length;
  const mapa = new Map(ced.pessoas.map(([id, nome]) => [id, nome]));
  const vazias = ced.categorias.filter((c) => escolhas[c.codigo].length === 0);
  const total = ced.categorias.reduce((s, c) => s + escolhas[c.codigo].length, 0);
  const erro = h('div', { role: 'alert' });
  const btn = h('button', { class: 'btn', type: 'button', disabled: total === 0 }, icone('check'), 'Confirmar voto');

  let perguntando = false;
  btn.addEventListener('click', async () => {
    if (enviando || perguntando) return;
    if (vazias.length) {
      perguntando = true;
      const ok = await confirmar({
        titulo: 'Há categorias em branco',
        texto: `Você não escolheu ninguém em: ${vazias.map((c) => c.nome).join(', ')}. Depois de confirmar não é possível alterar. Deseja enviar mesmo assim?`,
        ok: 'Enviar assim mesmo', cancelar: 'Voltar e revisar',
      }).finally(() => { perguntando = false; });
      if (!ok) return;
    }
    enviar(btn, erro);
  });

  mostrar(
    stepper(),
    h('section', { class: 'glass panel fade-in stack' },
      titulo('Revise seu voto'),
      h('p', { class: 'muted' }, 'Confira suas escolhas. Depois de confirmar, o voto não pode ser alterado.'),
      ...ced.categorias.map((c, i) => h('div', { class: 'resumo-cat' },
        h('div', { class: 'resumo-topo' },
          h('h3', {}, c.nome),
          h('button', { class: 'btn btn-ghost btn-sm', type: 'button', onclick: () => { passo = i; salvarEstado(); telaCategoria(); } }, 'Alterar')),
        escolhas[c.codigo].length
          ? h('div', { class: 'chips' }, ...escolhas[c.codigo].map((id) => h('span', { class: 'chip' }, nomeBonito(mapa.get(id)))))
          : h('span', { class: 'badge badge-aviso' }, 'Em branco'))),
      total === 0 ? h('div', { class: 'alert alert-aviso' }, 'Escolha ao menos uma pessoa em alguma categoria para enviar.') : null,
      erro),
    h('div', { class: 'barra-acoes glass' },
      h('button', { class: 'btn btn-ghost', type: 'button', onclick: () => { passo = ced.categorias.length - 1; salvarEstado(); telaCategoria(); } }, icone('voltar'), 'Voltar'),
      btn),
  );
}

async function enviar(btn, erro) {
  if (enviando) return;           // proteção contra duplo envio
  enviando = true;
  carregando(btn, true);
  limpar(erro);
  try {
    const payload = Object.fromEntries(ced.categorias.map((c) => [c.codigo, escolhas[c.codigo]]));
    const r = await rpc(cliente, 'registrar_cedula', { p_token: ced.token, p_escolhas: payload });
    if (r && r.ok) {
      limparEstado();
      telaComprovante(r.protocolo);
      return;
    }
    if (r && r.codigo === 'sessao_expirada') {
      limparEstado();
      telaIdentificacao(r.mensagem);
      return;
    }
    if (r && (r.codigo === 'recusado' || r.codigo === 'fechada')) limparEstado();
    erro.append(h('div', { class: 'alert alert-erro' }, (r && r.mensagem) || 'Não foi possível registrar o voto.'));
    if (!ced) btn.remove();
  } catch (e) {
    // Falha de rede: o voto pode ou não ter sido gravado. Não reenvia sozinho.
    erro.append(h('div', { class: 'alert alert-erro' }, e.message,
      ' Se o problema continuar, tente de novo: se o voto já tiver sido registrado, o sistema avisará.'));
  } finally {
    enviando = false;
    if (btn.isConnected) carregando(btn, false, 'Confirmar voto');
  }
}

// ------------------------------------------------------------------ 5. Comprovante
function telaComprovante(protocolo) {
  mostrar(h('section', { class: 'glass panel fade-in stack', 'aria-live': 'assertive' },
    h('div', { class: 'check-grande' }, icone('check')),
    h('h1', { 'data-foco': true }, 'Voto registrado com sucesso'),
    h('p', {}, 'Obrigado por reconhecer quem faz a diferença. Juntos não existe impossível!'),
    h('div', { class: 'resumo-cat' },
      h('p', { class: 'label' }, 'Protocolo'),
      h('p', { class: 'protocolo' }, protocolo),
      h('p', { class: 'muted small' }, 'Este código não identifica você nem suas escolhas. Ele só confirma que a cédula foi recebida.')),
    h('div', { class: 'row row-end' }, h('button', { class: 'btn btn-ghost', type: 'button', onclick: telaBoasVindas }, 'Concluir'))));
}

// ------------------------------------------------------------------ início
async function iniciar() {
  try {
    cliente = criarCliente();
    info = await rpc(cliente, 'info_publica', { p_empresa: EMPRESA });
    const badge = $('#status-badge');
    badge.hidden = false;
    badge.className = 'badge ' + (info.aberta_agora ? 'badge-ok' : 'badge-aviso');
    badge.replaceChildren(h('span', { class: 'dot' }), info.aberta_agora ? 'Aberta' : (info.status === 'encerrada' ? 'Encerrada' : 'Fechada'));
    if (info.aberta_agora && restaurarEstado()) {
      passo >= ced.categorias.length ? telaRevisao() : telaCategoria();
    } else {
      telaBoasVindas();
    }
  } catch (e) {
    mostrar(h('section', { class: 'glass panel stack' },
      h('h1', {}, 'Não foi possível carregar'),
      h('p', { class: 'muted' }, e.message),
      h('button', { class: 'btn', type: 'button', onclick: () => location.reload() }, 'Tentar de novo')));
  }
}
iniciar();

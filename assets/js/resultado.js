// Painel de apuração (comissão). Polling de 30 s, sem Realtime.
import { criarCliente, rpc, h, $, limpar, icone, toast, fmtDataHora, fmtData, fmtNum, nomeBonito, baixarArquivo, csv, carregando, EMPRESAS } from './comum.js?v=20261123c';
import { exigirLogin, botaoSair } from './auth.js?v=20261123c';

const app = $('#app');
const cliente = criarCliente({ comLogin: true });
const INTERVALO = 30000;
let dados = null;
let filtroCat = '';
let filtroUni = '';
let timer = null;
let empresa = (() => { try { return sessionStorage.getItem('destaques-admin-empresa') || 'WAP'; } catch { return 'WAP'; } })();
const nomeEmpresa = () => (EMPRESAS.find((e) => e.codigo === empresa) || {}).nome || empresa;

function seletorEmpresa() {
  return h('div', { class: 'tabs glass no-print', role: 'tablist', 'aria-label': 'Empresa' },
    ...EMPRESAS.map((e) => h('button', {
      role: 'tab', type: 'button', 'aria-selected': e.codigo === empresa ? 'true' : 'false',
      onclick: async () => {
        if (e.codigo === empresa) return;
        empresa = e.codigo; filtroCat = ''; filtroUni = '';
        try { sessionStorage.setItem('destaques-admin-empresa', empresa); } catch { /* nada */ }
        await atualizar();
      },
    }, e.nome)));
}

function kpi(rot, valor, sub) {
  return h('div', { class: 'kpi' }, h('div', { class: 'label' }, rot), h('div', { class: 'v' }, valor), sub ? h('div', { class: 'muted small' }, sub) : null);
}

function cartaoGrupo(g) {
  const max = Math.max(1, ...g.ranking.map((r) => r.votos), g.anulados);
  const itens = g.ranking.map((r) => {
    const barra = h('i'); barra.style.width = `${(100 * r.votos / max).toFixed(1)}%`;
    return h('li', { class: r.posicao === 1 ? 'lider' : '' },
      h('span', { class: 'pos' }, `${r.posicao}º`),
      h('span', {}, h('strong', {}, nomeBonito(r.nome)), r.setor ? h('span', { class: 'muted small' }, ` · ${r.setor}`) : null),
      h('span', { class: 'num' }, fmtNum(r.votos)),
      h('span', { class: 'bar', 'aria-hidden': 'true' }, barra));
  });
  if (g.anulados > 0) {
    const barra = h('i'); barra.style.width = `${(100 * g.anulados / max).toFixed(1)}%`;
    itens.push(h('li', { class: 'anulado' }, h('span', { class: 'pos' }, '—'),
      h('span', {}, `Anulados (desligado) · ${g.candidatos_anulados} pessoa(s)`), h('span', { class: 'num' }, fmtNum(g.anulados)),
      h('span', { class: 'bar', 'aria-hidden': 'true' }, barra)));
  }
  let destaque;
  if (g.empate) destaque = h('div', { class: 'alert alert-aviso' }, h('strong', {}, 'Empate no 1º lugar'), 'A decisão fica com a comissão.');
  else if (g.vencedor) destaque = h('div', { class: 'alert alert-ok row' }, icone('trofeu'), h('span', {}, h('strong', {}, nomeBonito(g.vencedor.nome)), ` · ${fmtNum(g.vencedor.votos)} votos`));
  else destaque = h('p', { class: 'muted small' }, 'Sem votos válidos ainda.');

  return h('section', { class: 'glass panel stack' },
    h('div', { class: 'row' }, h('h2', {}, g.categoria_nome), h('span', { class: 'badge' }, g.unidade === 'GERAL' ? 'Geral' : g.unidade),
      h('span', { class: 'spacer' }), h('span', { class: 'muted small' }, `${fmtNum(g.votos_validos)} votos válidos`)),
    destaque,
    itens.length ? h('ol', { class: 'rank' }, ...itens) : null);
}

function render() {
  if (!dados) return;
  const cats = [...new Map(dados.grupos.map((g) => [g.categoria, g.categoria_nome])).entries()];
  const unis = [...new Set(dados.grupos.map((g) => g.unidade))].sort((a, b) => (a === 'GERAL') - (b === 'GERAL') || a.localeCompare(b, 'pt-BR'));
  const grupos = dados.grupos.filter((g) => (!filtroCat || g.categoria === filtroCat) && (!filtroUni || g.unidade === filtroUni));
  const pg = dados.participacao_geral;

  const selCat = h('select', { class: 'input', 'aria-label': 'Categoria', onchange: (e) => { filtroCat = e.target.value; render(); } },
    h('option', { value: '' }, 'Todas as categorias'), ...cats.map(([k, n]) => h('option', { value: k, selected: k === filtroCat }, n)));
  const selUni = h('select', { class: 'input', 'aria-label': 'Unidade', onchange: (e) => { filtroUni = e.target.value; render(); } },
    h('option', { value: '' }, 'Todas as unidades'), ...unis.map((u) => h('option', { value: u, selected: u === filtroUni }, u === 'GERAL' ? 'Geral (Ouro e HiPo)' : u)));

  limpar(app).append(
    seletorEmpresa(),
    h('section', { class: 'glass panel stack' },
      h('div', { class: 'row' },
        h('div', { class: 'titulo-barras' }, h('img', { class: 'barras', src: empresa === 'FRESO' ? 'assets/img/freso-simbolo.png' : 'assets/img/simbolo-barras.svg', alt: '', width: 40, height: 22 }), h('h1', {}, `Apuração · ${nomeEmpresa()}`)),
        h('span', { class: 'spacer' }),
        h('span', { class: 'muted small', 'aria-live': 'polite' }, `Atualizado ${fmtDataHora(dados.gerado_em)} · atualiza a cada 30 s`)),
      h('div', { class: 'kpis' },
        kpi('Cédulas', fmtNum(dados.cedulas)),
        kpi('Participação', `${pg.percentual ?? 0}%`, `${fmtNum(pg.votaram)} de ${fmtNum(pg.elegiveis)} elegíveis`),
        kpi('Votos (indicações)', fmtNum(dados.total_votos)),
        kpi('Conferência', dados.sanidade_ok ? 'OK' : 'ERRO', `soma ≤ cédulas × 15 (${fmtNum(dados.limite_votos)})`)),
      !dados.sanidade_ok ? h('div', { class: 'alert alert-erro' }, 'A soma de votos passou do limite possível. Avise o responsável técnico.') : null,
      h('div', { class: 'grid-2 no-print' }, selCat, selUni),
      h('div', { class: 'row row-end no-print' },
        h('button', { class: 'btn btn-ghost btn-sm', type: 'button', onclick: exportarCsv }, 'Exportar CSV'),
        h('button', { class: 'btn btn-sm', type: 'button', onclick: (e) => gerarAta(e.currentTarget) }, 'Gerar ata'))),
    ...grupos.map(cartaoGrupo),
    h('section', { class: 'glass panel stack' },
      h('h2', {}, 'Participação por unidade'),
      h('div', { class: 'tabela-wrap' }, h('table', {},
        h('thead', {}, h('tr', {}, h('th', {}, 'Unidade'), h('th', { class: 'num' }, 'Elegíveis'), h('th', { class: 'num' }, 'Votaram'), h('th', { class: 'num' }, '%'))),
        h('tbody', {}, ...dados.participacao.map((p) => h('tr', {}, h('td', {}, p.unidade), h('td', { class: 'num' }, fmtNum(p.elegiveis)),
          h('td', { class: 'num' }, fmtNum(p.votaram)), h('td', { class: 'num' }, `${p.percentual ?? 0}%`)))))),
      dados.por_dia.length ? h('p', { class: 'muted small' }, 'Cédulas por dia: ', dados.por_dia.map((d) => `${fmtData(d.dia)}: ${d.cedulas}`).join(' · ')) : null));
}

function linhasCsv(d) {
  const L = [['Categoria', 'Unidade', 'Posição', 'Nome', 'Setor', 'Votos', 'Observação']];
  for (const g of d.grupos) {
    for (const r of g.ranking) L.push([g.categoria_nome, g.unidade, r.posicao, r.nome, r.setor || '', r.votos,
      r.posicao === 1 ? (g.empate ? 'EMPATE' : 'VENCEDOR') : '']);
    if (g.anulados) L.push([g.categoria_nome, g.unidade, '', 'Anulados (desligado)', '', g.anulados, '']);
  }
  L.push([]); L.push(['Unidade', 'Elegíveis', 'Votaram', '%']);
  for (const p of d.participacao) L.push([p.unidade, p.elegiveis, p.votaram, p.percentual ?? 0]);
  L.push([]); L.push(['Cédulas', d.cedulas]); L.push(['Total de indicações', d.total_votos]); L.push(['Conferência', d.sanidade_ok ? 'OK' : 'ERRO']);
  return L;
}

function exportarCsv() {
  const nome = `apuracao-destaques-${empresa.toLowerCase()}-${new Date().toISOString().slice(0, 16).replace(/[:T]/g, '-')}.csv`;
  baixarArquivo(nome, csv(linhasCsv(dados)));
}

async function gerarAta(btn) {
  carregando(btn, true);
  try {
    const ata = await rpc(cliente, 'exportar_ata', { p_empresa: empresa });
    pararPolling();
    const e = ata.eleicao;
    const vencedores = ata.grupos.map((g) => h('tr', {},
      h('td', {}, g.categoria_nome), h('td', {}, g.unidade === 'GERAL' ? 'Geral' : g.unidade),
      h('td', {}, g.empate ? `EMPATE: ${g.ranking.filter((r) => r.posicao === 1).map((r) => nomeBonito(r.nome)).join(', ')}` : g.vencedor ? nomeBonito(g.vencedor.nome) : '—'),
      h('td', { class: 'num' }, g.empate ? fmtNum(g.ranking[0].votos) : g.vencedor ? fmtNum(g.vencedor.votos) : '—'),
      h('td', { class: 'num' }, fmtNum(g.votos_validos)), h('td', { class: 'num' }, fmtNum(g.anulados))));
    limpar(app).append(
      h('div', { class: 'row no-print' },
        h('button', { class: 'btn', type: 'button', onclick: () => window.print() }, 'Imprimir / salvar PDF'),
        h('button', { class: 'btn btn-ghost', type: 'button', onclick: () => { render(); iniciarPolling(); } }, 'Voltar ao painel')),
      h('section', { class: 'glass panel stack' },
        empresa === 'FRESO'
          ? h('img', { src: 'assets/img/freso-azul.png', alt: 'Freso', width: 160, height: 41 })
          : h('img', { src: 'assets/img/wap-waaw-positivo.svg', alt: 'WAP WAAW', width: 180, height: 37 }),
        h('h1', {}, `Ata de apuração · ${ata.empresa_nome} · ${e.nome_eleicao}`),
        h('p', {}, `Período: ${fmtDataHora(e.inicio)} a ${fmtDataHora(e.fim)} · Status: ${e.status}`),
        h('p', {}, `Gerada em ${ata.gerado_em_local} por ${ata.gerado_por || '—'}.`),
        h('p', {}, `Cédulas: ${fmtNum(ata.cedulas)} · Indicações: ${fmtNum(ata.total_votos)} · Participação: ${ata.participacao_geral.percentual ?? 0}% (${fmtNum(ata.participacao_geral.votaram)} de ${fmtNum(ata.participacao_geral.elegiveis)}) · Conferência: ${ata.sanidade_ok ? 'OK' : 'ERRO'}`),
        h('h2', {}, 'Vencedores'),
        h('div', { class: 'tabela-wrap' }, h('table', {},
          h('thead', {}, h('tr', {}, h('th', {}, 'Categoria'), h('th', {}, 'Unidade'), h('th', {}, 'Vencedor'), h('th', { class: 'num' }, 'Votos'), h('th', { class: 'num' }, 'Válidos'), h('th', { class: 'num' }, 'Anulados'))),
          h('tbody', {}, ...vencedores))),
        h('h2', {}, 'Rankings completos'),
        ...ata.grupos.filter((g) => g.ranking.length).map((g) => h('div', {},
          h('h3', {}, `${g.categoria_nome} · ${g.unidade === 'GERAL' ? 'Geral' : g.unidade}`),
          h('ol', {}, ...g.ranking.map((r) => h('li', {}, `${nomeBonito(r.nome)} (${r.votos})`))))),
        h('h2', {}, 'Importações e eventos'),
        h('ul', {}, ...ata.importacoes.map((i) => h('li', {}, `${fmtDataHora(i.feito_em)} · ${i.tipo}${i.tipo === 'ativos' ? ` · ${i.novos} novos, ${i.atualizados} atualizados, ${i.desligados} desligados` : ''}`))),
        h('p', { class: 'muted small' }, 'Votos em pessoas desligadas durante a votação foram anulados. Empates no 1º lugar são decididos pela comissão. O voto é anônimo: o sistema não guarda ligação entre eleitor e escolhas.'),
        h('div', { class: 'grid-2' }, h('p', {}, '_______________________________', h('br'), 'Comissão'), h('p', {}, '_______________________________', h('br'), 'RH'))));
  } catch (err) { toast(err.message, 6000); }
  finally { if (btn.isConnected) carregando(btn, false, 'Gerar ata'); }
}

async function atualizar() {
  try { dados = await rpc(cliente, 'apurar', { p_empresa: empresa }); render(); }
  catch (e) { toast('Não foi possível atualizar: ' + e.message, 5000); }
}
function iniciarPolling() { pararPolling(); timer = setInterval(() => { if (!document.hidden) atualizar(); }, INTERVALO); }
function pararPolling() { if (timer) clearInterval(timer); timer = null; }
document.addEventListener('visibilitychange', () => { if (!document.hidden && timer) atualizar(); });

exigirLogin(cliente, app, {
  titulo: 'Resultado',
  aoEntrar: async (sessao) => {
    $('#topo-acoes').append(h('span', { class: 'muted small' }, sessao.user.email), botaoSair(cliente));
    await atualizar();
    iniciarPolling();
  },
}).catch((e) => { limpar(app).append(h('section', { class: 'glass panel' }, h('div', { class: 'alert alert-erro' }, e.message))); });

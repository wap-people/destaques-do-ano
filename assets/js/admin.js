// Página de administração: importação, configuração, abertura/encerramento.
import {
  criarCliente, rpc, h, $, limpar, icone, toast, confirmar, carregando,
  fmtDataHora, fmtNum, nomeBonito, chave, soDigitos, EMPRESAS,
} from './comum.js?v=20261123c';
import { exigirLogin, botaoSair } from './auth.js?v=20261123c';

const app = $('#app');
const cliente = criarCliente({ comLogin: true });
let painel = null;
let abaAtual = 'painel';

// Empresa em administração (WAP ou Freso). Admins são os mesmos para as duas.
let empresa = (() => { try { return sessionStorage.getItem('destaques-admin-empresa') || 'WAP'; } catch { return 'WAP'; } })();
const nomeEmpresa = () => (EMPRESAS.find((e) => e.codigo === empresa) || {}).nome || empresa;
const rpcE = (nome, args = {}) => rpc(cliente, nome, { p_empresa: empresa, ...args });

function seletorEmpresa() {
  const status = Object.fromEntries((painel?.empresas || []).map((e) => [e.codigo, e]));
  return h('div', { class: 'tabs glass seletor-empresa', role: 'tablist', 'aria-label': 'Empresa' },
    ...EMPRESAS.map((e) => h('button', {
      role: 'tab', type: 'button', 'aria-selected': e.codigo === empresa ? 'true' : 'false',
      onclick: async () => {
        if (e.codigo === empresa) return;
        empresa = e.codigo;
        try { sessionStorage.setItem('destaques-admin-empresa', empresa); } catch { /* nada */ }
        await recarregar();
      },
    }, e.nome, status[e.codigo] ? h('span', { class: 'muted small' }, ` · ${ROTULO_STATUS[status[e.codigo].status]}`) : null)));
}

const CAMPOS_ATIVOS = [
  { k: 'cpf', rot: 'CPF', obrig: true, sin: ['cpf', 'id federal', 'cpf do colaborador', 'nr cpf', 'numero cpf'] },
  { k: 'nome', rot: 'Nome', obrig: true, sin: ['nome', 'nome completo', 'colaborador', 'funcionario', 'nome do colaborador'] },
  { k: 'nascimento', rot: 'Data de nascimento', obrig: true, sin: ['data nascimento', 'data de nascimento', 'nascimento', 'dt nascimento', 'dt. nascimento'] },
  { k: 'admissao', rot: 'Data de admissão', obrig: true, sin: ['data admissao', 'data de admissao', 'admissao', 'dt admissao', 'dt. admissao'] },
  { k: 'unidade', rot: 'Unidade', obrig: true, sin: ['local pgto-descricao', 'unidade', 'filial', 'estabelecimento', 'local de trabalho', 'local'] },
  { k: 'matricula', rot: 'Matrícula', sin: ['matricula', 'chapa', 'registro'] },
  { k: 'cargo', rot: 'Cargo', sin: ['cargo basico-descricao', 'cargo', 'funcao', 'cargo-descricao'] },
  { k: 'setor', rot: 'Setor', sin: ['centro custo-descricao', 'centro de custo-descricao', 'setor', 'departamento', 'area'] },
  { k: 'vinculo', rot: 'Vínculo', sin: ['vinculo', 'tipo de contrato', 'tipo contrato', 'vinculo empregaticio'] },
  { k: 'situacao', rot: 'Situação', sin: ['situacao', 'status', 'situacao do colaborador'] },
];
const CAMPOS_HIPO = [
  { k: 'cpf', rot: 'CPF', sin: ['cpf', 'id federal'] },
  { k: 'matricula', rot: 'Matrícula', sin: ['matricula', 'chapa', 'registro'] },
  { k: 'nome', rot: 'Nome (só para conferência)', sin: ['nome', 'nome completo', 'colaborador'] },
];

// ------------------------------------------------------------------ Excel
function paraIso(v) {
  if (v === null || v === undefined || v === '') return null;
  if (typeof v === 'number' && window.XLSX) {
    const d = XLSX.SSF.parse_date_code(v);
    if (!d || !d.y) return null;
    return `${String(d.y).padStart(4, '0')}-${String(d.m).padStart(2, '0')}-${String(d.d).padStart(2, '0')}`;
  }
  if (v instanceof Date) return `${v.getFullYear()}-${String(v.getMonth() + 1).padStart(2, '0')}-${String(v.getDate()).padStart(2, '0')}`;
  const s = String(v).trim();
  let m = /^(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})/.exec(s);
  if (m) return `${m[3]}-${m[2].padStart(2, '0')}-${m[1].padStart(2, '0')}`;
  m = /^(\d{4})-(\d{2})-(\d{2})/.exec(s);
  if (m) return `${m[1]}-${m[2]}-${m[3]}`;
  return null;
}
const texto = (v) => (v === null || v === undefined) ? null : String(v).trim() || null;

async function lerArquivo(file) {
  if (!window.XLSX) throw new Error('A biblioteca de planilhas não carregou. Atualize a página.');
  const buf = await file.arrayBuffer();
  const wb = XLSX.read(buf, { type: 'array' });
  return wb.SheetNames.map((nome) => {
    const linhas = XLSX.utils.sheet_to_json(wb.Sheets[nome], { header: 1, raw: true, defval: null, blankrows: false });
    let iCab = linhas.findIndex((l, i) => i < 15 && l.filter((c) => typeof c === 'string' && c.trim()).length >= 2);
    if (iCab < 0) iCab = 0;
    const cab = (linhas[iCab] || []).map((c, i) => texto(c) || `Coluna ${i + 1}`);
    return { nome, cab, dados: linhas.slice(iCab + 1).filter((l) => l.some((c) => c !== null && String(c).trim() !== '')) };
  });
}

function autoMapear(cab, campos) {
  const ks = cab.map(chave);
  const usado = new Set();
  const mapa = {};
  for (const c of campos) {
    let i = ks.findIndex((k, j) => !usado.has(j) && c.sin.includes(k));
    if (i < 0) i = ks.findIndex((k, j) => !usado.has(j) && c.sin.some((s) => k.includes(s)));
    if (i >= 0) { mapa[c.k] = i; usado.add(i); }
  }
  return mapa;
}

function montarLinhas(aba, mapa, campos) {
  return aba.dados.map((l) => {
    const o = {};
    for (const c of campos) {
      const i = mapa[c.k];
      const v = (i === undefined || i === null || i === '') ? null : l[i];
      if (c.k === 'cpf') o.cpf = v === null ? null : soDigitos(typeof v === 'number' ? Math.round(v).toString() : v);
      else if (c.k === 'nascimento' || c.k === 'admissao') o[c.k] = paraIso(v);
      else if (c.k === 'matricula') o.matricula = v === null ? null : (typeof v === 'number' ? String(Math.round(v)) : texto(v));
      else o[c.k] = texto(v);
    }
    return o;
  });
}

// ------------------------------------------------------------------ fluxo de importação genérico
function fluxoImportacao({ titulo, descricao, campos, rpcNome, renderPrevia }) {
  const area = h('div', { class: 'stack' });
  const input = h('input', { type: 'file', accept: '.xlsx,.xls,.csv', hidden: true });
  const drop = h('label', { class: 'dropzone', tabindex: 0 },
    icone('upload'), h('strong', {}, 'Escolha ou arraste a planilha (.xlsx, .xls, .csv)'),
    h('span', { class: 'muted small' }, 'O arquivo é lido só no seu navegador. Ele não é salvo em lugar nenhum.'), input);
  drop.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); input.click(); } });
  drop.addEventListener('dragover', (e) => { e.preventDefault(); drop.classList.add('over'); });
  drop.addEventListener('dragleave', () => drop.classList.remove('over'));
  drop.addEventListener('drop', (e) => { e.preventDefault(); drop.classList.remove('over'); if (e.dataTransfer.files[0]) carregar(e.dataTransfer.files[0]); });
  input.addEventListener('change', () => { if (input.files[0]) carregar(input.files[0]); input.value = ''; });

  async function carregar(file) {
    limpar(area).append(h('p', { class: 'muted' }, `Lendo ${file.name}…`));
    let abas;
    try { abas = await lerArquivo(file); } catch (e) { limpar(area).append(h('div', { class: 'alert alert-erro' }, e.message)); return; }
    let aba = abas[0];
    let mapa = autoMapear(aba.cab, campos);

    const seletorAba = abas.length > 1 ? h('select', { class: 'input', 'aria-label': 'Aba da planilha', onchange: (e) => { aba = abas[e.target.selectedIndex]; mapa = autoMapear(aba.cab, campos); desenharMapa(); } },
      ...abas.map((a) => h('option', {}, `${a.nome} (${a.dados.length} linhas)`))) : null;
    const tabMapa = h('div');
    const previa = h('div', { class: 'stack' });
    const btnPrevia = h('button', { class: 'btn', type: 'button' }, 'Gerar prévia');

    function desenharMapa() {
      limpar(tabMapa).append(h('div', { class: 'tabela-wrap' }, h('table', {},
        h('thead', {}, h('tr', {}, h('th', {}, 'Campo do sistema'), h('th', {}, 'Coluna da planilha'))),
        h('tbody', {}, ...campos.map((c) => {
          const sel = h('select', { class: 'input', 'aria-label': `Coluna para ${c.rot}`, onchange: (e) => { mapa[c.k] = e.target.value === '' ? undefined : Number(e.target.value); limpar(previa); } },
            h('option', { value: '' }, c.obrig ? '— escolha —' : '(não usar)'),
            ...aba.cab.map((nome, i) => h('option', { value: i, selected: mapa[c.k] === i }, nome)));
          return h('tr', {}, h('td', {}, c.rot, c.obrig ? h('span', { class: 'muted' }, ' *') : null), h('td', {}, sel));
        })))));
      limpar(previa);
    }

    btnPrevia.addEventListener('click', async () => {
      const faltando = campos.filter((c) => c.obrig && (mapa[c.k] === undefined));
      if (faltando.length) { toast('Faltam colunas: ' + faltando.map((c) => c.rot).join(', ')); return; }
      if (rpcNome === 'importar_hipo' && mapa.cpf === undefined && mapa.matricula === undefined) { toast('Indique a coluna de CPF ou de matrícula.'); return; }
      const linhas = montarLinhas(aba, mapa, campos);
      carregando(btnPrevia, true);
      limpar(previa);
      try {
        const r = await rpcE(rpcNome, { p_linhas: linhas, p_simular: true });
        previa.append(renderPrevia(r));
        const btnOk = h('button', { class: 'btn', type: 'button' }, icone('check'), 'Confirmar importação');
        btnOk.addEventListener('click', async () => {
          const extra = r.alerta_desligamentos ? ` ATENÇÃO: ${r.desligados} pessoas serão marcadas como desligadas.` : '';
          const ok = await confirmar({ titulo: `Confirmar importação na ${nomeEmpresa()}?`, texto: `A base da ${nomeEmpresa()} será atualizada.${extra}`, ok: 'Importar', perigo: !!r.alerta_desligamentos });
          if (!ok) return;
          carregando(btnOk, true);
          try {
            await rpcE(rpcNome, { p_linhas: linhas, p_simular: false });
            toast('Importação concluída.');
            limpar(area).append(h('div', { class: 'alert alert-ok' }, h('strong', {}, 'Importação concluída'), `${file.name} foi importado.`));
            painel = await rpcE('painel_admin');
          } catch (e) {
            previa.append(h('div', { class: 'alert alert-erro' }, e.message));
            carregando(btnOk, false, 'Confirmar importação');
          }
        });
        previa.append(h('div', { class: 'row row-end' }, btnOk));
      } catch (e) {
        previa.append(h('div', { class: 'alert alert-erro' }, e.message));
      } finally { carregando(btnPrevia, false, 'Gerar prévia'); }
    });

    limpar(area).append(
      h('div', { class: 'row' }, h('strong', {}, file.name), h('span', { class: 'muted small' }, `${aba.dados.length} linhas`), h('span', { class: 'spacer' }), seletorAba),
      h('h3', {}, 'Mapeamento de colunas'),
      h('p', { class: 'muted small' }, 'Conferimos os nomes das colunas automaticamente. Ajuste se algum campo estiver errado.'),
      tabMapa,
      h('div', { class: 'row row-end' }, btnPrevia),
      previa);
    desenharMapa();
  }

  return h('section', { class: 'glass panel stack' }, h('h2', {}, titulo), h('p', { class: 'muted' }, descricao), drop, area);
}

function kpi(rot, valor, cls = '') { return h('div', { class: 'kpi ' + cls }, h('div', { class: 'label' }, rot), h('div', { class: 'v' }, fmtNum(valor))); }
function tabela(cols, linhas, vazio = 'Nada a mostrar.') {
  if (!linhas.length) return h('p', { class: 'muted small' }, vazio);
  return h('div', { class: 'tabela-wrap' }, h('table', {},
    h('thead', {}, h('tr', {}, ...cols.map((c) => h('th', { class: c.num ? 'num' : '' }, c.rot)))),
    h('tbody', {}, ...linhas.map((l) => h('tr', {}, ...cols.map((c) => h('td', { class: c.num ? 'num' : '' }, c.f ? c.f(l) : (l[c.k] ?? '—'))))))));
}
const caixa = (titulo, n, conteudo, aberto = false) => h('details', { class: 'box', open: aberto }, h('summary', {}, `${titulo} (${fmtNum(n)})`), conteudo);

function previaAtivos(r) {
  return h('div', { class: 'stack' },
    h('h3', {}, 'Prévia (nada foi gravado ainda)'),
    r.alerta_desligamentos ? h('div', { class: 'alert alert-erro' }, h('strong', {}, 'Muitos desligamentos'),
      `${r.desligados} de ${r.ativos_antes} ativos não estão nesta planilha e seriam marcados como desligados. Confira se é a planilha certa.`) : null,
    h('div', { class: 'kpis' },
      kpi('Linhas', r.total_linhas), kpi('Novos', r.novos), kpi('Atualizados', r.atualizados), kpi('Reativados', r.reativados),
      kpi('Desligados', r.desligados), kpi('Elegíveis', r.elegiveis), kpi('Inelegíveis', r.inelegiveis), kpi('Ignorados', r.ignorados)),
    h('h3', {}, 'Normalização das unidades'),
    tabela([{ rot: 'Valor na planilha', k: 'original' }, { rot: 'Unidade final', k: 'final' }, { rot: 'Pessoas', k: 'qtd', num: true }], r.unidades),
    h('h3', {}, 'Por unidade (após importar)'),
    tabela([{ rot: 'Unidade', k: 'unidade' }, { rot: 'Total', k: 'total', num: true }, { rot: 'Elegíveis', k: 'elegiveis', num: true },
      { rot: 'Admitidos 12 meses', k: 'admitidos_12m', num: true }], r.por_unidade),
    caixa('Inelegíveis e motivo', r.lista_inelegiveis.length,
      tabela([{ rot: 'Linha', k: 'linha', num: true }, { rot: 'Nome', f: (l) => nomeBonito(l.nome) }, { rot: 'Unidade', k: 'unidade' }, { rot: 'Motivo', k: 'motivo' }], r.lista_inelegiveis)),
    caixa('Serão marcados como desligados', r.lista_desligados.length,
      tabela([{ rot: 'Nome', f: (l) => nomeBonito(l.nome) }, { rot: 'Unidade', k: 'unidade' }], r.lista_desligados), r.desligados > 0),
    caixa('Reativados', r.lista_reativados.length,
      tabela([{ rot: 'Nome', f: (l) => nomeBonito(l.nome) }, { rot: 'Unidade', k: 'unidade' }], r.lista_reativados)),
    caixa('Linhas ignoradas', r.lista_ignorados.length,
      tabela([{ rot: 'Linha', k: 'linha', num: true }, { rot: 'Nome', f: (l) => nomeBonito(l.nome) || '—' }, { rot: 'Motivo', k: 'motivo' }], r.lista_ignorados), r.ignorados > 0));
}

function previaHipo(r) {
  return h('div', { class: 'stack' },
    h('h3', {}, 'Prévia (nada foi gravado ainda)'),
    h('div', { class: 'kpis' }, kpi('Linhas', r.total_linhas), kpi('Encontrados', r.encontrados), kpi('Aparecerão na cédula', r.elegiveis),
      kpi('Não encontrados', r.lista_nao_encontrados.length)),
    r.lista_nao_elegiveis.length ? h('div', { class: 'alert alert-aviso' }, h('strong', {}, 'Na lista HiPo, mas não elegíveis'),
      'Estas pessoas estão na lista do programa, mas não aparecerão na cédula.') : null,
    caixa('Não elegíveis', r.lista_nao_elegiveis.length,
      tabela([{ rot: 'Nome', f: (l) => nomeBonito(l.nome) }, { rot: 'Unidade', k: 'unidade' }, { rot: 'Motivo', k: 'motivo' }], r.lista_nao_elegiveis), true),
    caixa('Não encontrados', r.lista_nao_encontrados.length,
      tabela([{ rot: 'Linha', k: 'linha', num: true }, { rot: 'Nome', f: (l) => nomeBonito(l.nome) || '—' }, { rot: 'Matrícula', k: 'matricula' }, { rot: 'Motivo', k: 'motivo' }], r.lista_nao_encontrados), true),
    caixa('Participantes que aparecerão na cédula', r.lista_participantes.length,
      tabela([{ rot: 'Nome', f: (l) => nomeBonito(l.nome) }, { rot: 'Unidade', k: 'unidade' }], r.lista_participantes)));
}

// ------------------------------------------------------------------ abas
const ROTULO_STATUS = { rascunho: 'Rascunho', aberta: 'Aberta', encerrada: 'Encerrada' };

function abaPainel() {
  const c = painel.config;
  const badge = h('span', { class: 'badge ' + (painel.aberta_agora ? 'badge-ok' : c.status === 'aberta' ? 'badge-aviso' : '') },
    h('span', { class: 'dot' }), ROTULO_STATUS[c.status], c.status === 'aberta' && !painel.aberta_agora ? ' (fora do período)' : '');

  const acoes = [];
  const acao = (rotulo, novo, palavra, perigo) => h('button', { class: 'btn' + (perigo ? ' btn-danger' : ''), type: 'button', onclick: async (e) => {
    const b = e.currentTarget;
    const ok1 = await confirmar({ titulo: `${rotulo}?`, texto: novo === 'aberta'
      ? `A votação ficará disponível para todos os elegíveis entre ${fmtDataHora(c.inicio)} e ${fmtDataHora(c.fim)}.`
      : 'Ninguém mais conseguirá votar até que a votação seja reaberta.', ok: 'Continuar', perigo });
    if (!ok1) return;
    const ok2 = await confirmar({ titulo: `Confirmação final · ${nomeEmpresa()}`, texto: `Esta ação afeta toda a ${nomeEmpresa()}.`, ok: rotulo, digitar: palavra, perigo });
    if (!ok2) return;
    carregando(b, true);
    try { await rpcE('alterar_status', { p_status: novo }); toast('Status atualizado.'); await recarregar(); }
    catch (err) { toast(err.message, 6000); carregando(b, false, rotulo); }
  } }, rotulo);
  if (c.status === 'rascunho') acoes.push(acao('Abrir votação', 'aberta', 'ABRIR', false));
  if (c.status === 'aberta') acoes.push(acao('Encerrar votação', 'encerrada', 'ENCERRAR', true));
  if (c.status === 'encerrada') acoes.push(acao('Reabrir votação', 'aberta', 'REABRIR', false));

  return h('div', { class: 'stack' },
    h('section', { class: 'glass panel stack' },
      h('div', { class: 'row' }, h('h2', {}, `${nomeEmpresa()} · ${c.nome_eleicao}`), badge, h('span', { class: 'spacer' }), ...acoes),
      h('p', { class: 'muted' }, `Período: ${fmtDataHora(c.inicio)} até ${fmtDataHora(c.fim)} · Auto-voto: ${c.permitir_auto_voto ? 'permitido' : 'proibido'}`),
      h('div', { class: 'kpis' }, kpi('Na base', painel.pessoas), kpi('Ativos', painel.ativos), kpi('Elegíveis', painel.elegiveis),
        kpi('High Potential', painel.hipo), kpi('Cédulas recebidas', painel.cedulas)),
      h('h3', {}, 'Elegíveis por unidade'),
      tabela([{ rot: 'Unidade', k: 'unidade' }, { rot: 'Elegíveis', k: 'elegiveis', num: true }, { rot: 'Admitidos 12 meses', k: 'admitidos_12m', num: true },
        { rot: 'High Potential', k: 'hipo', num: true }], painel.por_unidade, 'Importe a base de ativos.')),
    h('section', { class: 'glass panel stack' },
      h('h2', {}, 'Zona de cuidado'),
      h('p', { class: 'muted small' }, 'Use só nas situações descritas no manual de operação.'),
      h('div', { class: 'row' },
        h('button', { class: 'btn btn-ghost', type: 'button', onclick: async () => {
          if (!await confirmar({ titulo: 'Zerar votos (piloto)?', texto: 'Apaga TODOS os votos e libera todos para votar de novo. A votação volta para rascunho. Use só depois do piloto.', digitar: 'ZERAR VOTOS', ok: 'Zerar', perigo: true })) return;
          try { const r = await rpcE('zerar_votacao', { p_confirmacao: 'ZERAR VOTOS' }); toast(`${r.votos_apagados} votos apagados.`); await recarregar(); } catch (e) { toast(e.message, 6000); }
        } }, 'Zerar votos do piloto'),
        h('button', { class: 'btn btn-ghost', type: 'button', onclick: async () => {
          if (!await confirmar({ titulo: 'Anonimizar a base (LGPD)?', texto: 'Troca os hashes de CPF e nascimento por valores aleatórios. Ninguém mais conseguirá entrar. Faça antes a ata e o backup. Não pode ser desfeito.', digitar: 'ANONIMIZAR', ok: 'Anonimizar', perigo: true })) return;
          try { const r = await rpcE('anonimizar_base', { p_confirmacao: 'ANONIMIZAR' }); toast(`${r.pessoas_anonimizadas} registros anonimizados.`); await recarregar(); } catch (e) { toast(e.message, 6000); }
        } }, 'Anonimizar base (encerramento)'))));
}

function abaConfig() {
  const c = painel.config;
  const local = (iso) => {
    if (!iso) return '';
    const p = new Intl.DateTimeFormat('sv-SE', { timeZone: 'America/Sao_Paulo', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' }).format(new Date(iso));
    return p.replace(' ', 'T');
  };
  const nome = h('input', { class: 'input', id: 'cfg-nome', value: c.nome_eleicao });
  const ini = h('input', { class: 'input', id: 'cfg-ini', type: 'datetime-local', value: local(c.inicio) });
  const fim = h('input', { class: 'input', id: 'cfg-fim', type: 'datetime-local', value: local(c.fim) });
  const auto = h('input', { type: 'checkbox', id: 'cfg-auto', checked: c.permitir_auto_voto, disabled: c.status === 'aberta' });
  const btn = h('button', { class: 'btn', type: 'submit' }, 'Salvar');
  return h('section', { class: 'glass panel' }, h('form', { class: 'stack', onsubmit: async (e) => {
    e.preventDefault();
    if (!ini.value || !fim.value) { toast('Preencha início e fim.'); return; }
    const p = { nome_eleicao: nome.value, inicio: ini.value + ':00-03:00', fim: fim.value + (fim.value.length === 16 ? ':59-03:00' : '-03:00'), permitir_auto_voto: auto.checked };
    if (new Date(p.fim) <= new Date(p.inicio)) { toast('O fim precisa ser depois do início.'); return; }
    carregando(btn, true);
    try { await rpcE('configurar', { p }); toast('Configuração salva.'); await recarregar(); }
    catch (err) { toast(err.message, 6000); carregando(btn, false, 'Salvar'); }
  } },
    h('h2', {}, 'Configuração'),
    h('div', { class: 'field' }, h('label', { for: 'cfg-nome' }, 'Nome da eleição'), nome),
    h('div', { class: 'grid-2' },
      h('div', { class: 'field' }, h('label', { for: 'cfg-ini' }, 'Início (horário de Brasília)'), ini),
      h('div', { class: 'field' }, h('label', { for: 'cfg-fim' }, 'Fim (horário de Brasília)'), fim)),
    h('label', { class: 'row', for: 'cfg-auto' }, auto, 'Permitir votar em si mesmo (padrão: não)'),
    c.status === 'aberta' ? h('p', { class: 'muted small' }, 'A regra de auto-voto não pode mudar com a votação aberta.') : null,
    h('p', { class: 'muted small' }, `Data de corte: ${c.data_corte.split('-').reverse().join('/')} · Vim para ficar: admitidos desde ${c.vim_para_ficar_desde.split('-').reverse().join('/')} · Máximo por categoria: ${c.max_por_categoria}`),
    h('div', { class: 'row row-end' }, btn)));
}

function abaHistorico() {
  const ROT = { ativos: 'Base de ativos', hipo: 'Lista HiPo', status: 'Status', config: 'Configuração', zeragem: 'Zeragem (piloto)', anonimizacao: 'Anonimização' };
  return h('section', { class: 'glass panel stack' }, h('h2', {}, 'Histórico'),
    tabela([
      { rot: 'Quando', f: (l) => fmtDataHora(l.feito_em) },
      { rot: 'Tipo', f: (l) => ROT[l.tipo] || l.tipo },
      { rot: 'Por', f: (l) => l.por || '—' },
      { rot: 'Resumo', f: (l) => l.tipo === 'ativos' ? `${l.novos} novos · ${l.atualizados} atualizados · ${l.desligados} desligados · ${l.ignorados} ignorados`
        : l.tipo === 'hipo' ? `${l.novos} participantes · ${l.ignorados} não encontrados`
        : l.tipo === 'status' ? `${l.detalhes?.de} → ${l.detalhes?.para}`
        : l.tipo === 'zeragem' ? `${l.detalhes?.votos_apagados} votos apagados` : '—' },
    ], painel.importacoes, 'Nenhuma ação registrada ainda.'));
}

function render() {
  const abas = [
    ['painel', 'Painel', abaPainel],
    ['ativos', 'Base de ativos', () => fluxoImportacao({
      titulo: `Importar base de ativos · ${nomeEmpresa()}`, campos: CAMPOS_ATIVOS, rpcNome: 'importar_ativos', renderPrevia: previaAtivos,
      descricao: 'Envie a planilha completa de colaboradores ativos. Quem já está no banco e não vier na planilha será marcado como desligado (nada é apagado). Pode ser reimportada durante a votação.' })],
    ['hipo', 'High Potential', () => fluxoImportacao({
      titulo: `Importar lista High Potential 2026 · ${nomeEmpresa()}`, campos: CAMPOS_HIPO, rpcNome: 'importar_hipo', renderPrevia: previaHipo,
      descricao: 'Planilha com os participantes do programa (por CPF ou matrícula). A lista substitui a anterior.' })],
    ['config', 'Configuração', abaConfig],
    ['historico', 'Histórico', abaHistorico],
  ];
  const conteudo = h('div', { class: 'fade-in' });
  const nav = h('div', { class: 'tabs glass', role: 'tablist', 'aria-label': 'Seções' },
    ...abas.map(([id, rot]) => h('button', { role: 'tab', type: 'button', 'aria-selected': id === abaAtual ? 'true' : 'false', onclick: () => { abaAtual = id; render(); } }, rot)));
  conteudo.append(abas.find(([id]) => id === abaAtual)[2]());
  limpar(app).append(seletorEmpresa(), nav, conteudo);
}

async function recarregar() {
  painel = await rpcE('painel_admin');
  render();
}

exigirLogin(cliente, app, {
  titulo: 'Administração',
  aoEntrar: async (sessao) => {
    $('#topo-acoes').append(h('span', { class: 'muted small' }, sessao.user.email), botaoSair(cliente));
    try { await recarregar(); } catch (e) { limpar(app).append(h('div', { class: 'alert alert-erro' }, e.message)); }
  },
}).catch((e) => { limpar(app).append(h('section', { class: 'glass panel' }, h('div', { class: 'alert alert-erro' }, e.message))); });

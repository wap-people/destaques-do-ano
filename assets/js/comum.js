// Utilitários compartilhados pelas três páginas.
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config.js?v=20261124d';

export function criarCliente({ comLogin = false } = {}) {
  if (!window.supabase) throw new Error('Biblioteca do Supabase não carregou.');
  return window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: comLogin
      ? { persistSession: true, storage: window.sessionStorage, detectSessionInUrl: true, autoRefreshToken: true }
      : { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
}

// Chama uma RPC e devolve os dados, ou lança Error com mensagem amigável.
export async function rpc(cliente, nome, args = {}) {
  let resp;
  try {
    resp = await cliente.rpc(nome, args);
  } catch (e) {
    throw new Error('Falha de conexão. Verifique a internet e tente de novo.');
  }
  if (resp.error) {
    const m = resp.error.message || '';
    if (/acesso negado|permission denied/i.test(m)) throw new Error('Acesso negado.');
    if (/Failed to fetch|NetworkError|fetch/i.test(m)) throw new Error('Falha de conexão. Verifique a internet e tente de novo.');
    throw new Error(m || 'Erro inesperado.');
  }
  return resp.data;
}

// ------------------------------------------------------------------ DOM
// h('div', {class:'x', onclick: fn}, filho1, 'texto', ...)  - nunca usa innerHTML.
export function h(tag, attrs, ...filhos) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2), v);
    else if (k === 'class') el.className = v;
    else if (k === 'dataset') Object.assign(el.dataset, v);
    else if (k === 'style' && typeof v === 'object') Object.assign(el.style, v);
    else if (v === true) el.setAttribute(k, '');
    else el.setAttribute(k, String(v));
  }
  for (const f of filhos.flat(Infinity)) {
    if (f === null || f === undefined || f === false) continue;
    el.append(f instanceof Node ? f : document.createTextNode(String(f)));
  }
  return el;
}
export const $ = (sel, raiz = document) => raiz.querySelector(sel);
export const $$ = (sel, raiz = document) => [...raiz.querySelectorAll(sel)];
export function limpar(el) { while (el.firstChild) el.removeChild(el.firstChild); return el; }

const SVG_NS = 'http://www.w3.org/2000/svg';
export function icone(nome) {
  const paths = {
    check: ['M20 6 9 17l-5-5'],
    busca: ['M21 21l-4.3-4.3', 'M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14z'],
    seta: ['M5 12h14', 'm12 5 7 7-7 7'],
    voltar: ['M19 12H5', 'm12 19-7-7 7-7'],
    sair: ['M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4', 'm16 17 5-5-5-5', 'M21 12H9'],
    upload: ['M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4', 'm17 8-5-5-5 5', 'M12 3v12'],
    alerta: ['M12 9v4', 'M12 17h.01', 'M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z'],
    trofeu: ['M6 9H4.5a2.5 2.5 0 0 1 0-5H6', 'M18 9h1.5a2.5 2.5 0 0 0 0-5H18', 'M4 22h16', 'M10 14.7V17c0 .6-.5 1-1 1.2C7.9 18.8 7 20.2 7 22', 'M14 14.7V17c0 .6.5 1 1 1.2 1.2.6 2 2 2 3.8', 'M18 2H6v7a6 6 0 0 0 12 0V2z'],
  };
  const svg = document.createElementNS(SVG_NS, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24'); svg.setAttribute('fill', 'none'); svg.setAttribute('stroke', 'currentColor');
  svg.setAttribute('stroke-width', '2'); svg.setAttribute('stroke-linecap', 'round'); svg.setAttribute('stroke-linejoin', 'round');
  svg.setAttribute('aria-hidden', 'true'); svg.setAttribute('width', '20'); svg.setAttribute('height', '20');
  for (const d of paths[nome] || []) { const p = document.createElementNS(SVG_NS, 'path'); p.setAttribute('d', d); svg.append(p); }
  return svg;
}

let toastTimer;
export function toast(msg, ms = 3200) {
  let t = $('#toast');
  if (!t) { t = h('div', { id: 'toast', class: 'toast', role: 'status', 'aria-live': 'polite' }); document.body.append(t); }
  t.textContent = msg; t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, ms);
}

// Diálogo de confirmação. Se `digitar` vier, exige digitar a palavra.
export function confirmar({ titulo, texto, ok = 'Confirmar', cancelar = 'Cancelar', perigo = false, digitar = null }) {
  return new Promise((resolve) => {
    const campo = digitar ? h('input', { class: 'input', autocomplete: 'off', 'aria-label': `Digite ${digitar} para confirmar` }) : null;
    const btnOk = h('button', { class: 'btn' + (perigo ? ' btn-danger' : ''), type: 'submit', value: 'sim', disabled: !!digitar }, ok);
    const dlg = h('dialog', { class: 'modal', 'aria-labelledby': 'dlg-t' },
      h('form', { method: 'dialog', class: 'stack' },
        h('h2', { id: 'dlg-t' }, titulo),
        texto ? h('p', { class: 'muted' }, texto) : null,
        digitar ? h('div', { class: 'field' }, h('label', {}, 'Digite ', h('strong', {}, digitar), ' para confirmar'), campo) : null,
        h('div', { class: 'row row-end' },
          h('button', { class: 'btn btn-ghost', type: 'button', onclick: () => dlg.close('nao') }, cancelar),
          btnOk)));
    if (campo) campo.addEventListener('input', () => { btnOk.disabled = campo.value.trim().toUpperCase() !== digitar; });
    dlg.addEventListener('close', () => { const v = dlg.returnValue; dlg.remove(); resolve(v === 'sim'); });
    document.body.append(dlg);
    dlg.showModal();
    (campo || btnOk).focus();
  });
}

export function carregando(btn, sim, textoOriginal) {
  if (sim) {
    btn.dataset.txt = btn.dataset.txt || btn.textContent;
    btn.disabled = true;
    limpar(btn).append(h('span', { class: 'spin', 'aria-hidden': 'true' }), ' Aguarde…');
    btn.setAttribute('aria-busy', 'true');
  } else {
    btn.disabled = false;
    btn.textContent = textoOriginal || btn.dataset.txt || 'OK';
    btn.removeAttribute('aria-busy');
  }
}

// ------------------------------------------------------------------ CPF e datas
export const soDigitos = (s) => String(s ?? '').replace(/\D/g, '');

export function cpfValido(c) {
  const d = soDigitos(c);
  if (d.length !== 11 || /^(\d)\1{10}$/.test(d)) return false;
  const dv = (base, peso) => {
    let s = 0;
    for (let i = 0; i < base.length; i++) s += Number(base[i]) * (peso - i);
    const r = (s * 10) % 11;
    return r === 10 ? 0 : r;
  };
  return dv(d.slice(0, 9), 10) === Number(d[9]) && dv(d.slice(0, 10), 11) === Number(d[10]);
}

export function mascaraCpf(v) {
  const d = soDigitos(v).slice(0, 11);
  return d.replace(/^(\d{3})(\d)/, '$1.$2').replace(/^(\d{3})\.(\d{3})(\d)/, '$1.$2.$3').replace(/\.(\d{3})(\d{1,2})$/, '.$1-$2');
}

export function mascaraData(v) {
  const d = soDigitos(v).slice(0, 8);
  if (d.length > 4) return `${d.slice(0, 2)}/${d.slice(2, 4)}/${d.slice(4)}`;
  if (d.length > 2) return `${d.slice(0, 2)}/${d.slice(2)}`;
  return d;
}

// 'dd/mm/aaaa' -> 'aaaa-mm-dd' (ou null se inválida)
export function dataBrParaIso(s) {
  const m = /^(\d{2})\/(\d{2})\/(\d{4})$/.exec(String(s || '').trim());
  if (!m) return null;
  const [, dd, mm, yyyy] = m;
  const dt = new Date(Date.UTC(+yyyy, +mm - 1, +dd));
  if (dt.getUTCFullYear() !== +yyyy || dt.getUTCMonth() !== +mm - 1 || dt.getUTCDate() !== +dd) return null;
  if (+yyyy < 1900 || dt > new Date()) return null;
  return `${yyyy}-${mm}-${dd}`;
}

const TZ = 'America/Sao_Paulo';
export function fmtDataHora(iso) {
  if (!iso) return '—';
  return new Intl.DateTimeFormat('pt-BR', { timeZone: TZ, dateStyle: 'short', timeStyle: 'short' }).format(new Date(iso));
}
export function fmtData(iso) {
  if (!iso) return '—';
  const s = String(iso);
  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) { const [y, m, d] = s.split('-'); return `${d}/${m}/${y}`; }
  return new Intl.DateTimeFormat('pt-BR', { timeZone: TZ, dateStyle: 'short' }).format(new Date(s));
}
export const fmtNum = (n) => new Intl.NumberFormat('pt-BR').format(n ?? 0);

export function nomeBonito(nome) {
  const minusculas = new Set(['da', 'de', 'do', 'das', 'dos', 'e']);
  return String(nome || '').toLowerCase().split(/\s+/).filter(Boolean)
    .map((p, i) => (i > 0 && minusculas.has(p)) ? p : p.charAt(0).toUpperCase() + p.slice(1)).join(' ');
}
export function iniciais(nome) {
  const p = String(nome || '').trim().split(/\s+/);
  return ((p[0]?.[0] || '') + (p.length > 1 ? p[p.length - 1][0] : '')).toUpperCase();
}
export const chave = (s) => String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/\s+/g, ' ').trim();

export function baixarArquivo(nome, conteudo, tipo = 'text/csv;charset=utf-8') {
  const blob = new Blob([conteudo], { type: tipo });
  const url = URL.createObjectURL(blob);
  const a = h('a', { href: url, download: nome });
  document.body.append(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 2000);
}
export function csv(linhas) {
  const q = (v) => { const s = String(v ?? ''); return /[";\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s; };
  return '﻿' + linhas.map((l) => l.map(q).join(';')).join('\r\n');
}

// Cores das categorias vêm do tema da empresa (tokens.css / tema-freso.css).
export const CORES_CATEGORIA = ['var(--cat-1)', 'var(--cat-2)', 'var(--cat-3)', 'var(--cat-4)', 'var(--cat-5)'];

export const EMPRESAS = [{ codigo: 'WAP', nome: 'WAP' }, { codigo: 'FRESO', nome: 'Freso' }];

// ------------------------------------------------------------------ movimento Liquid Glass
// Liquid Morph: um único indicador desliza até a aba ativa (só transform + width de um elemento).
// As telas são recriadas a cada clique, então a última posição fica guardada por lista
// (aria-label): o indicador nasce onde estava e escorrega até a aba nova.
const posicaoAbas = new Map();
export function abasLiquidas(lista, seletor = '[aria-selected="true"], [aria-current="step"]') {
  const ind = h('span', { class: 'tab-ind', 'aria-hidden': 'true' });
  const chaveLista = lista.getAttribute('aria-label') || '';
  lista.classList.add('abas-liquidas');
  lista.prepend(ind);
  const medir = () => { const b = lista.querySelector(seletor); return b ? { x: b.offsetLeft, w: b.offsetWidth } : null; };
  const pousar = (p) => { ind.style.transform = `translateX(${p.x}px)`; ind.style.width = `${p.w}px`; };
  // Microtask: roda logo depois de a tela ser montada (mesmo tick), antes do próximo quadro.
  // Se a lista ainda não estiver na página, tenta de novo no quadro seguinte.
  let tentativas = 0;
  const iniciar = () => {
    if (!lista.isConnected) { if (++tentativas < 30) requestAnimationFrame(iniciar); return; }
    const novo = medir();
    if (!novo) return;
    const antigo = posicaoAbas.get(chaveLista);
    ind.classList.add('parado');
    pousar(antigo || novo);
    void ind.offsetWidth;            // fixa a posição de partida antes de ligar a transição
    ind.classList.remove('parado');
    ind.classList.add('pronto');
    pousar(novo);
    posicaoAbas.set(chaveLista, novo);
    // Rótulos que mudam de largura (ex.: status carregado) reposicionam o indicador.
    if ('ResizeObserver' in window) {
      new ResizeObserver(() => { const p = lista.isConnected && medir(); if (p) { pousar(p); posicaoAbas.set(chaveLista, p); } }).observe(lista);
    }
  };
  queueMicrotask(iniciar);
  return lista;
}

// Respeita "reduzir movimento" também nas animações feitas por JS (o CSS já desliga as dele).
export const reduzMovimento = () => !!window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;

// Animação curta via Web Animations API; não faz nada com movimento reduzido ou sem suporte.
export function animar(el, quadros, opcoes) {
  if (!el || reduzMovimento() || !el.animate) return null;
  return el.animate(quadros, opcoes);
}

// Pulso de mola (contador que muda, badge do stepper).
export const pulsar = (el) => animar(el,
  [{ transform: 'scale(1)' }, { transform: 'scale(1.28)' }, { transform: 'scale(1)' }],
  { duration: 380, easing: 'cubic-bezier(.34, 1.56, .64, 1)' });

// Confete com as cores da marca, ~1,6 s. Um <canvas> fixo, sem clique, removido no fim.
export function confete({ quantidade = 110, duracao = 1600 } = {}) {
  if (reduzMovimento()) return;
  const raiz = getComputedStyle(document.documentElement);
  const cores = ['--cat-1', '--cat-2', '--cat-3', '--cat-4', '--accent']
    .map((v) => raiz.getPropertyValue(v).trim()).filter(Boolean);
  if (!cores.length) cores.push('#0094a1');
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  const L = window.innerWidth, A = window.innerHeight;
  const cv = h('canvas', { class: 'confete', 'aria-hidden': 'true' });
  cv.width = L * dpr; cv.height = A * dpr;
  document.body.append(cv);
  const ctx = cv.getContext('2d');
  ctx.scale(dpr, dpr);
  // Duas rajadas, dos cantos de baixo para o centro.
  const ps = Array.from({ length: quantidade }, (_, i) => {
    const esq = i % 2 === 0;
    const ang = (esq ? -60 : -120) * Math.PI / 180 + (Math.random() - .5) * .9;
    const vel = 9 + Math.random() * 8;
    return {
      x: esq ? L * .08 : L * .92, y: A * .95, vx: Math.cos(ang) * vel, vy: Math.sin(ang) * vel * 1.35,
      r: Math.random() * Math.PI, vr: (Math.random() - .5) * .3, w: 6 + Math.random() * 6, hh: 8 + Math.random() * 8,
      cor: cores[i % cores.length],
    };
  });
  const t0 = performance.now();
  const quadro = (t) => {
    const p = (t - t0) / duracao;
    ctx.clearRect(0, 0, L, A);
    ctx.globalAlpha = p < .7 ? 1 : Math.max(0, 1 - (p - .7) / .3);
    for (const c of ps) {
      c.vy += .32; c.vx *= .985; c.vy *= .985; c.x += c.vx; c.y += c.vy; c.r += c.vr;
      ctx.save(); ctx.translate(c.x, c.y); ctx.rotate(c.r);
      ctx.fillStyle = c.cor; ctx.fillRect(-c.w / 2, -c.hh / 2, c.w, c.hh * Math.abs(Math.cos(c.r * 2)) + 2);
      ctx.restore();
    }
    if (p < 1) requestAnimationFrame(quadro); else cv.remove();
  };
  requestAnimationFrame(quadro);
}

// Bubble Reveal (saída): o elemento some por opacidade e só depois sai do DOM.
// A entrada (inflar + desfoque) é só CSS, com @starting-style.
export function sairBolha(el) {
  if (!el || !el.isConnected) return;
  el.classList.add('bolha-saindo');
  const fim = () => el.remove();
  el.addEventListener('transitionend', fim, { once: true });
  setTimeout(fim, 400);
}

// Scroll Float: ao rolar, <html data-rolou> aprofunda sombra e desfoque das barras flutuantes.
// IntersectionObserver em vez de ouvir 'scroll': só dispara ao cruzar o limite, nada por quadro.
(function profundidadeAoRolar(limite = 24) {
  if (!('IntersectionObserver' in window) || !document.body) return;
  const s = h('div', { class: 'sentinela-rolagem', 'aria-hidden': 'true' });
  s.style.height = `${limite}px`;
  document.body.prepend(s);
  new IntersectionObserver(([e]) => { document.documentElement.toggleAttribute('data-rolou', !e.isIntersecting); }).observe(s);
})();

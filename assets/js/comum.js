// Utilitários compartilhados pelas três páginas.
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config.js?v=20261124a';

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

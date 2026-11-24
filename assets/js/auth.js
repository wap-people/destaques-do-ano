// Login da comissão / admins (Supabase Auth, e-mail + senha).
import { rpc, h, limpar, carregando } from './comum.js?v=20261124b';

// Lê o tipo do link (convite ou recuperação) ANTES de o supabase-js limpar a URL.
const tipoLink = (() => {
  const p = new URLSearchParams(location.hash.slice(1));
  return p.get('type');
})();

export async function exigirLogin(cliente, container, { titulo, aoEntrar }) {
  const { data } = await cliente.auth.getSession();

  if (data.session && (tipoLink === 'invite' || tipoLink === 'recovery')) {
    return telaDefinirSenha(cliente, container, { titulo, aoEntrar });
  }
  if (data.session) {
    const ok = await rpc(cliente, 'sou_admin').catch(() => false);
    if (ok) return aoEntrar(data.session);
    await cliente.auth.signOut();
    return telaLogin(cliente, container, { titulo, aoEntrar, erro: 'Este usuário não tem acesso de administrador.' });
  }
  return telaLogin(cliente, container, { titulo, aoEntrar });
}

function telaLogin(cliente, container, { titulo, aoEntrar, erro }) {
  const email = h('input', { class: 'input', type: 'email', id: 'email', autocomplete: 'username', required: true });
  const senha = h('input', { class: 'input', type: 'password', id: 'senha', autocomplete: 'current-password', required: true });
  const msg = h('div', { role: 'alert' }, erro ? h('div', { class: 'alert alert-erro' }, erro) : null);
  const btn = h('button', { class: 'btn btn-block', type: 'submit' }, 'Entrar');

  const form = h('form', { class: 'stack', onsubmit: async (e) => {
    e.preventDefault();
    limpar(msg);
    carregando(btn, true);
    try {
      const { error } = await cliente.auth.signInWithPassword({ email: email.value.trim(), password: senha.value });
      if (error) throw new Error('E-mail ou senha incorretos.');
      const ok = await rpc(cliente, 'sou_admin');
      if (!ok) { await cliente.auth.signOut(); throw new Error('Este usuário não tem acesso de administrador.'); }
      senha.value = '';
      const { data } = await cliente.auth.getSession();
      aoEntrar(data.session);
    } catch (err) {
      msg.append(h('div', { class: 'alert alert-erro' }, err.message));
    } finally {
      if (btn.isConnected) carregando(btn, false, 'Entrar');
    }
  } },
    h('div', { class: 'field' }, h('label', { for: 'email' }, 'E-mail'), email),
    h('div', { class: 'field' }, h('label', { for: 'senha' }, 'Senha'), senha),
    msg, btn,
    h('button', { class: 'btn btn-ghost btn-block', type: 'button', onclick: async () => {
      limpar(msg);
      if (!email.value.trim()) { msg.append(h('div', { class: 'alert alert-aviso' }, 'Digite seu e-mail acima e clique de novo.')); return; }
      await cliente.auth.resetPasswordForEmail(email.value.trim(), { redirectTo: location.origin + location.pathname });
      msg.append(h('div', { class: 'alert alert-ok' }, 'Se o e-mail estiver cadastrado, você receberá um link para definir a senha.'));
    } }, 'Esqueci a senha'));

  limpar(container).append(h('section', { class: 'glass panel fade-in stack wrap' },
    h('div', { class: 'titulo-barras' }, h('img', { class: 'barras', src: 'assets/img/simbolo-barras.svg', alt: '', width: 40, height: 22 }), h('h1', {}, titulo)),
    h('p', { class: 'muted' }, 'Acesso restrito à comissão.'),
    form));
  email.focus();
}

function telaDefinirSenha(cliente, container, { titulo, aoEntrar }) {
  const s1 = h('input', { class: 'input', type: 'password', id: 's1', autocomplete: 'new-password', minlength: 10, required: true });
  const s2 = h('input', { class: 'input', type: 'password', id: 's2', autocomplete: 'new-password', minlength: 10, required: true });
  const msg = h('div', { role: 'alert' });
  const btn = h('button', { class: 'btn btn-block', type: 'submit' }, 'Salvar senha');
  const form = h('form', { class: 'stack', onsubmit: async (e) => {
    e.preventDefault();
    limpar(msg);
    if (s1.value.length < 10) { msg.append(h('div', { class: 'alert alert-erro' }, 'Use pelo menos 10 caracteres.')); return; }
    if (s1.value !== s2.value) { msg.append(h('div', { class: 'alert alert-erro' }, 'As senhas não conferem.')); return; }
    carregando(btn, true);
    const { error } = await cliente.auth.updateUser({ password: s1.value });
    carregando(btn, false, 'Salvar senha');
    if (error) { msg.append(h('div', { class: 'alert alert-erro' }, 'Não foi possível salvar: ' + error.message)); return; }
    s1.value = s2.value = '';
    history.replaceState(null, '', location.pathname);
    exigirLogin(cliente, container, { titulo, aoEntrar });
  } },
    h('div', { class: 'field' }, h('label', { for: 's1' }, 'Nova senha (mín. 10 caracteres)'), s1),
    h('div', { class: 'field' }, h('label', { for: 's2' }, 'Repita a senha'), s2),
    msg, btn);
  limpar(container).append(h('section', { class: 'glass panel fade-in stack wrap' }, h('h1', {}, 'Defina sua senha'), form));
  s1.focus();
}

export function botaoSair(cliente) {
  return h('button', { class: 'btn btn-ghost btn-sm', type: 'button', onclick: async () => { await cliente.auth.signOut(); location.reload(); } }, 'Sair');
}

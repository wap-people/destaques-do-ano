// Simulador da votação para as páginas /teste/ (WAP e Freso).
// Substitui o cliente do Supabase por RPCs falsas, com nomes fictícios. Nada sai do navegador:
// as páginas de teste nem carregam a biblioteca do Supabase e a CSP bloqueia conexões (connect-src 'none').
// As regras de tela (CPF válido, data, máximo por categoria, sessão de 20 min) são as mesmas do voto.js real.
(() => {
  const NOMES = [
    'ANA PAULA FICTICIA', 'BRUNO EXEMPLO', 'CARLA DE TESTE', 'DIEGO SIMULADO', 'EDUARDA MODELO', 'FABIO DEMONSTRACAO',
    'GABRIELA AMOSTRA', 'HENRIQUE PROVA', 'ISABELA ENSAIO', 'JOAO DA SILVA TESTE', 'KARINA PILOTO', 'LUCAS PROTOTIPO',
    'MARIANA ESBOCO', 'NICOLAS RASCUNHO', 'OLIVIA EXERCICIO', 'PEDRO HIPOTESE', 'RAQUEL CENARIO', 'SAMUEL TREINO',
    'TATIANA SIMULACAO', 'VINICIUS EXEMPLAR', 'WESLEY FICTICIO', 'YASMIN DE OLIVEIRA TESTE', 'ZULEICA MODELAGEM', 'ARTUR VALIDACAO',
    'BEATRIZ CONFERENCIA', 'CAIO HOMOLOGACAO', 'DANIELA ROTEIRO', 'ENZO PREVIA', 'FERNANDA ESTUDO', 'GUSTAVO ENSAIO GERAL',
  ];
  const SETORES = ['Produção', 'Qualidade', 'Engenharia', 'Comercial', 'People', 'Logística', 'Financeiro', 'Manutenção'];
  const pessoas = NOMES.map((n, i) => [`00000000-0000-4000-8000-${String(i + 1).padStart(12, '0')}`, n, SETORES[i % SETORES.length]]);
  const todos = pessoas.map((_, i) => i);
  const CATEGORIAS = [
    ['VIM_PARA_FICAR', 'Vim para ficar', 'unidade', todos.filter((i) => i % 4 === 0),
      'Aquele Legendário que chegou e rapidamente conquistou seu espaço. Demonstrou valor, comprometimento e já se tornou peça essencial para o time.'],
    ['LIDERANCA', 'Liderança Inspiradora', 'unidade', todos,
      'Não precisa ocupar uma posição de gestor para ser um líder nato. Esse legendário inspira quem está à sua volta, direciona os ambientes com confiança e influencia positivamente todos ao seu redor.'],
    ['PATROCINADOR', 'Patrocinador da Mudança', 'unidade', todos,
      'Esse legendário não apenas apoia mudanças e melhorias, ele as impulsiona. Sugere, provoca e faz acontecer. Está sempre à frente, puxando transformações e desafiando, com uma visão de evolução que realmente faz a diferença.'],
    ['OURO', 'Colaborador de Ouro', 'geral', todos,
      'Esse legendário é a personificação dos nossos valores. Se pensamos em liderança de arrimo, mão na massa, sonhar grande, obsessão por resultados e foco no cliente, ele é o exemplo perfeito. Sua determinação e resiliência são evidentes e fazem toda a diferença.'],
    ['HIPO', 'High Potential', 'geral', [2, 6, 11, 17, 23, 28],
      'Esse legendário foi destaque e entrou para a lista dos High Potential 2026. Mesmo em meio a um grupo de talentos, conseguiu se sobressair ainda mais, demonstrando um potencial e comprometimento acima da média.'],
  ];
  const MAX = 3;
  const agora = Date.now();
  const tokens = new Set();
  const esperar = () => new Promise((r) => setTimeout(r, 250 + Math.random() * 250));
  const hex = (n) => Array.from(crypto.getRandomValues(new Uint8Array(n)), (b) => b.toString(16).padStart(2, '0')).join('').toUpperCase();

  async function rpc(nome, args = {}) {
    await esperar();
    if (nome === 'info_publica') {
      return { data: {
        empresa: args.p_empresa, nome_eleicao: 'Destaques do Ano 2026 (teste)', status: 'aberta', aberta_agora: true,
        inicio: new Date(agora - 864e5).toISOString(), fim: new Date(agora + 864e5 * 14).toISOString(),
        data_corte: '2026-11-30', max_por_categoria: MAX,
        categorias: CATEGORIAS.map(([codigo, nome, escopo, , descricao]) => ({ codigo, nome, escopo, descricao })),
      } };
    }
    if (nome === 'iniciar_votacao') {
      // Simula a recusa do servidor para quem quiser ver a mensagem de erro.
      if (args.p_nascimento === '2000-01-01') {
        return { data: { ok: false, codigo: 'recusado', mensagem: 'Não foi possível validar seus dados ou seu voto já foi registrado. Procure o RH.' } };
      }
      const token = 'teste-' + hex(8);
      tokens.add(token);
      return { data: {
        ok: true, token, expira_em: new Date(Date.now() + 20 * 60e3).toISOString(),
        primeiro_nome: 'Visitante', unidade: 'Unidade Teste', max_por_categoria: MAX, pessoas,
        categorias: CATEGORIAS.map(([codigo, nome, escopo, candidatos, descricao]) => ({ codigo, nome, escopo, descricao, candidatos })),
      } };
    }
    if (nome === 'registrar_cedula') {
      // Valida como o servidor (máximo por categoria, candidatos válidos), mas não guarda nada.
      const ids = new Set(pessoas.map((p) => p[0]));
      for (const [cod, lista] of Object.entries(args.p_escolhas || {})) {
        if (!Array.isArray(lista) || lista.length > MAX || lista.some((id) => !ids.has(id))) {
          return { data: { ok: false, codigo: 'invalida', mensagem: `Cédula inválida na categoria ${cod}.` } };
        }
      }
      tokens.delete(args.p_token);
      return { data: { ok: true, protocolo: `${hex(3).slice(0, 5)}-${hex(3).slice(0, 5)}` } };
    }
    return { data: null, error: { message: 'Função indisponível no modo teste.' } };
  }

  window.supabase = { modoTeste: true, createClient: () => ({ rpc, auth: { getSession: async () => ({ data: { session: null } }) } }) };
})();

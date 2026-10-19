// Adalink: botão "Não receber campanhas de WhatsApp" do painel do contato.
//
// O painel manda 'trama-nao-receber-campanhas' ao CRM (Atendimento.tsx), que
// descadastra o telefone das campanhas de WhatsApp (wa_optout) e responde com
// 'trama-nao-receber-campanhas-done'. Aqui ficam só as regras puras: montar o
// pedido e entender a resposta. Quem decide se o usuário pode é o banco.

export const NAO_RECEBER_MESSAGE_TYPE = 'trama-nao-receber-campanhas';
export const NAO_RECEBER_DONE_MESSAGE_TYPE = 'trama-nao-receber-campanhas-done';

// Texto de último recurso: nunca mostrar um erro vazio ao corretor.
export const TEXTO_ERRO_PADRAO =
  'Não deu para tirar o número das campanhas agora. Tente de novo em instantes.';

// O CRM não respondeu (fork subiu antes do CRM, Chatwoot aberto fora do iframe,
// erro antes de responder): o botão não pode ficar preso em "enviando".
export const NAO_RECEBER_TIMEOUT_MS = 15000;
export const TEXTO_SEM_RESPOSTA =
  'O CRM não respondeu. Tente de novo; se continuar, avise o suporte.';

const telefoneDoContato = contact => {
  const telefone =
    typeof contact?.phone_number === 'string'
      ? contact.phone_number.trim()
      : '';
  return telefone;
};

// Contato sem telefone (conversa só por e-mail) não tem o que descadastrar.
export const podeNaoReceberCampanhas = contact =>
  telefoneDoContato(contact) !== '';

export const novoRequestId = () =>
  `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;

// requestId pareia pedido e resposta: o painel só aceita a resposta do pedido
// que ele mesmo mandou (trocar de contato no meio não "empresta" a resposta).
export const buildNaoReceberCampanhasMessage = ({ contact, requestId }) => ({
  type: NAO_RECEBER_MESSAGE_TYPE,
  telefone: telefoneDoContato(contact),
  requestId,
});

// Lê a resposta do CRM. Devolve null para qualquer outra mensagem; senão
// { requestId, ok, novo, error }. Sucesso só vale com ok === true (nunca por
// "não tem erro").
export const lerRespostaNaoReceberCampanhas = data => {
  if (!data || typeof data !== 'object' || Array.isArray(data)) return null;
  if (data.type !== NAO_RECEBER_DONE_MESSAGE_TYPE) return null;
  const requestId = typeof data.requestId === 'string' ? data.requestId : '';
  if (data.ok === true) {
    return { requestId, ok: true, novo: data.novo !== false, error: '' };
  }
  const error =
    typeof data.error === 'string' && data.error.trim() !== ''
      ? data.error
      : TEXTO_ERRO_PADRAO;
  return { requestId, ok: false, novo: false, error };
};

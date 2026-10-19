// Adalink: botão "Não receber campanhas" do painel do contato.
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

export const buildNaoReceberCampanhasMessage = ({ contact }) => ({
  type: NAO_RECEBER_MESSAGE_TYPE,
  telefone: telefoneDoContato(contact),
});

// Lê a resposta do CRM. Devolve null para qualquer outra mensagem; senão
// { ok, novo, error }. Sucesso só vale com ok === true (nunca por "não tem erro").
export const lerRespostaNaoReceberCampanhas = data => {
  if (!data || typeof data !== 'object' || Array.isArray(data)) return null;
  if (data.type !== NAO_RECEBER_DONE_MESSAGE_TYPE) return null;
  if (data.ok === true)
    return { ok: true, novo: data.novo !== false, error: '' };
  const error =
    typeof data.error === 'string' && data.error.trim() !== ''
      ? data.error
      : TEXTO_ERRO_PADRAO;
  return { ok: false, novo: false, error };
};

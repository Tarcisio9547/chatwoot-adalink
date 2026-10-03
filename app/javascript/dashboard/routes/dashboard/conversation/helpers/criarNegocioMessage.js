// Adalink: monta a mensagem 'trama-criar-negocio' que o painel do contato manda
// ao CRM (Atendimento.tsx) quando o corretor clica em "Criar Negócio".
//
// conversationId e inboxId identificam a conversa ABERTA no momento do clique.
// O CRM usa os dois pra ligar a conversa oficial ao negócio (wa_oficial_vinculos).
// São opcionais de propósito: o CRM tolera mensagem sem eles, e aqui só vão
// valores que são inteiros positivos. Qualquer outra coisa é omitida, nunca
// enviada como lixo.

// A prop conversationId do ContactPanel aceita Number ou String ('321' vira 321).
const toPositiveInt = value => {
  if (typeof value === 'string' && value.trim() === '') return undefined;
  if (typeof value !== 'number' && typeof value !== 'string') return undefined;
  const n = Number(value);
  return Number.isInteger(n) && n > 0 ? n : undefined;
};

export const CRIAR_NEGOCIO_MESSAGE_TYPE = 'trama-criar-negocio';

export const buildCriarNegocioMessage = ({
  contact,
  conversationId,
  inboxId,
}) => {
  const message = {
    type: CRIAR_NEGOCIO_MESSAGE_TYPE,
    contato: {
      nome: contact.name || '',
      telefone: contact.phone_number || '',
      email: contact.email || '',
      chatwoot_contact_id: contact.id,
    },
  };

  const conversa = toPositiveInt(conversationId);
  if (conversa !== undefined) message.conversationId = conversa;

  const caixa = toPositiveInt(inboxId);
  if (caixa !== undefined) message.inboxId = caixa;

  return message;
};

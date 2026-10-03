import { buildCriarNegocioMessage } from '../criarNegocioMessage';

const contact = {
  id: 77,
  name: 'Maria Souza',
  phone_number: '+5511999990000',
  email: 'maria@exemplo.com',
};

describe('#buildCriarNegocioMessage', () => {
  it('monta a mensagem com contato, conversationId e inboxId', () => {
    expect(
      buildCriarNegocioMessage({ contact, conversationId: 321, inboxId: 12 })
    ).toEqual({
      type: 'trama-criar-negocio',
      contato: {
        nome: 'Maria Souza',
        telefone: '+5511999990000',
        email: 'maria@exemplo.com',
        chatwoot_contact_id: 77,
      },
      conversationId: 321,
      inboxId: 12,
    });
  });

  it('converte conversationId numérico em string (a prop aceita Number ou String)', () => {
    const msg = buildCriarNegocioMessage({
      contact,
      conversationId: '321',
      inboxId: 12,
    });
    expect(msg.conversationId).toBe(321);
    expect(msg.inboxId).toBe(12);
  });

  it('omite inboxId quando a conversa não informa a caixa', () => {
    const msg = buildCriarNegocioMessage({ contact, conversationId: 321 });
    expect(msg).not.toHaveProperty('inboxId');
    expect(msg.conversationId).toBe(321);
  });

  it('omite os dois campos novos sem conversa aberta (mensagem igual à antiga)', () => {
    const msg = buildCriarNegocioMessage({ contact });
    expect(msg).toEqual({
      type: 'trama-criar-negocio',
      contato: {
        nome: 'Maria Souza',
        telefone: '+5511999990000',
        email: 'maria@exemplo.com',
        chatwoot_contact_id: 77,
      },
    });
  });

  it.each([
    ['zero', 0],
    ['negativo', -4],
    ['NaN', NaN],
    ['texto', 'abc'],
    ['string vazia', ''],
    ['decimal', 3.5],
    ['null', null],
    ['objeto', {}],
  ])(
    'descarta id inválido (%s) em vez de mandar lixo ao CRM',
    (_, invalido) => {
      const msg = buildCriarNegocioMessage({
        contact,
        conversationId: invalido,
        inboxId: invalido,
      });
      expect(msg).not.toHaveProperty('conversationId');
      expect(msg).not.toHaveProperty('inboxId');
    }
  );

  it('usa strings vazias para contato sem nome, telefone ou e-mail (comportamento anterior)', () => {
    const msg = buildCriarNegocioMessage({
      contact: { id: 5 },
      conversationId: 9,
      inboxId: 2,
    });
    expect(msg.contato).toEqual({
      nome: '',
      telefone: '',
      email: '',
      chatwoot_contact_id: 5,
    });
  });
});

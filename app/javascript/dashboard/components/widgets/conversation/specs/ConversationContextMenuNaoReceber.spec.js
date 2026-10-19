import { mount } from '@vue/test-utils';
import ContextMenu from '../contextMenu/Index.vue';

// Item "Não receber campanhas de WhatsApp" do menu de clique direito da lista:
// só com telefone, dois cliques (o 1º pede confirmação) e o resultado vira aviso.
const alertar = vi.fn();
vi.mock('dashboard/composables/useAdmin', () => ({
  useAdmin: () => ({ isAdmin: false }),
}));
vi.mock('dashboard/composables', () => ({ useAlert: msg => alertar(msg) }));

const RESPOSTA = 'trama-nao-receber-campanhas-done';

const montar = props =>
  mount(ContextMenu, {
    props: { chatId: 9, inboxId: 3, status: 'open', ...props },
    global: {
      mocks: {
        $t: chave => chave,
        $store: {
          dispatch: vi.fn(),
          getters: {
            'labels/getLabels': [],
            'teams/getTeams': [],
            'inboxAssignableAgents/getUIFlags': {},
            'inboxAssignableAgents/getAssignableAgents': () => [],
            getCurrentUser: { id: 1 },
            getCurrentAccountId: 1,
          },
        },
      },
      stubs: { 'fluent-icon': true, Avatar: true, Icon: true },
    },
  });

const item = painel =>
  painel
    .findAll('[role="button"]')
    .find(b => /campanhas|confirmar|Tirando/.test(b.text()));

const responder = async (data, extra = {}) => {
  window.dispatchEvent(
    new MessageEvent('message', {
      data,
      origin: window.location.origin,
      source: window.parent,
      ...extra,
    })
  );
  await Promise.resolve();
  await Promise.resolve();
};

describe('ConversationContextMenu: Não receber campanhas', () => {
  let postMessage;
  const pedido = () => postMessage.mock.calls.at(-1)[0];

  beforeEach(() => {
    alertar.mockReset();
    postMessage = vi
      .spyOn(window.parent, 'postMessage')
      .mockImplementation(() => {});
  });

  afterEach(() => {
    postMessage.mockRestore();
    vi.useRealTimers();
  });

  it('aparece quando a conversa tem telefone', () => {
    const painel = montar({ phoneNumber: '+5547991140001' });
    expect(item(painel).text()).toContain('Não receber campanhas de WhatsApp');
  });

  it('não aparece sem telefone', () => {
    const painel = montar({ phoneNumber: '' });
    expect(item(painel)).toBeUndefined();
  });

  it('não aparece na lista restrita (allowedOptions sem o item)', () => {
    const painel = montar({
      phoneNumber: '+5547991140001',
      allowedOptions: ['open-new-tab', 'copy-link'],
    });
    expect(item(painel)).toBeUndefined();
  });

  it('o 1º clique só pede confirmação: nada vai ao CRM', async () => {
    const painel = montar({ phoneNumber: '+5547991140001' });
    await item(painel).trigger('click');

    expect(postMessage).not.toHaveBeenCalled();
    expect(item(painel).text()).toContain('Clique de novo para confirmar');
  });

  it('o 2º clique manda telefone e requestId; a resposta ok vira aviso e fecha o menu', async () => {
    const painel = montar({ phoneNumber: '+5547991140001' });
    await item(painel).trigger('click');
    await item(painel).trigger('click');

    expect(postMessage).toHaveBeenCalledTimes(1);
    expect(pedido()).toEqual({
      type: 'trama-nao-receber-campanhas',
      telefone: '+5547991140001',
      requestId: expect.any(String),
    });
    expect(item(painel).text()).toContain('Tirando das campanhas');

    await responder({
      type: RESPOSTA,
      requestId: pedido().requestId,
      ok: true,
      novo: true,
    });
    expect(alertar).toHaveBeenCalledWith(
      'Pronto: este número não recebe mais campanhas de WhatsApp.'
    );
    expect(painel.emitted('close')).toBeTruthy();
  });

  it('clique durante o envio não manda um 2º pedido', async () => {
    const painel = montar({ phoneNumber: '+5547991140001' });
    await item(painel).trigger('click');
    await item(painel).trigger('click');
    await item(painel).trigger('click');

    expect(postMessage).toHaveBeenCalledTimes(1);
  });

  it('resposta com erro mostra o texto do CRM no aviso', async () => {
    const painel = montar({ phoneNumber: '+5547991140001' });
    await item(painel).trigger('click');
    await item(painel).trigger('click');
    await responder({
      type: RESPOSTA,
      requestId: pedido().requestId,
      ok: false,
      error: 'Você não tem permissão para tirar este número das campanhas.',
    });

    expect(alertar).toHaveBeenCalledWith(
      'Você não tem permissão para tirar este número das campanhas.'
    );
  });
});

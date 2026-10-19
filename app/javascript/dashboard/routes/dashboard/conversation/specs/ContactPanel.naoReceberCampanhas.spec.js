import { mount } from '@vue/test-utils';
import { ref } from 'vue';
import ContactPanel from '../ContactPanel.vue';

// Botão "Não receber campanhas": pedido ao CRM (window.parent) só depois da
// confirmação, e a resposta do CRM (mesmo origin) decide a mensagem na tela.
// Store, preferências de UI e filhos entram como dublês mínimos.
const contato = {
  id: 77,
  name: 'Maria Souza',
  phone_number: '+5511999990000',
  email: 'maria@exemplo.com',
};

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: vi.fn() }),
  useFunctionGetter: () => ref({}),
  useMapGetter: nome => {
    const valores = {
      getSelectedChat: {
        meta: { channel: 'Channel::Whatsapp', sender: { id: 77 } },
      },
      'contacts/getContact': () => contato,
      'conversationMetadata/getConversationMetadata': () => ({}),
    };
    return ref(valores[nome]);
  },
}));
vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({ isCloudFeatureEnabled: () => false }),
}));
vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    updateUISettings: vi.fn(),
    isContactSidebarItemOpen: () => false,
    conversationSidebarItemsOrder: ref([]),
    toggleSidebarUIState: vi.fn(),
  }),
}));

const montar = props =>
  mount(ContactPanel, {
    props,
    global: {
      mocks: { $t: chave => chave },
      stubs: {
        AccordionItem: true,
        ContactConversations: true,
        ConversationAction: true,
        ConversationParticipant: true,
        ContactInfo: true,
        ContactNotes: true,
        ConversationInfo: true,
        CustomAttributes: true,
        Draggable: true,
        MacrosList: true,
        ShopifyOrdersList: true,
        SidebarActionsHeader: true,
        LinearIssuesList: true,
        LinearSetupCTA: true,
        'woot-feature-toggle': true,
      },
    },
  });

const RESPOSTA = 'trama-nao-receber-campanhas-done';

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
};

const botaoComTexto = (painel, texto) =>
  painel.findAll('button').find(b => b.text().includes(texto));

describe('ContactPanel: botão Não receber campanhas', () => {
  let postMessage;

  beforeEach(() => {
    postMessage = vi
      .spyOn(window.parent, 'postMessage')
      .mockImplementation(() => {});
  });

  afterEach(() => {
    postMessage.mockRestore();
  });

  it('o 1º clique só pede confirmação: nada é enviado ao CRM', async () => {
    const painel = montar({ conversationId: 321, inboxId: 12 });
    await botaoComTexto(painel, 'Não receber campanhas').trigger('click');

    expect(postMessage).not.toHaveBeenCalled();
    expect(painel.text()).toContain('Só um administrador consegue reativar');
  });

  it('confirmar manda o telefone ao CRM, só para o mesmo origin', async () => {
    const painel = montar({ conversationId: 321, inboxId: 12 });
    await botaoComTexto(painel, 'Não receber campanhas').trigger('click');
    await botaoComTexto(painel, 'Sim, tirar').trigger('click');

    expect(postMessage).toHaveBeenCalledTimes(1);
    expect(postMessage).toHaveBeenCalledWith(
      { type: 'trama-nao-receber-campanhas', telefone: '+5511999990000' },
      window.location.origin
    );
    expect(painel.text()).toContain('Tirando o número das campanhas');
  });

  it('cancelar volta ao botão e não envia nada', async () => {
    const painel = montar({ conversationId: 321 });
    await botaoComTexto(painel, 'Não receber campanhas').trigger('click');
    await botaoComTexto(painel, 'Cancelar').trigger('click');

    expect(postMessage).not.toHaveBeenCalled();
    expect(botaoComTexto(painel, 'Não receber campanhas')).toBeTruthy();
  });

  it('resposta ok: mostra que o número saiu das campanhas', async () => {
    const painel = montar({ conversationId: 321 });
    await botaoComTexto(painel, 'Não receber campanhas').trigger('click');
    await botaoComTexto(painel, 'Sim, tirar').trigger('click');
    await responder({ type: RESPOSTA, ok: true, novo: true });

    expect(painel.text()).toContain('este número não recebe mais campanhas');
  });

  it('resposta ok com novo=false: diz que já estava fora', async () => {
    const painel = montar({ conversationId: 321 });
    await botaoComTexto(painel, 'Não receber campanhas').trigger('click');
    await botaoComTexto(painel, 'Sim, tirar').trigger('click');
    await responder({ type: RESPOSTA, ok: true, novo: false });

    expect(painel.text()).toContain('já estava fora das campanhas');
  });

  it('resposta com erro: mostra o texto do CRM e deixa tentar de novo', async () => {
    const painel = montar({ conversationId: 321 });
    await botaoComTexto(painel, 'Não receber campanhas').trigger('click');
    await botaoComTexto(painel, 'Sim, tirar').trigger('click');
    await responder({
      type: RESPOSTA,
      ok: false,
      error: 'Você não tem permissão para tirar este número das campanhas.',
    });

    expect(painel.find('[role="alert"]').text()).toContain(
      'Você não tem permissão'
    );
    expect(botaoComTexto(painel, 'Não receber campanhas')).toBeTruthy();
  });

  it('resposta de OUTRO origin, ou de outra janela, é ignorada', async () => {
    const painel = montar({ conversationId: 321 });
    await botaoComTexto(painel, 'Não receber campanhas').trigger('click');
    await botaoComTexto(painel, 'Sim, tirar').trigger('click');
    await responder(
      { type: RESPOSTA, ok: true, novo: true },
      { origin: 'https://site-malicioso.example' }
    );
    await responder({ type: RESPOSTA, ok: true, novo: true }, { source: null });

    expect(painel.text()).toContain('Tirando o número das campanhas');
    expect(painel.text()).not.toContain('não recebe mais campanhas');
  });

  it('resposta que chega SEM pedido em andamento não muda a tela', async () => {
    const painel = montar({ conversationId: 321 });
    await responder({ type: RESPOSTA, ok: true, novo: true });

    expect(painel.text()).not.toContain('não recebe mais campanhas');
  });

  it('depois de desmontar, o painel não escuta mais o CRM', async () => {
    const remover = vi.spyOn(window, 'removeEventListener');
    const painel = montar({ conversationId: 321 });
    painel.unmount();

    expect(remover.mock.calls.some(c => c[0] === 'message')).toBe(true);
    remover.mockRestore();
  });
});

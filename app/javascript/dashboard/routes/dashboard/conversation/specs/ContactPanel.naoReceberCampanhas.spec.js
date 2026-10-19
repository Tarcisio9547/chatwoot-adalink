import { mount } from '@vue/test-utils';
import { ref } from 'vue';
import ContactPanel from '../ContactPanel.vue';

// Botão "Não receber campanhas de WhatsApp": pedido ao CRM (window.parent) só
// depois da confirmação, e a resposta do CRM (mesmo origin, mesmo requestId)
// decide a mensagem na tela. Store, preferências de UI e filhos entram como
// dublês mínimos.
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
const BOTAO = 'Não receber campanhas de WhatsApp';

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

describe('ContactPanel: botão Não receber campanhas de WhatsApp', () => {
  let postMessage;
  const pedido = () => postMessage.mock.calls.at(-1)[0];

  const pedirEConfirmar = async painel => {
    await botaoComTexto(painel, BOTAO).trigger('click');
    await botaoComTexto(painel, 'Sim, tirar').trigger('click');
  };

  beforeEach(() => {
    postMessage = vi
      .spyOn(window.parent, 'postMessage')
      .mockImplementation(() => {});
  });

  afterEach(() => {
    postMessage.mockRestore();
    vi.useRealTimers();
  });

  it('o 1º clique só pede confirmação: nada é enviado ao CRM', async () => {
    const painel = montar({ conversationId: 321, inboxId: 12 });
    await botaoComTexto(painel, BOTAO).trigger('click');

    expect(postMessage).not.toHaveBeenCalled();
    expect(painel.text()).toContain('a fila de ligação não muda');
    expect(painel.text()).toContain('um administrador precisa reativar');
  });

  it('confirmar manda telefone e requestId ao CRM, só para o mesmo origin', async () => {
    const painel = montar({ conversationId: 321, inboxId: 12 });
    await pedirEConfirmar(painel);

    expect(postMessage).toHaveBeenCalledTimes(1);
    expect(postMessage).toHaveBeenCalledWith(
      {
        type: 'trama-nao-receber-campanhas',
        telefone: '+5511999990000',
        requestId: expect.any(String),
      },
      window.location.origin
    );
    expect(pedido().requestId).not.toBe('');
    expect(painel.text()).toContain('Tirando o número das campanhas');
  });

  it('cancelar volta ao botão e não envia nada', async () => {
    const painel = montar({ conversationId: 321 });
    await botaoComTexto(painel, BOTAO).trigger('click');
    await botaoComTexto(painel, 'Cancelar').trigger('click');

    expect(postMessage).not.toHaveBeenCalled();
    expect(botaoComTexto(painel, BOTAO)).toBeTruthy();
  });

  it('resposta ok do MESMO pedido: mostra que o número saiu das campanhas', async () => {
    const painel = montar({ conversationId: 321 });
    await pedirEConfirmar(painel);
    await responder({
      type: RESPOSTA,
      requestId: pedido().requestId,
      ok: true,
      novo: true,
    });

    expect(painel.text()).toContain('este número não recebe mais campanhas');
  });

  it('resposta ok com novo=false: diz que já estava fora', async () => {
    const painel = montar({ conversationId: 321 });
    await pedirEConfirmar(painel);
    await responder({
      type: RESPOSTA,
      requestId: pedido().requestId,
      ok: true,
      novo: false,
    });

    expect(painel.text()).toContain('já estava fora das campanhas');
  });

  it('resposta com erro: mostra o texto do CRM e deixa tentar de novo', async () => {
    const painel = montar({ conversationId: 321 });
    await pedirEConfirmar(painel);
    await responder({
      type: RESPOSTA,
      requestId: pedido().requestId,
      ok: false,
      error: 'Você não tem permissão para tirar este número das campanhas.',
    });

    expect(painel.find('[role="alert"]').text()).toContain(
      'Você não tem permissão'
    );
    expect(botaoComTexto(painel, BOTAO)).toBeTruthy();
  });

  it('resposta de OUTRO pedido (requestId diferente ou ausente) é ignorada', async () => {
    const painel = montar({ conversationId: 321 });
    await pedirEConfirmar(painel);
    await responder({
      type: RESPOSTA,
      requestId: 'de-outro',
      ok: true,
      novo: true,
    });
    await responder({ type: RESPOSTA, ok: true, novo: true });

    expect(painel.text()).toContain('Tirando o número das campanhas');
    expect(painel.text()).not.toContain('não recebe mais campanhas');
  });

  it('resposta de OUTRO origin, ou de outra janela, é ignorada', async () => {
    const painel = montar({ conversationId: 321 });
    await pedirEConfirmar(painel);
    const ok = {
      type: RESPOSTA,
      requestId: pedido().requestId,
      ok: true,
      novo: true,
    };
    await responder(ok, { origin: 'https://site-malicioso.example' });
    await responder(ok, { source: null });

    expect(painel.text()).toContain('Tirando o número das campanhas');
    expect(painel.text()).not.toContain('não recebe mais campanhas');
  });

  it('resposta que chega SEM pedido em andamento não muda a tela', async () => {
    const painel = montar({ conversationId: 321 });
    await responder({ type: RESPOSTA, requestId: 'x', ok: true, novo: true });

    expect(painel.text()).not.toContain('não recebe mais campanhas');
  });

  it('o CRM não responde em 15 s: sai de "enviando" com erro e deixa tentar de novo', async () => {
    vi.useFakeTimers();
    const painel = montar({ conversationId: 321 });
    await pedirEConfirmar(painel);
    const idAntigo = pedido().requestId;

    await vi.advanceTimersByTimeAsync(15000);
    expect(painel.find('[role="alert"]').text()).toContain(
      'O CRM não respondeu'
    );
    expect(botaoComTexto(painel, BOTAO)).toBeTruthy();

    // A resposta tardia do pedido que já deu timeout não vira "Pronto".
    await responder({
      type: RESPOSTA,
      requestId: idAntigo,
      ok: true,
      novo: true,
    });
    expect(painel.text()).not.toContain('não recebe mais campanhas');
  });

  it('resposta do pedido ANTERIOR não vale para o pedido novo', async () => {
    vi.useFakeTimers();
    const painel = montar({ conversationId: 321 });
    await pedirEConfirmar(painel);
    const idAntigo = pedido().requestId;
    await vi.advanceTimersByTimeAsync(15000); // 1º pedido estoura o tempo
    await pedirEConfirmar(painel); // 2º pedido
    expect(pedido().requestId).not.toBe(idAntigo);

    await responder({
      type: RESPOSTA,
      requestId: idAntigo,
      ok: true,
      novo: true,
    });
    expect(painel.text()).toContain('Tirando o número das campanhas');
    expect(painel.text()).not.toContain('não recebe mais campanhas');
  });

  it('com resposta a tempo, o timeout não derruba o resultado', async () => {
    vi.useFakeTimers();
    const painel = montar({ conversationId: 321 });
    await pedirEConfirmar(painel);
    await responder({
      type: RESPOSTA,
      requestId: pedido().requestId,
      ok: true,
      novo: true,
    });
    await vi.advanceTimersByTimeAsync(20000);

    expect(painel.text()).toContain('este número não recebe mais campanhas');
    expect(painel.find('[role="alert"]').exists()).toBe(false);
  });

  it('depois de desmontar, o painel não escuta mais o CRM', async () => {
    const remover = vi.spyOn(window, 'removeEventListener');
    const painel = montar({ conversationId: 321 });
    painel.unmount();

    expect(remover.mock.calls.some(c => c[0] === 'message')).toBe(true);
    remover.mockRestore();
  });
});

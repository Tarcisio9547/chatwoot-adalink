import { mount } from '@vue/test-utils';
import { ref } from 'vue';
import ContactPanel from '../ContactPanel.vue';

// Só o botão "Criar Negócio" importa aqui: o store, as preferências de UI e os
// componentes filhos entram como dublês mínimos, pra provar que a mensagem enviada
// ao CRM (window.parent) leva a conversa e a caixa abertas.
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

describe('ContactPanel: botão Criar Negócio', () => {
  let postMessage;

  beforeEach(() => {
    // jsdom: window.parent === window
    postMessage = vi
      .spyOn(window.parent, 'postMessage')
      .mockImplementation(() => {});
  });

  afterEach(() => {
    postMessage.mockRestore();
  });

  it('manda ao CRM o contato, a conversa e a caixa abertas', async () => {
    const painel = montar({ conversationId: 321, inboxId: 12 });
    await painel.find('button').trigger('click');

    expect(postMessage).toHaveBeenCalledTimes(1);
    expect(postMessage).toHaveBeenCalledWith(
      {
        type: 'trama-criar-negocio',
        contato: {
          nome: 'Maria Souza',
          telefone: '+5511999990000',
          email: 'maria@exemplo.com',
          chatwoot_contact_id: 77,
        },
        conversationId: 321,
        inboxId: 12,
      },
      '*'
    );
  });

  it('sem inboxId na prop, a mensagem segue sem esse campo (CRM tolera)', async () => {
    const painel = montar({ conversationId: 321 });
    await painel.find('button').trigger('click');

    const [mensagem] = postMessage.mock.calls[0];
    expect(mensagem.conversationId).toBe(321);
    expect(mensagem).not.toHaveProperty('inboxId');
  });
});

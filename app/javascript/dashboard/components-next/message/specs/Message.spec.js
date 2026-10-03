import { mount } from '@vue/test-utils';
import { ref } from 'vue';
import Message from '../Message.vue';

// Só o que depende de Vuex/rota/analytics é trocado; o balão de texto, o
// Base.vue e o template da raiz de Message.vue renderizam de verdade.
vi.mock('dashboard/composables/store', async importOriginal => ({
  ...(await importOriginal()),
  useMapGetter: () => ref(() => ({})),
  useStoreGetters: () => ({ getUISettings: ref({}) }),
  useStore: () => ({ getters: {}, dispatch: vi.fn() }),
}));
vi.mock('vue-router', () => ({
  useRoute: () => ({ query: {}, params: {} }),
  useRouter: () => ({ push: vi.fn() }),
}));
vi.mock('dashboard/composables', () => ({
  useTrack: vi.fn(),
  useAlert: vi.fn(),
}));
vi.mock(
  'dashboard/modules/conversations/components/MessageContextMenu.vue',
  () => ({ default: { name: 'ContextMenu', template: '<div />' } })
);

const baseProps = {
  id: 4321,
  messageType: 0, // incoming
  status: 'sent',
  content: '[imagem]',
  createdAt: 1_760_000_000,
  currentUserId: 1,
  conversationId: 77,
  inboxId: 12,
  sender: { id: 9, name: 'Cliente', type: 'contact' },
  senderType: 'Contact',
};

const mountMessage = props =>
  mount(Message, {
    props: { ...baseProps, ...props },
    global: {
      directives: {
        dompurifyHtml: (el, binding) => {
          el.innerHTML = binding.value;
        },
      },
    },
  });

describe('Message.vue — atributos para o CRM da Adalink', () => {
  it('expõe data-source-id e data-inbox-id na raiz da mensagem', () => {
    const wrapper = mountMessage({ sourceId: '3EB0A1B2C3D4E5F60718' });
    const root = wrapper.element;

    expect(root.getAttribute('data-message-id')).toBe('4321');
    expect(root.getAttribute('data-source-id')).toBe('3EB0A1B2C3D4E5F60718');
    expect(root.getAttribute('data-inbox-id')).toBe('12');
  });

  it('o balão de texto fica dentro da raiz que carrega o source_id', () => {
    const wrapper = mountMessage({ sourceId: '3EB0A1B2C3D4E5F60718' });
    const bubble = wrapper.element.querySelector('[data-bubble-name="text"]');

    expect(bubble).not.toBeNull();
    expect(bubble.closest('[data-source-id]')).toBe(wrapper.element);
    expect(bubble.closest('[data-source-id]').dataset.sourceId).toBe(
      '3EB0A1B2C3D4E5F60718'
    );
    expect(bubble.querySelector('.prose').textContent.trim()).toBe('[imagem]');
  });

  it('não escreve o atributo quando a mensagem não tem source_id', () => {
    const semSourceId = mountMessage({ sourceId: '' });
    expect(semSourceId.element.hasAttribute('data-source-id')).toBe(false);

    const nulo = mountMessage({ sourceId: null });
    expect(nulo.element.hasAttribute('data-source-id')).toBe(false);
  });

  it('não escreve data-inbox-id quando a mensagem não tem inbox', () => {
    const wrapper = mountMessage({ inboxId: null });
    expect(wrapper.element.hasAttribute('data-inbox-id')).toBe(false);
  });
});

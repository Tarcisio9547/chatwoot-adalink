import { mount } from '@vue/test-utils';
import ChatListSearch from '../ChatListSearch.vue';
import MessagePreview from '../widgets/conversation/MessagePreview.vue';
import { emitter } from 'shared/helpers/mitt';

// Trama: lista de conversas com cara de WhatsApp.
// 1) O campo de busca da lista abre a busca completa do Chatwoot com o termo.
// 2) A prévia da última mensagem enviada por nós mostra ✓ / ✓✓ / ✓✓ azul.
const push = vi.fn();
vi.mock('vue-router', () => ({ useRouter: () => ({ push }) }));
vi.mock('dashboard/composables/store.js', () => ({
  useMapGetter: () => ({ value: 7 }),
}));

describe('ChatListSearch', () => {
  const montar = () =>
    mount(ChatListSearch, { global: { mocks: { $t: chave => chave } } });

  beforeEach(() => push.mockReset());

  it('abre a busca existente com o termo digitado ao apertar Enter', async () => {
    const wrapper = montar();
    await wrapper.find('input').setValue('  Marina  ');
    await wrapper.find('form').trigger('submit');
    expect(push).toHaveBeenCalledWith({
      name: 'search',
      params: { accountId: 7 },
      query: { q: 'Marina' },
    });
  });

  it('sem termo, só abre a tela de busca', async () => {
    const wrapper = montar();
    await wrapper.find('form').trigger('submit');
    expect(push).toHaveBeenCalledWith({
      name: 'search',
      params: { accountId: 7 },
    });
  });

  it('limpa o campo quando a lista troca de aba (clearSearchInput)', async () => {
    const wrapper = montar();
    await wrapper.find('input').setValue('algo');
    emitter.emit('clearSearchInput');
    await wrapper.vm.$nextTick();
    expect(wrapper.find('input').element.value).toBe('');
  });
});

describe('MessagePreview: tiques da última mensagem enviada', () => {
  const montar = message =>
    mount(MessagePreview, {
      props: {
        message: { content: 'Oi', attachments: [], ...message },
      },
      global: {
        mocks: { $t: chave => chave },
        stubs: { 'fluent-icon': true },
      },
    });

  it('enviada mostra ✓ cinza', () => {
    const icone = montar({ message_type: 1, status: 'sent' }).find(
      '.i-lucide-check'
    );
    expect(icone.exists()).toBe(true);
    expect(icone.classes()).not.toContain('trama-lido');
  });

  it('entregue mostra ✓✓ cinza', () => {
    const icone = montar({ message_type: 1, status: 'delivered' }).find(
      '.i-lucide-check-check'
    );
    expect(icone.exists()).toBe(true);
    expect(icone.classes()).not.toContain('trama-lido');
  });

  it('lida mostra ✓✓ azul', () => {
    const icone = montar({ message_type: 1, status: 'read' }).find(
      '.i-lucide-check-check'
    );
    expect(icone.classes()).toContain('trama-lido');
  });

  it('mensagem recebida não mostra tique', () => {
    const wrapper = montar({ message_type: 0, status: 'read' });
    expect(wrapper.find('[class*="i-lucide-check"]').exists()).toBe(false);
  });

  it('enviada sem status conhecido mantém a seta de resposta', () => {
    const wrapper = montar({ message_type: 1, status: 'failed' });
    expect(wrapper.find('[class*="i-lucide-check"]').exists()).toBe(false);
    expect(wrapper.find('fluent-icon-stub[icon="arrow-reply"]').exists()).toBe(
      true
    );
  });
});

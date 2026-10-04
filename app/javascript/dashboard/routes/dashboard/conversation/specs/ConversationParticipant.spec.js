import { mount } from '@vue/test-utils';
import { createStore } from 'vuex';
import ConversationParticipant from '../ConversationParticipant.vue';
import {
  state as agentsState,
  getters as agentsGetters,
} from '../../../../store/modules/agents';

// A lista de candidatos a participante é a de TODOS os agentes confirmados da
// conta, não só os membros da caixa da conversa. O store de agentes entra de
// verdade (getter e filtro de confirmados); o resto vira dublê mínimo.
const agente = (id, nome, extra = {}) => ({
  id,
  name: nome,
  email: `${nome.toLowerCase()}@exemplo.com`,
  role: 'agent',
  confirmed: true,
  availability_status: 'offline',
  ...extra,
});

const voce = agente(1, 'Voce', { availability_status: 'offline' });

const montar = (agentes, { actions = {} } = {}) => {
  const store = createStore({
    getters: {
      getCurrentUser: () => ({
        ...voce,
        accounts: [{ id: 7, availability_status: 'online' }],
      }),
      getCurrentAccountId: () => 7,
    },
    modules: {
      agents: {
        namespaced: true,
        state: { ...agentsState, records: agentes },
        getters: agentsGetters,
        actions: { get: vi.fn(), ...actions },
      },
      conversationWatchers: {
        namespaced: true,
        getters: {
          getUIFlags: () => ({ isFetching: false }),
          getByConversationId: () => () => [],
        },
        actions: { show: vi.fn(), update: vi.fn() },
      },
    },
  });

  const wrapper = mount(ConversationParticipant, {
    props: { conversationId: 321 },
    global: {
      plugins: [store],
      mocks: { $t: chave => chave },
      directives: { tooltip: {}, onClickaway: {}, 'on-clickaway': {} },
      stubs: {
        Spinner: true,
        ThumbnailGroup: true,
        NextButton: true,
        MultiselectDropdownItems: {
          name: 'MultiselectDropdownItems',
          props: ['options', 'selectedItems'],
          template: '<div class="multiselect-stub" />',
        },
      },
    },
  });
  return { wrapper, store };
};

const opcoes = wrapper =>
  wrapper.findComponent({ name: 'MultiselectDropdownItems' }).props('options');

describe('ConversationParticipant: lista de candidatos', () => {
  it('oferece todos os agentes confirmados da conta (inclusive quem não é da caixa)', () => {
    const { wrapper } = montar([
      voce,
      agente(2, 'Ana', { availability_status: 'online' }),
      agente(3, 'Bruno', { availability_status: 'busy' }),
      agente(4, 'Carla', {
        availability_status: 'offline',
        role: 'administrator',
      }),
    ]);

    const nomes = opcoes(wrapper).map(item => item.name);

    expect(nomes).toHaveLength(4);
    expect(nomes).toEqual(
      expect.arrayContaining(['Voce', 'Ana', 'Bruno', 'Carla'])
    );
  });

  it('esconde quem ainda não confirmou o convite', () => {
    const { wrapper } = montar([
      voce,
      agente(2, 'Ana', { availability_status: 'online' }),
      agente(5, 'Pendente', {
        confirmed: false,
        availability_status: 'offline',
      }),
    ]);

    const nomes = opcoes(wrapper).map(item => item.name);

    expect(nomes).toContain('Ana');
    expect(nomes).not.toContain('Pendente');
  });

  it('ordena por presença: online, ocupado, offline', () => {
    const { wrapper } = montar([
      agente(2, 'Zeca', { availability_status: 'offline' }),
      agente(3, 'Bia', { availability_status: 'busy' }),
      agente(4, 'Ana', { availability_status: 'online' }),
    ]);

    expect(opcoes(wrapper).map(item => item.name)).toEqual([
      'Ana',
      'Bia',
      'Zeca',
    ]);
  });

  it('usa a presença da conta para o próprio usuário', () => {
    const { wrapper } = montar([
      voce,
      agente(2, 'Ana', { availability_status: 'busy' }),
    ]);

    const eu = opcoes(wrapper).find(item => item.id === 1);

    expect(eu.availability_status).toBe('online');
  });

  it('carrega os agentes da conta ao abrir', () => {
    const get = vi.fn();
    montar([voce], { actions: { get } });

    expect(get).toHaveBeenCalledTimes(1);
  });

  it('não depende de a caixa da conversa estar carregada (lista vazia só se a conta não tem agentes)', () => {
    const { wrapper } = montar([]);

    expect(opcoes(wrapper)).toEqual([]);
  });
});

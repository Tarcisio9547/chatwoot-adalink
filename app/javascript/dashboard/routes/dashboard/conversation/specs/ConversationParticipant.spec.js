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

const montar = (
  agentes,
  { actions = {}, role = 'agent', permissions = [], assigneeId = null } = {}
) => {
  const update = vi.fn();
  const store = createStore({
    getters: {
      getCurrentUser: () => ({
        ...voce,
        accounts: [
          {
            id: 7,
            availability_status: 'online',
            role: role === 'administrator' ? 'administrator' : 'agent',
            custom_role_id: role === 'custom_role' ? 5 : null,
            permissions,
          },
        ],
      }),
      getCurrentAccountId: () => 7,
      getConversationById: () => () => ({
        id: 321,
        meta: { assignee: assigneeId ? { id: assigneeId } : null },
      }),
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
        actions: { show: vi.fn(), update },
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
        NextButton: {
          name: 'NextButton',
          props: ['label', 'icon'],
          template: '<button class="next-button" :data-icon="icon" />',
        },
        MultiselectDropdownItems: {
          name: 'MultiselectDropdownItems',
          props: ['options', 'selectedItems'],
          template: '<div class="multiselect-stub" />',
        },
      },
    },
  });
  return { wrapper, store, update };
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

// Participar dá acesso à conversa, então só administrador, agente sem custom_role,
// "Todas" ou o responsável atual veem o "Participar" e a edição da lista (mesma regra
// do servidor, ConversationPolicy#manage_participants?). Os demais só leem.
describe('ConversationParticipant: quem pode alterar a lista', () => {
  const botoes = wrapper => wrapper.findAllComponents({ name: 'NextButton' });
  const temEngrenagem = wrapper =>
    botoes(wrapper).some(botao => botao.props('icon') === 'i-lucide-settings');
  const temParticipar = wrapper =>
    botoes(wrapper).some(
      botao =>
        botao.props('label') === 'CONVERSATION_PARTICIPANTS.WATCH_CONVERSATION'
    );
  const temSeletor = wrapper =>
    wrapper.findComponent({ name: 'MultiselectDropdownItems' }).exists();

  it.each([
    ['administrador', { role: 'administrator' }],
    ['agente sem custom_role', { role: 'agent' }],
    [
      'custom_role "Todas"',
      { role: 'custom_role', permissions: ['conversation_manage'] },
    ],
    [
      'responsável "Minhas"',
      {
        role: 'custom_role',
        permissions: ['conversation_participating_manage'],
        assigneeId: 1,
      },
    ],
    [
      'responsável "Não atribuídas"',
      {
        role: 'custom_role',
        permissions: ['conversation_unassigned_manage'],
        assigneeId: 1,
      },
    ],
  ])('%s vê o Participar, a engrenagem e o seletor', (_nome, opcoesUsuario) => {
    const { wrapper } = montar([voce], opcoesUsuario);

    expect(temParticipar(wrapper)).toBe(true);
    expect(temEngrenagem(wrapper)).toBe(true);
    expect(temSeletor(wrapper)).toBe(true);
  });

  it.each([
    ['Minhas', ['conversation_participating_manage']],
    ['Não atribuídas', ['conversation_unassigned_manage']],
  ])(
    'com a visão restrita %s e sem ser o responsável: sem Participar, sem engrenagem, sem seletor',
    (_nome, permissions) => {
      const { wrapper } = montar([voce], {
        role: 'custom_role',
        permissions,
        assigneeId: 2,
      });

      expect(temParticipar(wrapper)).toBe(false);
      expect(temEngrenagem(wrapper)).toBe(false);
      expect(temSeletor(wrapper)).toBe(false);
    }
  );

  it('restrito em conversa sem responsável também não vê o Participar', () => {
    const { wrapper } = montar([voce], {
      role: 'custom_role',
      permissions: ['conversation_unassigned_manage'],
      assigneeId: null,
    });

    expect(temParticipar(wrapper)).toBe(false);
    expect(temEngrenagem(wrapper)).toBe(false);
  });
});

// O responsável restrito adiciona participantes mas não remove: clicar num já selecionado não faz nada
// (o servidor também barra com 401). Administrador, agente sem custom_role e "Todas" removem.
describe('ConversationParticipant: remover participante', () => {
  const ana = agente(2, 'Ana', { availability_status: 'online' });
  const bruno = agente(3, 'Bruno', { availability_status: 'online' });
  const seletor = wrapper =>
    wrapper.findComponent({ name: 'MultiselectDropdownItems' });
  const idsEnviados = update =>
    update.mock.calls.map(([, payload]) => payload.userIds);

  it('o responsável restrito adiciona mas não remove', async () => {
    const { wrapper, update } = montar([voce, ana, bruno], {
      role: 'custom_role',
      permissions: ['conversation_unassigned_manage'],
      assigneeId: 1,
    });
    await wrapper.setData({ selectedWatchers: [ana] });

    seletor(wrapper).vm.$emit('select', ana); // já é participante: seria remover
    await wrapper.vm.$nextTick();
    expect(update).not.toHaveBeenCalled();

    seletor(wrapper).vm.$emit('select', bruno); // adicionar
    await wrapper.vm.$nextTick();
    expect(idsEnviados(update)).toEqual([[2, 3]]);
  });

  it.each([
    ['agente sem custom_role', { role: 'agent' }],
    ['administrador', { role: 'administrator' }],
    ['"Todas"', { role: 'custom_role', permissions: ['conversation_manage'] }],
  ])('%s remove', async (_nome, opcoesUsuario) => {
    const { wrapper, update } = montar([voce, ana, bruno], opcoesUsuario);
    await wrapper.setData({ selectedWatchers: [ana] });

    seletor(wrapper).vm.$emit('select', ana);
    await wrapper.vm.$nextTick();

    expect(idsEnviados(update)).toEqual([[]]);
  });
});

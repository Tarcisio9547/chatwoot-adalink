import { describe, it, beforeEach, expect, vi } from 'vitest';
import ActionCableConnector from '../actionCable';

vi.mock('shared/helpers/mitt', () => ({
  emitter: {
    emit: vi.fn(),
  },
}));

vi.mock('dashboard/composables/useImpersonation', () => ({
  useImpersonation: () => ({
    isImpersonating: { value: false },
  }),
}));

global.chatwootConfig = {
  websocketURL: 'wss://test.chatwoot.com',
};

describe('ActionCableConnector - Copilot Tests', () => {
  let store;
  let actionCable;
  let mockDispatch;

  beforeEach(() => {
    vi.clearAllMocks();
    mockDispatch = vi.fn();
    store = {
      $store: {
        dispatch: mockDispatch,
        getters: {
          getCurrentAccountId: 1,
        },
      },
    };

    actionCable = ActionCableConnector.init(store.$store, 'test-token');
  });
  describe('copilot event handlers', () => {
    it('should register the copilot.message.created event handler', () => {
      expect(Object.keys(actionCable.events)).toContain(
        'copilot.message.created'
      );
      expect(actionCable.events['copilot.message.created']).toBe(
        actionCable.onCopilotMessageCreated
      );
    });

    it('should handle the copilot.message.created event through the ActionCable system', () => {
      const copilotData = {
        id: 2,
        content: 'This is a copilot message from ActionCable',
        conversation_id: 456,
        created_at: '2025-05-27T15:58:04-06:00',
        account_id: 1,
      };
      actionCable.onReceived({
        event: 'copilot.message.created',
        data: copilotData,
      });
      expect(mockDispatch).toHaveBeenCalledWith(
        'copilotMessages/upsert',
        copilotData
      );
    });
  });
});

// conversation.participants_changed: quem entrou passa a ver a conversa, quem saiu a perde.
// O servidor manda o payload de agente (com participant_ids) a membros, participantes e a
// quem foi removido. A tela só guarda a conversa se ela já estava na lista ou se o usuário
// logado é participante, para não "ressuscitar" na lista de quem acabou de sair.
describe('ActionCableConnector - participants changed', () => {
  const buildConnector = ({ currentUserId, knownConversationIds }) => {
    const dispatch = vi.fn();
    const $store = {
      dispatch,
      getters: {
        getCurrentAccountId: 1,
        getCurrentUser: { id: currentUserId },
        getConversationById: id =>
          knownConversationIds.includes(id) ? { id } : undefined,
      },
    };
    return {
      dispatch,
      actionCable: ActionCableConnector.init($store, 'test-token'),
    };
  };

  const payload = { account_id: 1, id: 77, participant_ids: [5, 9], meta: {} };

  it('registers the conversation.participants_changed handler', () => {
    const { actionCable } = buildConnector({
      currentUserId: 5,
      knownConversationIds: [],
    });

    expect(actionCable.onConversationParticipantsChanged).toBeTypeOf(
      'function'
    );
    expect(actionCable.events['conversation.participants_changed']).toBe(
      actionCable.onConversationParticipantsChanged
    );
  });

  it('adds the conversation when the current user just became a participant', () => {
    const { actionCable, dispatch } = buildConnector({
      currentUserId: 5,
      knownConversationIds: [],
    });

    actionCable.onReceived({
      event: 'conversation.participants_changed',
      data: payload,
    });

    expect(dispatch).toHaveBeenCalledWith('updateConversation', payload);
  });

  it('updates a conversation that is already on the list (e.g. the user was removed: the role filter hides it)', () => {
    const { actionCable, dispatch } = buildConnector({
      currentUserId: 42,
      knownConversationIds: [77],
    });

    actionCable.onReceived({
      event: 'conversation.participants_changed',
      data: payload,
    });

    expect(dispatch).toHaveBeenCalledWith('updateConversation', payload);
  });

  it('ignores it when the user is not a participant and does not hold the conversation', () => {
    const { actionCable, dispatch } = buildConnector({
      currentUserId: 42,
      knownConversationIds: [],
    });

    actionCable.onReceived({
      event: 'conversation.participants_changed',
      data: payload,
    });

    expect(dispatch).not.toHaveBeenCalledWith(
      'updateConversation',
      expect.anything()
    );
  });

  it('ignores events from another account', () => {
    const { actionCable, dispatch } = buildConnector({
      currentUserId: 5,
      knownConversationIds: [77],
    });

    actionCable.onReceived({
      event: 'conversation.participants_changed',
      data: { ...payload, account_id: 2 },
    });

    expect(dispatch).not.toHaveBeenCalled();
  });
});

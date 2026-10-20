import { computed } from 'vue';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';

// Trama: "Atribuir a mim" do cabeçalho da conversa e do painel "Dados do contato".
// Faz exatamente o que o "Atribuir a mim" de ConversationAction.vue (onSelfAssign)
// já fazia: setCurrentChatAssignee + assignAgent com o usuário logado.
export const useTramaAtribuirAMim = () => {
  const store = useStore();
  const currentChat = useMapGetter('getSelectedChat');
  const currentUser = useMapGetter('getCurrentUser');

  const responsavel = computed(() => currentChat.value?.meta?.assignee || null);

  const souResponsavel = computed(
    () =>
      !!responsavel.value &&
      !!currentUser.value?.id &&
      responsavel.value.id === currentUser.value.id
  );

  const atribuirAMim = async mensagemSucesso => {
    const chat = currentChat.value;
    const usuario = currentUser.value;
    if (!chat?.id || !usuario?.id || souResponsavel.value) return;

    const {
      account_id,
      availability_status,
      available_name,
      email,
      id,
      name,
      role,
      avatar_url,
    } = usuario;
    const agente = {
      account_id,
      availability_status,
      available_name,
      email,
      id,
      name,
      role,
      thumbnail: avatar_url,
    };

    store.dispatch('setCurrentChatAssignee', {
      conversationId: chat.id,
      assignee: agente,
    });
    await store.dispatch('assignAgent', {
      conversationId: chat.id,
      agentId: id,
    });
    if (mensagemSucesso) useAlert(mensagemSucesso);
  };

  return { responsavel, souResponsavel, atribuirAMim };
};

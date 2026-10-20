<script setup>
import { computed, ref, watch } from 'vue';
import { useRouter } from 'vue-router';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { getLastMessage } from 'dashboard/helper/conversationHelper';
import { frontendURL, conversationUrl } from 'dashboard/helper/URLHelper';
import Avatar from 'next/avatar/Avatar.vue';
import MessagePreview from './MessagePreview.vue';
import InboxName from '../InboxName.vue';
import ConversationContextMenu from './contextMenu/Index.vue';
import TimeAgo from 'dashboard/components/ui/TimeAgo.vue';
import CardLabels from './conversationCardComponents/CardLabels.vue';
import CardPriorityIcon from 'dashboard/components-next/Conversation/ConversationCard/CardPriorityIcon.vue';
import SLACardLabel from './components/SLACardLabel.vue';
import ContextMenu from 'dashboard/components/ui/ContextMenu.vue';
import VoiceCallStatus from './VoiceCallStatus.vue';

const props = defineProps({
  activeLabel: { type: String, default: '' },
  chat: { type: Object, default: () => ({}) },
  hideInboxName: { type: Boolean, default: false },
  hideThumbnail: { type: Boolean, default: false },
  teamId: { type: [String, Number], default: 0 },
  foldersId: { type: [String, Number], default: 0 },
  conversationType: { type: String, default: '' },
  selected: { type: Boolean, default: false },
  compact: { type: Boolean, default: false },
  enableContextMenu: { type: Boolean, default: false },
  allowedContextMenuOptions: { type: Array, default: () => [] },
});

const emit = defineEmits([
  'contextMenuToggle',
  'assignAgent',
  'assignLabel',
  'removeLabel',
  'assignTeam',
  'markAsUnread',
  'markAsRead',
  'assignPriority',
  'updateConversationStatus',
  'deleteConversation',
  'selectConversation',
  'deSelectConversation',
]);

const router = useRouter();
const store = useStore();

const hovered = ref(false);
const showContextMenu = ref(false);
const contextMenu = ref({ x: null, y: null });

// Reset UI state when conversation changes at same index (no :key, instance reused on reorder)
// This prevents context menu/hover state from leaking to a different conversation
// Emit contextMenuToggle(false) to sync parent state if menu was open during recycling
const resetState = () => {
  if (showContextMenu.value) {
    emit('contextMenuToggle', false);
  }
  hovered.value = false;
  showContextMenu.value = false;
  contextMenu.value = { x: null, y: null };
};

watch(() => props.chat.id, resetState);

const currentChat = useMapGetter('getSelectedChat');
const inboxesList = useMapGetter('inboxes/getInboxes');
const activeInbox = useMapGetter('getSelectedInbox');
const accountId = useMapGetter('getCurrentAccountId');

const chatMetadata = computed(() => props.chat.meta || {});

const senderId = computed(() => chatMetadata.value.sender?.id);

const currentContact = computed(() => {
  return senderId.value
    ? store.getters['contacts/getContact'](senderId.value)
    : {};
});

const isActiveChat = computed(() => {
  return currentChat.value.id === props.chat.id;
});

const unreadCount = computed(() => props.chat.unread_count);

const hasUnread = computed(() => unreadCount.value > 0);

const isInboxNameVisible = computed(() => !activeInbox.value);

const lastMessageInChat = computed(() => getLastMessage(props.chat));

const voiceCallData = computed(() => ({
  status: props.chat.additional_attributes?.call_status,
  direction: props.chat.additional_attributes?.call_direction,
}));

const inboxId = computed(() => props.chat.inbox_id);

const inbox = computed(() => {
  return inboxId.value ? store.getters['inboxes/getInbox'](inboxId.value) : {};
});

const showInboxName = computed(() => {
  return (
    !props.hideInboxName &&
    isInboxNameVisible.value &&
    inboxesList.value.length > 1
  );
});

// Trama (lista com cara de WhatsApp): o nome da caixa e o responsável saíram
// do cartão da lista principal (aparecem no cabeçalho da conversa). No modo
// compacto (conversas anteriores no painel do contato) a caixa continua
// aparecendo, porque lá não há outro lugar que diga de qual caixa ela é.
const showCompactInboxName = computed(() => {
  return props.compact && showInboxName.value;
});

const hasSlaPolicyId = computed(() => props.chat?.sla_policy_id);

const showLabelsSection = computed(() => {
  return props.chat.labels?.length > 0 || hasSlaPolicyId.value;
});

const conversationPath = computed(() => {
  return frontendURL(
    conversationUrl({
      accountId: accountId.value,
      activeInbox: activeInbox.value,
      id: props.chat.id,
      label: props.activeLabel,
      teamId: props.teamId,
      conversationType: props.conversationType,
      foldersId: props.foldersId,
    })
  );
});

const onCardClick = e => {
  const path = conversationPath.value;
  if (!path) return;

  // Handle Ctrl/Cmd + Click for new tab
  if (e.metaKey || e.ctrlKey) {
    e.preventDefault();
    window.open(
      `${window.chatwootConfig.hostURL}${path}`,
      '_blank',
      'noopener,noreferrer'
    );
    return;
  }

  // Skip if already active
  if (isActiveChat.value) return;

  router.push({ path });
};

const onThumbnailHover = () => {
  hovered.value = !props.hideThumbnail;
};

const onThumbnailLeave = () => {
  hovered.value = false;
};

const onSelectConversation = checked => {
  if (checked) {
    emit('selectConversation', props.chat.id, inbox.value.id);
  } else {
    emit('deSelectConversation', props.chat.id, inbox.value.id);
  }
};

const openContextMenu = e => {
  if (!props.enableContextMenu) return;
  e.preventDefault();
  emit('contextMenuToggle', true);
  contextMenu.value.x = e.pageX || e.clientX;
  contextMenu.value.y = e.pageY || e.clientY;
  showContextMenu.value = true;
};

const closeContextMenu = () => {
  emit('contextMenuToggle', false);
  showContextMenu.value = false;
  contextMenu.value.x = null;
  contextMenu.value.y = null;
};

const onUpdateConversation = (status, snoozedUntil) => {
  closeContextMenu();
  emit('updateConversationStatus', props.chat.id, status, snoozedUntil);
};

const onAssignAgent = agent => {
  emit('assignAgent', agent, [props.chat.id]);
  closeContextMenu();
};

const onAssignLabel = label => {
  emit('assignLabel', [label.title], [props.chat.id]);
};

const onRemoveLabel = label => {
  emit('removeLabel', [label.title], [props.chat.id]);
};

const onAssignTeam = team => {
  emit('assignTeam', team, props.chat.id);
  closeContextMenu();
};

const markAsUnread = () => {
  emit('markAsUnread', props.chat.id);
  closeContextMenu();
};

const markAsRead = () => {
  emit('markAsRead', props.chat.id);
  closeContextMenu();
};

const assignPriority = priority => {
  emit('assignPriority', priority, props.chat.id);
  closeContextMenu();
};

const deleteConversation = () => {
  emit('deleteConversation', props.chat.id);
  closeContextMenu();
};
</script>

<template>
  <div
    class="trama-lista-linha relative flex items-center w-full max-w-full cursor-pointer conversation group"
    :class="{
      'active animate-card-select trama-lista-linha--ativa': isActiveChat,
      'trama-lista-linha--selecionada': selected,
      'trama-lista-linha--nao-lida': hasUnread,
      'trama-lista-linha--compacta': compact,
      'ltr:pl-3.5 rtl:pr-3.5': !hideThumbnail,
      'ltr:pl-2 rtl:pr-2': hideThumbnail,
    }"
    @click="onCardClick"
    @contextmenu="openContextMenu($event)"
  >
    <div
      v-if="!hideThumbnail"
      class="relative flex-shrink-0"
      @mouseenter="onThumbnailHover"
      @mouseleave="onThumbnailLeave"
    >
      <Avatar
        :name="currentContact.name"
        :src="currentContact.thumbnail"
        :size="48"
        solido
        :status="currentContact.availability_status"
        hide-offline-status
        rounded-full
      >
        <template #overlay="{ size }">
          <label
            v-if="hovered || selected"
            class="flex items-center justify-center rounded-full cursor-pointer absolute inset-0 z-10 backdrop-blur-[2px]"
            :style="{ width: `${size}px`, height: `${size}px` }"
            @click.stop
          >
            <input
              :value="selected"
              :checked="selected"
              class="!m-0 cursor-pointer"
              type="checkbox"
              @change="onSelectConversation($event.target.checked)"
            />
          </label>
        </template>
      </Avatar>
    </div>
    <div
      class="trama-lista-corpo flex flex-col justify-center flex-1 min-w-0 self-stretch py-3 ltr:pr-4 rtl:pl-4"
      :class="{ 'ltr:ml-3.5 rtl:mr-3.5': !hideThumbnail }"
    >
      <InboxName
        v-if="showCompactInboxName"
        :inbox="inbox"
        class="min-w-0 mb-0.5"
      />
      <div class="flex items-center min-w-0 gap-1.5">
        <h4
          class="conversation--user trama-lista-nome flex-1 min-w-0 my-0 capitalize text-ellipsis overflow-hidden whitespace-nowrap"
          :class="hasUnread ? 'font-semibold' : 'font-normal'"
        >
          {{ currentContact.name }}
        </h4>
        <CardPriorityIcon
          :priority="chat.priority"
          class="flex-shrink-0 !size-3.5"
        />
        <span class="trama-lista-hora flex-shrink-0">
          <TimeAgo
            :last-activity-timestamp="chat.timestamp"
            :created-at-timestamp="chat.created_at"
            :conversation-id="chat.id"
            :show-created-at="false"
            relogio
          />
        </span>
      </div>
      <div class="flex items-center min-w-0 gap-1.5 mt-0.5">
        <VoiceCallStatus
          v-if="voiceCallData.status"
          key="voice-status-row"
          :status="voiceCallData.status"
          :direction="voiceCallData.direction"
          message-preview-class="trama-lista-previa !m-0"
        />
        <MessagePreview
          v-else-if="lastMessageInChat"
          key="message-preview"
          :message="lastMessageInChat"
          class="trama-lista-previa flex-1 min-w-0 my-0"
        />
        <p
          v-else
          key="no-messages"
          class="trama-lista-previa flex-1 min-w-0 my-0 overflow-hidden text-ellipsis whitespace-nowrap"
        >
          <fluent-icon
            size="16"
            class="-mt-0.5 align-middle inline-block"
            icon="info"
          />
          <span class="mx-0.5">
            {{ $t(`CHAT_LIST.NO_MESSAGES`) }}
          </span>
        </p>
        <span v-if="hasUnread" class="trama-lista-contador flex-shrink-0">
          {{ unreadCount > 99 ? '99+' : unreadCount }}
        </span>
      </div>
      <CardLabels
        v-if="showLabelsSection"
        :conversation-labels="chat.labels"
        class="trama-lista-etiquetas mt-1 mb-0"
      >
        <template v-if="hasSlaPolicyId" #before>
          <SLACardLabel :chat="chat" class="ltr:mr-1 rtl:ml-1" />
        </template>
      </CardLabels>
    </div>
    <ContextMenu
      v-if="showContextMenu"
      :x="contextMenu.x"
      :y="contextMenu.y"
      @close="closeContextMenu"
    >
      <ConversationContextMenu
        :status="chat.status"
        :inbox-id="inbox.id"
        :priority="chat.priority"
        :chat-id="chat.id"
        :has-unread-messages="hasUnread"
        :conversation-labels="chat.labels"
        :conversation-url="conversationPath"
        :allowed-options="allowedContextMenuOptions"
        :phone-number="chat.meta?.sender?.phone_number || ''"
        @update-conversation="onUpdateConversation"
        @assign-agent="onAssignAgent"
        @assign-label="onAssignLabel"
        @remove-label="onRemoveLabel"
        @assign-team="onAssignTeam"
        @mark-as-unread="markAsUnread"
        @mark-as-read="markAsRead"
        @assign-priority="assignPriority"
        @delete-conversation="deleteConversation"
        @close="closeContextMenu"
      />
    </ContextMenu>
  </div>
</template>

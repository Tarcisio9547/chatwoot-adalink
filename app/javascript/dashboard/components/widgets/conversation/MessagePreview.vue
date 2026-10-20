<script>
import { MESSAGE_TYPE } from 'widget/helpers/constants';
import { useMessageFormatter } from 'shared/composables/useMessageFormatter';
import { ATTACHMENT_ICONS } from 'shared/constants/messages';
import { MESSAGE_STATUS } from 'dashboard/components-next/message/constants';
import Icon from 'dashboard/components-next/icon/Icon.vue';

export default {
  name: 'MessagePreview',
  components: { Icon },
  props: {
    message: {
      type: Object,
      required: true,
    },
    showMessageType: {
      type: Boolean,
      default: true,
    },
    defaultEmptyMessage: {
      type: String,
      default: '',
    },
  },
  setup() {
    const { getPlainText } = useMessageFormatter();
    return {
      getPlainText,
    };
  },
  computed: {
    messageByAgent() {
      const { message_type: messageType } = this.message;
      return messageType === MESSAGE_TYPE.OUTGOING;
    },
    isMessageAnActivity() {
      const { message_type: messageType } = this.message;
      return messageType === MESSAGE_TYPE.ACTIVITY;
    },
    isMessagePrivate() {
      const { private: isPrivate } = this.message;
      return isPrivate;
    },
    parsedLastMessage() {
      const { content_attributes: contentAttributes } = this.message;
      const { email: { subject } = {} } = contentAttributes || {};
      return this.getPlainText(subject || this.message.content);
    },
    lastMessageFileType() {
      const [{ file_type: fileType } = {}] = this.message.attachments;
      return fileType;
    },
    attachmentIcon() {
      return ATTACHMENT_ICONS[this.lastMessageFileType];
    },
    attachmentMessageContent() {
      return `CHAT_LIST.ATTACHMENTS.${this.lastMessageFileType}.CONTENT`;
    },
    // Trama: na lista, a última mensagem enviada por nós mostra ✓ (enviada),
    // ✓✓ (entregue) ou ✓✓ azul (lida), como no WhatsApp. Sem status conhecido
    // (ex.: e-mail, falha), fica a seta de resposta de antes.
    deliveryStatusIcon() {
      const icons = {
        [MESSAGE_STATUS.SENT]: 'i-lucide-check',
        [MESSAGE_STATUS.DELIVERED]: 'i-lucide-check-check',
        [MESSAGE_STATUS.READ]: 'i-lucide-check-check',
      };
      return icons[this.message.status] || '';
    },
    deliveryStatusClass() {
      return this.message.status === MESSAGE_STATUS.READ
        ? 'trama-lido'
        : 'text-n-slate-11';
    },
    isMessageSticker() {
      return this.message && this.message.content_type === 'sticker';
    },
  },
};
</script>

<template>
  <div class="overflow-hidden text-ellipsis whitespace-nowrap">
    <template v-if="showMessageType">
      <fluent-icon
        v-if="isMessagePrivate"
        size="16"
        class="-mt-0.5 align-middle text-n-slate-11 inline-block"
        icon="lock-closed"
      />
      <Icon
        v-else-if="messageByAgent && deliveryStatusIcon"
        :icon="deliveryStatusIcon"
        class="inline-block -mt-0.5 align-middle size-4 ltr:mr-0.5 rtl:ml-0.5"
        :class="deliveryStatusClass"
      />
      <fluent-icon
        v-else-if="messageByAgent"
        size="16"
        class="-mt-0.5 align-middle text-n-slate-11 inline-block"
        icon="arrow-reply"
      />
      <fluent-icon
        v-else-if="isMessageAnActivity"
        size="16"
        class="-mt-0.5 align-middle text-n-slate-11 inline-block"
        icon="info"
      />
    </template>
    <span v-if="message.content && isMessageSticker">
      <fluent-icon
        size="16"
        class="-mt-0.5 align-middle inline-block text-n-slate-11"
        icon="image"
      />
      {{ $t('CHAT_LIST.ATTACHMENTS.image.CONTENT') }}
    </span>
    <span v-else-if="message.content">
      {{ parsedLastMessage }}
    </span>
    <span v-else-if="message.attachments">
      <fluent-icon
        v-if="attachmentIcon && showMessageType"
        size="16"
        class="-mt-0.5 align-middle inline-block text-n-slate-11"
        :icon="attachmentIcon"
      />
      {{ $t(`${attachmentMessageContent}`) }}
    </span>
    <span v-else>
      {{ defaultEmptyMessage || $t('CHAT_LIST.NO_CONTENT') }}
    </span>
  </div>
</template>

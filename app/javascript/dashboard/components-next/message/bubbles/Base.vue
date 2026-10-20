<script setup>
import { computed } from 'vue';

import MessageMeta from '../MessageMeta.vue';

import { emitter } from 'shared/helpers/mitt';
import { useMessageContext } from '../provider.js';
import { useI18n } from 'vue-i18n';

import MessageFormatter from 'shared/helpers/MessageFormatter.js';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import { MESSAGE_VARIANTS, ORIENTATION } from '../constants';

const props = defineProps({
  hideMeta: { type: Boolean, default: false },
});

const { variant, orientation, inReplyTo, shouldGroupWithNext, sender } =
  useMessageContext();
const { t } = useI18n();

const varaintBaseMap = {
  // Trama: cores de WhatsApp (assets/scss/_trama-whatsapp.scss)
  [MESSAGE_VARIANTS.AGENT]: 'trama-bolha-enviada',
  [MESSAGE_VARIANTS.PRIVATE]:
    'trama-bolha-nota [&_.prosemirror-mention-node]:font-semibold',
  [MESSAGE_VARIANTS.USER]: 'trama-bolha-recebida',
  [MESSAGE_VARIANTS.ACTIVITY]: 'trama-sistema text-sm',
  [MESSAGE_VARIANTS.BOT]: 'trama-bolha-enviada',
  [MESSAGE_VARIANTS.TEMPLATE]: 'trama-bolha-enviada',
  [MESSAGE_VARIANTS.ERROR]: 'bg-n-ruby-4 text-n-ruby-12',
  [MESSAGE_VARIANTS.EMAIL]: 'w-full',
  [MESSAGE_VARIANTS.UNSUPPORTED]:
    'bg-n-solid-amber/70 border border-dashed border-n-amber-12 text-n-amber-12',
};

const orientationMap = {
  [ORIENTATION.LEFT]: 'left-bubble',
  [ORIENTATION.RIGHT]: 'right-bubble',
  [ORIENTATION.CENTER]: 'rounded-md',
};

const flexOrientationClass = computed(() => {
  const map = {
    [ORIENTATION.LEFT]: 'justify-start',
    [ORIENTATION.RIGHT]: 'justify-end',
    [ORIENTATION.CENTER]: 'justify-center',
  };

  return map[orientation.value];
});

const messageClass = computed(() => {
  const classToApply = [varaintBaseMap[variant.value]];

  if (variant.value !== MESSAGE_VARIANTS.ACTIVITY) {
    classToApply.push(orientationMap[orientation.value]);
  } else {
    classToApply.push('rounded-lg');
  }

  return classToApply;
});

const scrollToMessage = () => {
  emitter.emit(BUS_EVENTS.SCROLL_TO_MESSAGE, {
    messageId: inReplyTo.value.id,
  });
};

// Trama: nome de quem enviou dentro do balão (no lugar da bolinha do atendente).
// O CSS esconde nas mensagens seguidas do mesmo remetente.
const nomeAutor = computed(() => {
  if (orientation.value !== ORIENTATION.RIGHT) return '';
  if (variant.value === MESSAGE_VARIANTS.ACTIVITY) return '';
  return sender?.value?.available_name || sender?.value?.name || '';
});

const shouldShowMeta = computed(
  () =>
    !props.hideMeta &&
    !shouldGroupWithNext.value &&
    variant.value !== MESSAGE_VARIANTS.ACTIVITY
);

const replyToPreview = computed(() => {
  if (!inReplyTo) return '';

  const { content, attachments } = inReplyTo.value;

  if (content) return new MessageFormatter(content).formattedMessage;
  if (attachments?.length) {
    const firstAttachment = attachments[0];
    const fileType = firstAttachment.fileType ?? firstAttachment.file_type;

    return t(`CHAT_LIST.ATTACHMENTS.${fileType}.CONTENT`);
  }

  return t('CONVERSATION.REPLY_MESSAGE_NOT_FOUND');
});
</script>

<template>
  <div
    class="text-sm"
    :class="[
      messageClass,
      {
        'max-w-lg': variant !== MESSAGE_VARIANTS.EMAIL,
      },
    ]"
  >
    <div v-if="nomeAutor" class="trama-autor">{{ nomeAutor }}</div>
    <div
      v-if="inReplyTo"
      class="trama-citacao cursor-pointer"
      @click="scrollToMessage"
    >
      <div
        v-dompurify-html="replyToPreview"
        class="prose prose-bubble line-clamp-2"
      />
    </div>
    <slot />
    <MessageMeta
      v-if="shouldShowMeta"
      :class="[
        variant === MESSAGE_VARIANTS.EMAIL
          ? `${flexOrientationClass} px-3 pb-3`
          : 'justify-end',
        variant === MESSAGE_VARIANTS.PRIVATE
          ? 'text-n-amber-12/50'
          : 'text-n-slate-11',
      ]"
      class="trama-meta-linha"
    />
  </div>
</template>

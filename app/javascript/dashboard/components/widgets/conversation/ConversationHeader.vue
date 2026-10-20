<script setup>
import { computed, ref } from 'vue';
import { useRoute } from 'vue-router';
import { useStore } from 'vuex';
import { useElementSize } from '@vueuse/core';
import BackButton from '../BackButton.vue';
import MoreActions from './MoreActions.vue';
import Avatar from 'next/avatar/Avatar.vue';
import SLACardLabel from './components/SLACardLabel.vue';
import wootConstants from 'dashboard/constants/globals';
import { conversationListPageURL } from 'dashboard/helper/URLHelper';
import { snoozedReopenTime } from 'dashboard/helper/snoozeHelpers';
import { useInbox } from 'dashboard/composables/useInbox';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { useTramaAtribuirAMim } from 'dashboard/composables/useTramaAtribuirAMim';
import { useI18n } from 'vue-i18n';

const props = defineProps({
  chat: {
    type: Object,
    default: () => ({}),
  },
  showBackButton: {
    type: Boolean,
    default: false,
  },
});

const { t } = useI18n();
const store = useStore();
const route = useRoute();
const conversationHeader = ref(null);
const { width } = useElementSize(conversationHeader);
const { isAWebWidgetInbox } = useInbox();

const currentChat = computed(() => store.getters.getSelectedChat);
const accountId = computed(() => store.getters.getCurrentAccountId);

const chatMetadata = computed(() => props.chat.meta);

const backButtonUrl = computed(() => {
  const {
    params: { inbox_id: inboxId, label, teamId, id: customViewId },
    name,
  } = route;

  const conversationTypeMap = {
    conversation_through_mentions: 'mention',
    conversation_through_unattended: 'unattended',
  };
  return conversationListPageURL({
    accountId: accountId.value,
    inboxId,
    label,
    teamId,
    conversationType: conversationTypeMap[name],
    customViewId,
  });
});

const isHMACVerified = computed(() => {
  if (!isAWebWidgetInbox.value) {
    return true;
  }
  return chatMetadata.value.hmac_verified;
});

const currentContact = computed(() =>
  store.getters['contacts/getContact'](props.chat.meta.sender.id)
);

const isSnoozed = computed(
  () => currentChat.value.status === wootConstants.STATUS_TYPE.SNOOZED
);

const snoozedDisplayText = computed(() => {
  const { snoozed_until: snoozedUntil } = currentChat.value;
  if (snoozedUntil) {
    return `${t('CONVERSATION.HEADER.SNOOZED_UNTIL')} ${snoozedReopenTime(snoozedUntil)}`;
  }
  return t('CONVERSATION.HEADER.SNOOZED_UNTIL_NEXT_REPLY');
});

const inbox = computed(() => {
  const { inbox_id: inboxId } = props.chat;
  return store.getters['inboxes/getInbox'](inboxId);
});

const hasSlaPolicyId = computed(() => props.chat?.sla_policy_id);

// Trama: cabeçalho com cara de WhatsApp (protótipo aprovado em 19/10).
// Clicar no nome/avatar ou no (i) abre e fecha "Dados do contato", usando a
// mesma preferência do Chatwoot (is_contact_sidebar_open).
const { uiSettings, updateUISettings } = useUISettings();
const painelContatoAberto = computed(
  () => !!uiSettings.value?.is_contact_sidebar_open
);
const alternarPainelContato = () => {
  updateUISettings({
    is_contact_sidebar_open: !painelContatoAberto.value,
    is_copilot_panel_open: false,
  });
};

const { responsavel, souResponsavel, atribuirAMim } = useTramaAtribuirAMim();

const conversaAtiva = computed(() =>
  [wootConstants.STATUS_TYPE.OPEN, wootConstants.STATUS_TYPE.PENDING].includes(
    currentChat.value.status
  )
);

// "Atribuir a mim" só aparece quando a conversa está sem responsável.
const mostrarAtribuirAMim = computed(
  () => conversaAtiva.value && !responsavel.value
);

const textoResponsavel = computed(() => {
  if (responsavel.value) {
    return souResponsavel.value
      ? t('TRAMA_CONTATO.COM_VOCE')
      : t('TRAMA_CONTATO.COM_RESPONSAVEL', {
          nome: responsavel.value.available_name || responsavel.value.name,
        });
  }
  return '';
});

const cabecalhoCompacto = computed(() => width.value > 0 && width.value < 560);

const SEPARADOR = ' · ';

const onAtribuirAMim = () => {
  atribuirAMim(t('CONVERSATION.CHANGE_AGENT'));
};
</script>

<template>
  <div
    ref="conversationHeader"
    class="trama-conv-h flex items-center flex-1 w-full min-w-0 gap-3 ltr:pl-4 ltr:pr-2.5 rtl:pr-4 rtl:pl-2.5"
  >
    <BackButton v-if="showBackButton" :back-url="backButtonUrl" />
    <button
      type="button"
      class="flex items-center flex-1 min-w-0 gap-3 p-0 text-start bg-transparent border-0 cursor-pointer"
      :title="t('TRAMA_CONTATO.TITULO')"
      data-testid="trama-conv-who"
      @click="alternarPainelContato"
    >
      <Avatar
        :name="currentContact.name"
        :src="currentContact.thumbnail"
        :size="40"
        solido
        :status="currentContact.availability_status"
        hide-offline-status
        rounded-full
      />
      <span class="flex flex-col min-w-0 overflow-hidden">
        <span class="flex items-center max-w-full min-w-0 gap-1">
          <span class="truncate trama-conv-who-nome">
            {{ currentContact.name }}
          </span>
          <fluent-icon
            v-if="!isHMACVerified"
            v-tooltip="$t('CONVERSATION.UNVERIFIED_SESSION')"
            size="14"
            class="text-n-amber-10 my-0 mx-0 min-w-[14px] flex-shrink-0"
            icon="warning"
          />
        </span>
        <span class="truncate trama-conv-who-sub">
          <span
            v-if="mostrarAtribuirAMim"
            class="trama-conv-sem-resp"
            data-testid="trama-sem-responsavel"
          >
            {{ t('TRAMA_CONTATO.SEM_RESPONSAVEL') }}
          </span>
          <span v-else-if="textoResponsavel">{{ textoResponsavel }}</span>
          <template v-if="inbox && inbox.name">
            <span v-if="mostrarAtribuirAMim || textoResponsavel">
              {{ SEPARADOR }}
            </span>
            <span>{{ inbox.name }}</span>
          </template>
          <span v-if="isSnoozed" class="font-medium text-n-amber-10">
            {{ SEPARADOR }}{{ snoozedDisplayText }}
          </span>
        </span>
      </span>
    </button>
    <div class="flex items-center flex-shrink-0 gap-2">
      <SLACardLabel
        v-if="hasSlaPolicyId"
        :chat="chat"
        show-extended-info
        :parent-width="width"
        class="hidden md:flex"
      />
      <button
        v-if="mostrarAtribuirAMim"
        type="button"
        class="trama-hbtn trama-hbtn--verde"
        :title="t('TRAMA_CONTATO.ATRIBUIR_A_MIM')"
        data-testid="trama-atribuir-a-mim"
        @click="onAtribuirAMim"
      >
        <span class="i-lucide-user size-4" aria-hidden="true" />
        <span v-if="!cabecalhoCompacto">
          {{ t('TRAMA_CONTATO.ATRIBUIR_A_MIM') }}
        </span>
      </button>
      <MoreActions :conversation-id="currentChat.id">
        <template #antesDoMenu>
          <button
            type="button"
            class="trama-ib"
            :class="{ 'is-on': painelContatoAberto }"
            :aria-label="t('TRAMA_CONTATO.TITULO')"
            :title="t('TRAMA_CONTATO.TITULO')"
            :aria-pressed="painelContatoAberto"
            @click="alternarPainelContato"
          >
            <span class="i-lucide-info size-5" aria-hidden="true" />
          </button>
        </template>
      </MoreActions>
    </div>
  </div>
</template>

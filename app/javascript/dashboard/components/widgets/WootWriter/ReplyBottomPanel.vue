<script>
import { ref } from 'vue';
import { vOnClickOutside } from '@vueuse/components';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { useKeyboardEvents } from 'dashboard/composables/useKeyboardEvents';
import FileUpload from 'vue-upload-component';
import * as ActiveStorage from 'activestorage';
import inboxMixin from 'shared/mixins/inboxMixin';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { getAllowedFileTypesByChannel } from '@chatwoot/utils';
import { ALLOWED_FILE_TYPES } from 'shared/constants/messages';
import VideoCallButton from '../VideoCallButton.vue';
import { INBOX_TYPES } from 'dashboard/helper/inbox';
import { mapGetters } from 'vuex';
import NextButton from 'dashboard/components-next/button/Button.vue';

export default {
  name: 'ReplyBottomPanel',
  components: { NextButton, FileUpload, VideoCallButton },
  directives: {
    OnClickOutside: vOnClickOutside,
  },
  mixins: [inboxMixin],
  props: {
    isNote: {
      type: Boolean,
      default: false,
    },
    onSend: {
      type: Function,
      default: () => {},
    },
    sendButtonText: {
      type: String,
      default: '',
    },
    recordingAudioDurationText: {
      type: String,
      default: '00:00',
    },
    // inbox prop is used in /mixins/inboxMixin,
    // remove this props when refactoring to composable if not needed
    // eslint-disable-next-line vue/no-unused-properties
    inbox: {
      type: Object,
      default: () => ({}),
    },
    showFileUpload: {
      type: Boolean,
      default: false,
    },
    showAudioRecorder: {
      type: Boolean,
      default: false,
    },
    onFileUpload: {
      type: Function,
      default: () => {},
    },
    toggleEmojiPicker: {
      type: Function,
      default: () => {},
    },
    toggleAudioRecorder: {
      type: Function,
      default: () => {},
    },
    toggleAudioRecorderPlayPause: {
      type: Function,
      default: () => {},
    },
    isRecordingAudio: {
      type: Boolean,
      default: false,
    },
    recordingAudioState: {
      type: String,
      default: '',
    },
    isSendDisabled: {
      type: Boolean,
      default: false,
    },
    isOnPrivateNote: {
      type: Boolean,
      default: false,
    },
    enableMultipleFileUpload: {
      type: Boolean,
      default: true,
    },
    enableWhatsAppTemplates: {
      type: Boolean,
      default: false,
    },
    enableContentTemplates: {
      type: Boolean,
      default: false,
    },
    conversationId: {
      type: Number,
      required: true,
    },
    // eslint-disable-next-line vue/no-unused-properties
    message: {
      type: String,
      default: '',
    },
    newConversationModalActive: {
      type: Boolean,
      default: false,
    },
    portalSlug: {
      type: String,
      required: true,
    },
    conversationType: {
      type: String,
      default: '',
    },
    showQuotedReplyToggle: {
      type: Boolean,
      default: false,
    },
    quotedReplyEnabled: {
      type: Boolean,
      default: false,
    },
    isEditorDisabled: {
      type: Boolean,
      default: false,
    },
    // Trama (barra estilo WhatsApp): ações que saíram do painel de cima
    // e agora ficam no menu "+".
    showCopilotAction: {
      type: Boolean,
      default: false,
    },
    showPopoutAction: {
      type: Boolean,
      default: false,
    },
  },
  emits: [
    'replaceText',
    'toggleInsertArticle',
    'selectWhatsappTemplate',
    'selectContentTemplate',
    'toggleQuotedReply',
    'togglePrivateNote',
    'openCopilot',
    'togglePopout',
  ],
  setup(props) {
    const { setSignatureFlagForInbox, fetchSignatureFlagFromUISettings } =
      useUISettings();

    const uploadRef = ref(false);

    const keyboardEvents = {
      '$mod+Alt+KeyA': {
        action: () => {
          // Skip if editor is disabled (e.g., WhatsApp 24-hour window expired)
          if (props.isEditorDisabled) return;

          // TODO: This is really hacky, we need to replace the file picker component with
          // a custom one, where the logic and the component markup is isolated.
          // Once we have the custom component, we can remove the hacky logic below.

          const uploadTriggerButton = document.querySelector(
            '#conversationAttachment'
          );
          if (uploadTriggerButton) uploadTriggerButton.click();
        },
        allowOnFocusedInput: true,
      },
    };

    useKeyboardEvents(keyboardEvents);

    return {
      setSignatureFlagForInbox,
      fetchSignatureFlagFromUISettings,
      uploadRef,
    };
  },
  data() {
    return {
      ALLOWED_FILE_TYPES,
      showActionsMenu: false,
      // Filtro temporário do seletor de arquivos ("Fotos e vídeos").
      uploadAcceptOverride: '',
    };
  },
  computed: {
    ...mapGetters({
      accountId: 'getCurrentAccountId',
      isFeatureEnabledonAccount: 'accounts/isFeatureEnabledonAccount',
      uiFlags: 'integrations/getUIFlags',
    }),
    wrapClass() {
      return {
        'is-note-mode': this.isNote,
      };
    },
    showAttachButton() {
      if (this.isEditorDisabled) return false;
      return this.showFileUpload || this.isNote;
    },
    showAudioRecorderButton() {
      if (this.isEditorDisabled) return false;
      if (this.isALineChannel || this.isATiktokChannel) {
        return false;
      }
      // Disable audio recorder for safari browser as recording is not supported
      // const isSafari = /^((?!chrome|android|crios|fxios).)*safari/i.test(
      //   navigator.userAgent
      // );

      return (
        this.isFeatureEnabledonAccount(
          this.accountId,
          FEATURE_FLAGS.VOICE_RECORDER
        ) && this.showAudioRecorder
        // !isSafari
      );
    },
    showAudioPlayStopButton() {
      if (this.isEditorDisabled) return false;
      return this.showAudioRecorder && this.isRecordingAudio;
    },
    isInstagramDM() {
      return this.conversationType === 'instagram_direct_message';
    },
    allowedFileTypes() {
      // Use default file types for private notes
      if (this.isOnPrivateNote) {
        return this.ALLOWED_FILE_TYPES;
      }

      let channelType = this.channelType || this.inbox?.channel_type;

      if (this.isAnInstagramChannel || this.isInstagramDM) {
        channelType = INBOX_TYPES.INSTAGRAM;
      }

      return getAllowedFileTypesByChannel({
        channelType,
        medium: this.inbox?.medium,
      });
    },
    enableDragAndDrop() {
      return !this.newConversationModalActive;
    },
    audioRecorderPlayStopIcon() {
      switch (this.recordingAudioState) {
        // playing paused recording stopped inactive destroyed
        case 'playing':
          return 'i-ph-pause';
        case 'paused':
          return 'i-ph-play';
        case 'stopped':
          return 'i-ph-play';
        default:
          return 'i-ph-stop';
      }
    },
    showMessageSignatureButton() {
      if (this.isEditorDisabled) return false;
      return !this.isOnPrivateNote;
    },
    sendWithSignature() {
      // channelType is sourced from inboxMixin
      return this.fetchSignatureFlagFromUISettings(this.channelType);
    },
    signatureToggleTooltip() {
      return this.sendWithSignature
        ? this.$t('CONVERSATION.FOOTER.DISABLE_SIGN_TOOLTIP')
        : this.$t('CONVERSATION.FOOTER.ENABLE_SIGN_TOOLTIP');
    },
    enableInsertArticleInReply() {
      return this.portalSlug;
    },
    isFetchingAppIntegrations() {
      return this.uiFlags.isFetching;
    },
    hasTypedContent() {
      return !!(this.message && this.message.trim());
    },
    // Microfone no lugar do "enviar" quando não há nada para mandar (WhatsApp).
    showMicInSendSlot() {
      return (
        this.showAudioRecorderButton &&
        !this.isRecordingAudio &&
        this.isSendDisabled &&
        !this.hasTypedContent
      );
    },
    mediaFileTypes() {
      return this.allowedFileTypes
        .split(',')
        .map(type => type.trim())
        .filter(type => type.startsWith('image/') || type.startsWith('video/'))
        .join(', ');
    },
    uploadAccept() {
      return this.uploadAcceptOverride || this.allowedFileTypes;
    },
    showPrivateNoteToggle() {
      return !this.isNote && !this.isRecordingAudio;
    },
    hasMainMenuItems() {
      return (
        this.showAttachButton ||
        (this.showAudioRecorderButton && !this.isRecordingAudio) ||
        this.enableWhatsAppTemplates ||
        this.enableContentTemplates
      );
    },
    hasExtraMenuItems() {
      return (
        this.showMessageSignatureButton ||
        this.showQuotedReplyToggle ||
        !!this.enableInsertArticleInReply ||
        this.showCopilotAction ||
        this.showPopoutAction
      );
    },
    showActionsMenuButton() {
      if (this.isRecordingAudio) return false;
      return this.hasMainMenuItems || this.hasExtraMenuItems;
    },
    sendIcon() {
      return this.isNote ? 'i-ph-check-bold' : 'i-ph-paper-plane-right-fill';
    },
    quotedReplyToggleTooltip() {
      return this.quotedReplyEnabled
        ? this.$t('CONVERSATION.REPLYBOX.QUOTED_REPLY.DISABLE_TOOLTIP')
        : this.$t('CONVERSATION.REPLYBOX.QUOTED_REPLY.ENABLE_TOOLTIP');
    },
  },
  mounted() {
    ActiveStorage.start();
  },
  methods: {
    toggleMessageSignature() {
      this.setSignatureFlagForInbox(this.channelType, !this.sendWithSignature);
    },
    replaceText(text) {
      this.$emit('replaceText', text);
    },
    toggleInsertArticle() {
      this.$emit('toggleInsertArticle');
    },
    toggleActionsMenu() {
      this.showActionsMenu = !this.showActionsMenu;
    },
    closeActionsMenu() {
      this.showActionsMenu = false;
    },
    runMenuAction(action) {
      this.closeActionsMenu();
      action();
    },
    // Abre o mesmo seletor de arquivos de antes (input #conversationAttachment);
    // "Fotos e vídeos" só filtra a lista de tipos do diálogo.
    openFilePicker(onlyMedia = false) {
      this.closeActionsMenu();
      this.uploadAcceptOverride = onlyMedia ? this.mediaFileTypes : '';
      this.$nextTick(() => {
        const input = document.querySelector('#conversationAttachment');
        if (input) input.click();
        this.$nextTick(() => {
          this.uploadAcceptOverride = '';
        });
      });
    },
  },
};
</script>

<template>
  <div class="trama-wa-acoes" :class="wrapClass">
    <!-- Trama: o painel de baixo virou a barra estilo WhatsApp. A raiz usa
         display: contents para os botões ficarem na mesma linha do campo de
         texto (ver "barra" em _trama-whatsapp.scss). -->
    <div class="left-wrap trama-wa-esquerda">
      <div v-if="showActionsMenuButton" class="relative">
        <button
          v-tooltip.top-start="$t('CONVERSATION.TRAMA_BARRA.MAIS_ACOES')"
          type="button"
          class="trama-wa-icone-btn"
          :class="{ 'is-active': showActionsMenu }"
          :aria-label="$t('CONVERSATION.TRAMA_BARRA.MAIS_ACOES')"
          :aria-expanded="showActionsMenu"
          aria-haspopup="menu"
          data-test-id="trama-barra-mais"
          @click="toggleActionsMenu"
        >
          <span class="i-ph-plus size-6" />
        </button>
        <div
          v-if="showActionsMenu"
          v-on-click-outside="closeActionsMenu"
          class="trama-wa-pop"
          role="menu"
          @keydown.esc="closeActionsMenu"
        >
          <button
            v-if="showAttachButton"
            type="button"
            role="menuitem"
            class="trama-wa-pop-item"
            data-test-id="trama-barra-fotos"
            @click="openFilePicker(true)"
          >
            <span class="trama-wa-pop-circulo bg-[#007bfc]">
              <span class="i-ph-image size-4" />
            </span>
            {{ $t('CONVERSATION.TRAMA_BARRA.FOTOS_VIDEOS') }}
          </button>
          <button
            v-if="showAttachButton"
            type="button"
            role="menuitem"
            class="trama-wa-pop-item"
            data-test-id="trama-barra-documento"
            @click="openFilePicker(false)"
          >
            <span class="trama-wa-pop-circulo bg-[#1e3a5f]">
              <span class="i-ph-file-text size-4" />
            </span>
            {{ $t('CONVERSATION.TRAMA_BARRA.DOCUMENTO') }}
          </button>
          <button
            v-if="showAudioRecorderButton && !isRecordingAudio"
            type="button"
            role="menuitem"
            class="trama-wa-pop-item"
            data-test-id="trama-barra-gravar"
            @click="runMenuAction(toggleAudioRecorder)"
          >
            <span class="trama-wa-pop-circulo bg-[#e5533d]">
              <span class="i-ph-microphone size-4" />
            </span>
            {{ $t('CONVERSATION.TRAMA_BARRA.GRAVAR_AUDIO') }}
          </button>
          <button
            v-if="enableWhatsAppTemplates"
            type="button"
            role="menuitem"
            class="trama-wa-pop-item"
            data-test-id="trama-barra-modelo"
            @click="runMenuAction(() => $emit('selectWhatsappTemplate'))"
          >
            <span class="trama-wa-pop-circulo bg-[#00a884]">
              <span class="i-ph-whatsapp-logo size-4" />
            </span>
            {{ $t('CONVERSATION.TRAMA_BARRA.MODELO_WHATSAPP') }}
          </button>
          <button
            v-if="enableContentTemplates"
            type="button"
            role="menuitem"
            class="trama-wa-pop-item"
            data-test-id="trama-barra-modelo-conteudo"
            @click="runMenuAction(() => $emit('selectContentTemplate'))"
          >
            <span class="trama-wa-pop-circulo bg-[#00a884]">
              <span class="i-ph-whatsapp-logo size-4" />
            </span>
            {{ $t('CONVERSATION.TRAMA_BARRA.MODELOS_CONTEUDO') }}
          </button>
          <div
            v-if="hasMainMenuItems && hasExtraMenuItems"
            class="trama-wa-pop-divisor"
          />
          <button
            v-if="showMessageSignatureButton"
            type="button"
            role="menuitem"
            class="trama-wa-pop-item is-secundario"
            data-test-id="trama-barra-assinatura"
            @click="runMenuAction(toggleMessageSignature)"
          >
            <span class="i-ph-signature size-5" />
            {{ signatureToggleTooltip }}
          </button>
          <button
            v-if="showQuotedReplyToggle"
            type="button"
            role="menuitem"
            class="trama-wa-pop-item is-secundario"
            :aria-pressed="quotedReplyEnabled"
            @click="runMenuAction(() => $emit('toggleQuotedReply'))"
          >
            <span class="i-ph-quotes size-5" />
            {{ quotedReplyToggleTooltip }}
          </button>
          <button
            v-if="enableInsertArticleInReply"
            type="button"
            role="menuitem"
            class="trama-wa-pop-item is-secundario"
            @click="runMenuAction(toggleInsertArticle)"
          >
            <span class="i-ph-article-ny-times size-5" />
            {{ $t('HELP_CENTER.ARTICLE_SEARCH.OPEN_ARTICLE_SEARCH') }}
          </button>
          <button
            v-if="showCopilotAction"
            type="button"
            role="menuitem"
            class="trama-wa-pop-item is-secundario"
            data-test-id="trama-barra-ia"
            @click="runMenuAction(() => $emit('openCopilot'))"
          >
            <span class="i-ph-sparkle-fill size-5 text-n-blue-9" />
            {{ $t('CONVERSATION.TRAMA_BARRA.ASSISTENTE_IA') }}
          </button>
          <button
            v-if="showPopoutAction"
            type="button"
            role="menuitem"
            class="trama-wa-pop-item is-secundario"
            data-test-id="trama-barra-expandir"
            @click="runMenuAction(() => $emit('togglePopout'))"
          >
            <span class="i-lucide-maximize-2 size-5" />
            {{ $t('CONVERSATION.TRAMA_BARRA.EXPANDIR') }}
          </button>
        </div>
      </div>
      <button
        v-if="!isRecordingAudio"
        v-tooltip.top-start="$t('CONVERSATION.REPLYBOX.TIP_EMOJI_ICON')"
        type="button"
        class="trama-wa-icone-btn"
        :disabled="isEditorDisabled"
        :aria-label="$t('CONVERSATION.REPLYBOX.TIP_EMOJI_ICON')"
        data-test-id="trama-barra-emoji"
        @click="toggleEmojiPicker"
      >
        <span class="i-ph-smiley size-6" />
      </button>
      <button
        v-if="showPrivateNoteToggle"
        v-tooltip.top-start="$t('CONVERSATION.TRAMA_BARRA.NOTA_ALTERNAR')"
        type="button"
        class="trama-wa-icone-btn"
        :aria-label="$t('CONVERSATION.TRAMA_BARRA.NOTA_ALTERNAR')"
        data-test-id="trama-barra-nota"
        @click="$emit('togglePrivateNote')"
      >
        <span class="i-ph-lock-simple size-6" />
      </button>
      <!-- Mesmo seletor de arquivos de antes (id, tipos aceitos, arrastar e
           soltar). Fica invisível: quem abre é o menu "+" ou Ctrl+Alt+A. -->
      <FileUpload
        v-if="showAttachButton"
        ref="uploadRef"
        class="trama-wa-upload-oculto"
        input-id="conversationAttachment"
        :size="4096 * 4096"
        :accept="uploadAccept"
        :multiple="enableMultipleFileUpload"
        :drop="enableDragAndDrop"
        :drop-directory="false"
        :data="{
          direct_upload_url: '/rails/active_storage/direct_uploads',
          direct_upload: true,
        }"
        @input-file="onFileUpload"
      />
      <button
        v-if="showAudioRecorderButton && isRecordingAudio"
        v-tooltip.top-start="$t('CONVERSATION.TRAMA_BARRA.CANCELAR_AUDIO')"
        type="button"
        class="trama-wa-icone-btn"
        :aria-label="$t('CONVERSATION.TRAMA_BARRA.CANCELAR_AUDIO')"
        data-test-id="trama-barra-cancelar-audio"
        @click="toggleAudioRecorder"
      >
        <span class="i-ph-trash size-6" />
      </button>
      <NextButton
        v-if="showAudioPlayStopButton"
        :icon="audioRecorderPlayStopIcon"
        slate
        faded
        sm
        :label="recordingAudioDurationText"
        @click="toggleAudioRecorderPlayPause"
      />
      <VideoCallButton
        v-if="
          (isAWebWidgetInbox || isAPIInbox) &&
          !isOnPrivateNote &&
          !isEditorDisabled
        "
        :conversation-id="conversationId"
      />
      <transition name="modal-fade">
        <div
          v-show="uploadRef && uploadRef.dropActive"
          class="flex fixed top-0 right-0 bottom-0 left-0 z-20 flex-col gap-2 justify-center items-center w-full h-full text-n-slate-12 bg-modal-backdrop-light dark:bg-modal-backdrop-dark"
        >
          <fluent-icon icon="cloud-backup" size="40" />
          <h4 class="text-2xl break-words text-n-slate-12">
            {{ $t('CONVERSATION.REPLYBOX.DRAG_DROP') }}
          </h4>
        </div>
      </transition>
    </div>
    <div class="right-wrap trama-wa-direita">
      <button
        v-if="showMicInSendSlot"
        v-tooltip.top-end="$t('CONVERSATION.REPLYBOX.TIP_AUDIORECORDER_ICON')"
        type="button"
        class="trama-wa-enviar"
        :aria-label="$t('CONVERSATION.REPLYBOX.TIP_AUDIORECORDER_ICON')"
        data-test-id="trama-barra-microfone"
        @click="toggleAudioRecorder"
      >
        <span class="i-ph-microphone size-6" />
      </button>
      <button
        v-else
        v-tooltip.top-end="sendButtonText"
        type="submit"
        class="trama-wa-enviar"
        :disabled="isSendDisabled"
        :aria-label="sendButtonText"
        data-test-id="trama-barra-enviar"
        @click="onSend"
      >
        <span class="size-6" :class="sendIcon" />
      </button>
    </div>
  </div>
</template>

<style lang="scss" scoped>
// O visual da barra fica em _trama-whatsapp.scss (bloco "barra").
.trama-wa-upload-oculto {
  @apply absolute size-px overflow-hidden opacity-0 pointer-events-none;
}
</style>

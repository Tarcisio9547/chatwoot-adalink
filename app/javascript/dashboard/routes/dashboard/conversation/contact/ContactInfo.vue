<script>
import { mapGetters } from 'vuex';
import { useAlert } from 'dashboard/composables';
import { dynamicTime } from 'shared/helpers/timeHelper';
import { useAdmin } from 'dashboard/composables/useAdmin';
import ContactInfoRow from './ContactInfoRow.vue';
import Avatar from 'next/avatar/Avatar.vue';
import SocialIcons from './SocialIcons.vue';
import EditContact from './EditContact.vue';
import ContactMergeModal from 'dashboard/modules/contact/ContactMergeModal.vue';
import ComposeConversation from 'dashboard/components-next/NewConversation/ComposeConversation.vue';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import { copyTextToClipboard } from 'shared/helpers/clipboard';
import NextButton from 'dashboard/components-next/button/Button.vue';
import VoiceCallButton from 'dashboard/components-next/Contacts/VoiceCallButton.vue';

import {
  isAConversationRoute,
  isAInboxViewRoute,
  getConversationDashboardRoute,
} from '../../../../helper/routeHelpers';
import { emitter } from 'shared/helpers/mitt';

export default {
  components: {
    NextButton,
    ContactInfoRow,
    EditContact,
    Avatar,
    ComposeConversation,
    SocialIcons,
    ContactMergeModal,
    VoiceCallButton,
  },
  props: {
    contact: {
      type: Object,
      default: () => ({}),
    },
    showAvatar: {
      type: Boolean,
      default: true,
    },
  },
  emits: ['panelClose'],
  setup() {
    const { isAdmin } = useAdmin();
    return {
      isAdmin,
    };
  },
  data() {
    return {
      showEditModal: false,
      showDeleteModal: false,
    };
  },
  computed: {
    ...mapGetters({ uiFlags: 'contacts/getUIFlags' }),
    contactProfileLink() {
      return `/app/accounts/${this.$route.params.accountId}/contacts/${this.contact.id}`;
    },
    additionalAttributes() {
      return this.contact.additional_attributes || {};
    },
    location() {
      const {
        country = '',
        city = '',
        country_code: countryCode,
      } = this.additionalAttributes;
      const cityAndCountry = [city, country].filter(item => !!item).join(', ');

      if (!cityAndCountry) {
        return '';
      }
      return this.findCountryFlag(countryCode, cityAndCountry);
    },
    socialProfiles() {
      const {
        social_profiles: socialProfiles,
        screen_name: twitterScreenName,
        social_telegram_user_name: telegramUsername,
      } = this.additionalAttributes;

      const telegram = socialProfiles?.telegram || telegramUsername || '';
      const twitter = socialProfiles?.twitter || twitterScreenName || '';

      return {
        ...(socialProfiles || {}),
        twitter,
        telegram,
      };
    },
    // Delete Modal
    confirmDeleteMessage() {
      return ` ${this.contact.name}?`;
    },
  },
  watch: {
    'contact.id': {
      handler(id) {
        this.$store.dispatch('contacts/fetchContactableInbox', id);
      },
      immediate: true,
    },
  },
  methods: {
    dynamicTime,
    toggleEditModal() {
      this.showEditModal = !this.showEditModal;
    },
    openComposeConversationModal(toggleFn) {
      toggleFn();
      // Flag to prevent triggering drag n drop,
      // When compose modal is active
      emitter.emit(BUS_EVENTS.NEW_CONVERSATION_MODAL, true);
    },
    closeComposeConversationModal() {
      // Flag to enable drag n drop,
      // When compose modal is closed
      emitter.emit(BUS_EVENTS.NEW_CONVERSATION_MODAL, false);
    },
    toggleDeleteModal() {
      this.showDeleteModal = !this.showDeleteModal;
    },
    confirmDeletion() {
      this.deleteContact(this.contact);
      this.closeDelete();
    },
    closeDelete() {
      this.showDeleteModal = false;
      this.showEditModal = false;
    },
    findCountryFlag(countryCode, cityAndCountry) {
      try {
        if (!countryCode) {
          return `${cityAndCountry} 🌎`;
        }

        const code = countryCode?.toLowerCase();
        return `${cityAndCountry} <span class="fi fi-${code} size-3.5"></span>`;
      } catch (error) {
        return '';
      }
    },
    async deleteContact({ id }) {
      try {
        await this.$store.dispatch('contacts/delete', id);
        this.$emit('panelClose');
        useAlert(this.$t('DELETE_CONTACT.API.SUCCESS_MESSAGE'));

        if (isAConversationRoute(this.$route.name)) {
          this.$router.push({
            name: getConversationDashboardRoute(this.$route.name),
          });
        } else if (isAInboxViewRoute(this.$route.name)) {
          this.$router.push({
            name: 'inbox_view',
          });
        } else if (this.$route.name !== 'contacts_dashboard') {
          this.$router.push({
            name: 'contacts_dashboard',
          });
        }
      } catch (error) {
        useAlert(
          error.message
            ? error.message
            : this.$t('DELETE_CONTACT.API.ERROR_MESSAGE')
        );
      }
    },
    async copiar(valor) {
      if (!valor) return;
      await copyTextToClipboard(valor);
      useAlert(this.$t('CONTACT_PANEL.COPY_SUCCESSFUL'));
    },
    openMergeModal() {
      this.$refs.mergeModal?.open();
    },
  },
};
</script>

<template>
  <!-- Trama: perfil centralizado (protótipo aprovado em 19/10). Mesmos dados e ações de antes. -->
  <div class="relative w-full">
    <div class="flex flex-col items-center w-full text-center">
      <Avatar
        v-if="showAvatar"
        :src="contact.thumbnail"
        :name="contact.name"
        :status="contact.availability_status"
        :size="120"
        solido
        hide-offline-status
        rounded-full
      />
      <div
        v-if="showAvatar"
        class="flex items-center justify-center w-full min-w-0 gap-2"
      >
        <h2 class="trama-contato-nome font-sora">
          {{ contact.name }}
        </h2>
        <span
          v-if="contact.created_at"
          v-tooltip.left="
            `${$t('CONTACT_PANEL.CREATED_AT_LABEL')} ${dynamicTime(
              contact.created_at
            )}`
          "
          class="flex-shrink-0 mt-2.5 i-lucide-info text-sm text-n-slate-10"
        />
        <a
          :href="contactProfileLink"
          target="_blank"
          rel="noopener nofollow noreferrer"
          class="flex-shrink-0 mt-2.5 leading-3"
        >
          <span class="i-lucide-external-link text-sm text-n-slate-10" />
        </a>
      </div>

      <div v-if="contact.phone_number" class="trama-contato-tel">
        <a :href="`tel:${contact.phone_number}`" class="truncate">
          {{ contact.phone_number }}
        </a>
        <button
          type="button"
          :aria-label="$t('TRAMA_CONTATO.COPIAR')"
          :title="$t('TRAMA_CONTATO.COPIAR')"
          @click="copiar(contact.phone_number)"
        >
          <span class="i-lucide-copy size-[15px]" aria-hidden="true" />
        </button>
      </div>
      <div v-if="contact.email" class="trama-contato-tel is-email">
        <a :href="`mailto:${contact.email}`" class="truncate">
          {{ contact.email }}
        </a>
        <button
          type="button"
          :aria-label="$t('TRAMA_CONTATO.COPIAR')"
          :title="$t('TRAMA_CONTATO.COPIAR')"
          @click="copiar(contact.email)"
        >
          <span class="i-lucide-copy size-[13px]" aria-hidden="true" />
        </button>
      </div>

      <p
        v-if="additionalAttributes.description"
        class="break-words mt-2 mb-0.5 text-sm text-n-slate-11"
      >
        {{ additionalAttributes.description }}
      </p>
      <div
        v-if="
          contact.identifier ||
          additionalAttributes.company_name ||
          location ||
          additionalAttributes.location
        "
        class="flex flex-col items-start w-full gap-2 mt-3 text-start"
      >
        <ContactInfoRow
          v-if="contact.identifier"
          :value="contact.identifier"
          icon="contact-identify"
          emoji="🪪"
          :title="$t('CONTACT_PANEL.IDENTIFIER')"
        />
        <ContactInfoRow
          v-if="additionalAttributes.company_name"
          :value="additionalAttributes.company_name"
          icon="building-bank"
          emoji="🏢"
          :title="$t('CONTACT_PANEL.COMPANY')"
        />
        <ContactInfoRow
          v-if="location || additionalAttributes.location"
          :value="location || additionalAttributes.location"
          icon="map"
          emoji="🌍"
          :title="$t('CONTACT_PANEL.LOCATION')"
        />
      </div>
      <SocialIcons :social-profiles="socialProfiles" class="mt-2" />
      <div class="flex items-center justify-center w-full mt-3 gap-2">
        <ComposeConversation
          :contact-id="String(contact.id)"
          is-modal
          @close="closeComposeConversationModal"
        >
          <template #trigger="{ toggle }">
            <NextButton
              v-tooltip.top-end="$t('CONTACT_PANEL.NEW_MESSAGE')"
              icon="i-ph-chat-circle-dots"
              slate
              faded
              sm
              @click="openComposeConversationModal(toggle)"
            />
          </template>
        </ComposeConversation>
        <VoiceCallButton
          :phone="contact.phone_number"
          :contact-id="contact.id"
          icon="i-ri-phone-fill"
          size="sm"
          :tooltip-label="$t('CONTACT_PANEL.CALL')"
          slate
          faded
        />
        <NextButton
          v-tooltip.top-end="$t('EDIT_CONTACT.BUTTON_LABEL')"
          icon="i-ph-pencil-simple"
          slate
          faded
          sm
          @click="toggleEditModal"
        />
        <NextButton
          v-tooltip.top-end="$t('CONTACT_PANEL.MERGE_CONTACT')"
          icon="i-ph-arrows-merge"
          slate
          faded
          sm
          :disabled="uiFlags.isMerging"
          @click="openMergeModal"
        />
        <NextButton
          v-if="isAdmin"
          v-tooltip.top-end="$t('DELETE_CONTACT.BUTTON_LABEL')"
          icon="i-ph-trash"
          slate
          faded
          sm
          ruby
          :disabled="uiFlags.isDeleting"
          @click="toggleDeleteModal"
        />
      </div>
      <EditContact
        v-if="showEditModal"
        :show="showEditModal"
        :contact="contact"
        @cancel="toggleEditModal"
      />
      <ContactMergeModal ref="mergeModal" :primary-contact="contact" />
    </div>
    <woot-delete-modal
      v-if="showDeleteModal"
      v-model:show="showDeleteModal"
      :on-close="closeDelete"
      :on-confirm="confirmDeletion"
      :title="$t('DELETE_CONTACT.CONFIRM.TITLE')"
      :message="$t('DELETE_CONTACT.CONFIRM.MESSAGE')"
      :message-value="confirmDeleteMessage"
      :confirm-text="$t('DELETE_CONTACT.CONFIRM.YES')"
      :reject-text="$t('DELETE_CONTACT.CONFIRM.NO')"
    />
  </div>
</template>

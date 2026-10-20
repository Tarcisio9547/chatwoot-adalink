<script setup>
import { computed, watch, onMounted, onBeforeUnmount, ref } from 'vue';
import {
  useMapGetter,
  useFunctionGetter,
  useStore,
} from 'dashboard/composables/store';
import { useAccount } from 'dashboard/composables/useAccount';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';

import AccordionItem from 'dashboard/components/Accordion/AccordionItem.vue';
import ContactConversations from './ContactConversations.vue';
import ConversationAction from './ConversationAction.vue';
import ConversationParticipant from './ConversationParticipant.vue';
import ContactInfo from './contact/ContactInfo.vue';
import ContactNotes from './contact/ContactNotes.vue';
import ConversationInfo from './ConversationInfo.vue';
import CustomAttributes from './customAttributes/CustomAttributes.vue';
import Draggable from 'vuedraggable';
import MacrosList from './Macros/List.vue';
import ShopifyOrdersList from 'dashboard/components/widgets/conversation/ShopifyOrdersList.vue';
import SidebarActionsHeader from 'dashboard/components-next/SidebarActionsHeader.vue';
import LinearIssuesList from 'dashboard/components/widgets/conversation/linear/IssuesList.vue';
import LinearSetupCTA from 'dashboard/components/widgets/conversation/linear/LinearSetupCTA.vue';
import { buildCriarNegocioMessage } from './helpers/criarNegocioMessage';
import {
  podeNaoReceberCampanhas,
  solicitarNaoReceberCampanhas,
} from './helpers/naoReceberCampanhasMessage';

const props = defineProps({
  conversationId: {
    type: [Number, String],
    required: true,
  },
  inboxId: {
    type: Number,
    default: undefined,
  },
});

const {
  updateUISettings,
  isContactSidebarItemOpen,
  conversationSidebarItemsOrder,
  toggleSidebarUIState,
} = useUISettings();

const dragging = ref(false);
const conversationSidebarItems = ref([]);

const shopifyIntegration = useFunctionGetter(
  'integrations/getIntegration',
  'shopify'
);

const isShopifyFeatureEnabled = computed(
  () => shopifyIntegration.value.enabled
);

const { isCloudFeatureEnabled } = useAccount();

const isLinearFeatureEnabled = computed(() =>
  isCloudFeatureEnabled(FEATURE_FLAGS.LINEAR)
);

const linearIntegration = useFunctionGetter(
  'integrations/getIntegration',
  'linear'
);

const isLinearClientIdConfigured = computed(() => {
  return !!linearIntegration.value?.id;
});

const isLinearConnected = computed(
  () => linearIntegration.value?.enabled || false
);

const store = useStore();
const currentChat = useMapGetter('getSelectedChat');
const conversationId = computed(() => props.conversationId);
const conversationMetadataGetter = useMapGetter(
  'conversationMetadata/getConversationMetadata'
);
const currentConversationMetaData = computed(() =>
  conversationMetadataGetter.value(conversationId.value)
);
const conversationAdditionalAttributes = computed(
  () => currentConversationMetaData.value.additional_attributes || {}
);

const channelType = computed(() => currentChat.value.meta?.channel);

const contactGetter = useMapGetter('contacts/getContact');
const contactId = computed(() => currentChat.value.meta?.sender?.id);
const contact = computed(() => contactGetter.value(contactId.value));
const contactAdditionalAttributes = computed(
  () => contact.value.additional_attributes || {}
);

const getContactDetails = () => {
  if (contactId.value) {
    store.dispatch('contacts/show', { id: contactId.value });
  }
};

watch(contactId, (newContactId, prevContactId) => {
  if (newContactId && newContactId !== prevContactId) {
    getContactDetails();
  }
});

const onDragEnd = () => {
  dragging.value = false;
  updateUISettings({
    conversation_sidebar_items_order: conversationSidebarItems.value,
  });
};

const closeContactPanel = () => {
  updateUISettings({
    is_contact_sidebar_open: false,
    is_copilot_panel_open: false,
  });
};

// Adalink: Send contact data to CRM parent to create a deal
// Type 'trama-criar-negocio' bate com listener no CRM (Atendimento.tsx).
// conversationId/inboxId (conversa aberta) deixam o CRM ligar a conversa ao negócio.
const criarNegocio = () => {
  if (!contact.value) return;
  window.parent.postMessage(
    buildCriarNegocioMessage({
      contact: contact.value,
      conversationId: props.conversationId,
      inboxId: props.inboxId,
    }),
    '*'
  );
};

// Adalink: "Não receber campanhas de WhatsApp". O CRM (Atendimento.tsx) descadastra o telefone
// das campanhas de WhatsApp. O pedido, a resposta pareada (requestId) e o timeout ficam em
// solicitarNaoReceberCampanhas, a mesma função do item do menu de clique direito.
// Etapas: null (botão) -> 'confirmando' -> 'enviando' -> 'feito' | 'erro'.
const naoReceberEtapa = ref(null);
const naoReceberMensagem = ref('');
const podeNaoReceber = computed(() => podeNaoReceberCampanhas(contact.value));
// Pedido em andamento (para cancelar ao trocar de contato ou desmontar).
let naoReceberPedido = null;

const limparNaoReceberPedido = () => {
  naoReceberPedido?.cancelar();
  naoReceberPedido = null;
};

const pedirNaoReceber = () => {
  naoReceberMensagem.value = '';
  naoReceberEtapa.value = 'confirmando';
};

const cancelarNaoReceber = () => {
  limparNaoReceberPedido();
  naoReceberEtapa.value = null;
};

const confirmarNaoReceber = async () => {
  if (!podeNaoReceber.value || naoReceberEtapa.value !== 'confirmando') return;
  naoReceberEtapa.value = 'enviando';
  const pedido = solicitarNaoReceberCampanhas({
    telefone: contact.value.phone_number,
  });
  naoReceberPedido = pedido;
  const resposta = await pedido.promessa;
  // Cancelado (trocou de contato, desmontou) ou já existe um pedido mais novo.
  if (!resposta || naoReceberPedido !== pedido) return;
  naoReceberPedido = null;
  if (resposta.ok) {
    naoReceberMensagem.value = resposta.novo
      ? 'Pronto: este número não recebe mais campanhas.'
      : 'Este número já estava fora das campanhas.';
    naoReceberEtapa.value = 'feito';
  } else {
    naoReceberMensagem.value = resposta.error;
    naoReceberEtapa.value = 'erro';
  }
};

// Trocou de contato: o estado do botão não pode vazar para a pessoa seguinte.
watch(contactId, () => {
  limparNaoReceberPedido();
  naoReceberEtapa.value = null;
  naoReceberMensagem.value = '';
});

onMounted(() => {
  conversationSidebarItems.value = conversationSidebarItemsOrder.value;
  getContactDetails();
  store.dispatch('attributes/get', 0);
  // Load integrations to ensure linear integration state is available
  store.dispatch('integrations/get', 'linear');
});

onBeforeUnmount(() => {
  limparNaoReceberPedido();
});
</script>

<template>
  <div class="w-full">
    <SidebarActionsHeader
      :title="$t('CONVERSATION.SIDEBAR.CONTACT')"
      @close="closeContactPanel"
    />
    <ContactInfo :contact="contact" :channel-type="channelType" />

    <!-- Adalink: Criar Negócio button -->
    <div class="px-4 py-2">
      <button
        class="w-full flex items-center justify-center gap-2 px-3 py-2.5 rounded-lg text-sm font-medium bg-[rgb(30,58,95)] text-white hover:bg-[rgb(22,49,82)] transition-all"
        @click="criarNegocio"
      >
        <svg
          xmlns="http://www.w3.org/2000/svg"
          width="16"
          height="16"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
        >
          <path d="M12 5v14M5 12h14" />
        </svg>
        Criar Negócio
      </button>
    </div>

    <!-- Adalink: Não receber campanhas (WhatsApp) -->
    <div
      v-if="podeNaoReceber"
      class="px-4 pb-2"
      data-testid="nao-receber-campanhas"
    >
      <button
        v-if="!naoReceberEtapa || naoReceberEtapa === 'erro'"
        class="w-full flex items-center justify-center gap-2 px-3 py-2 rounded-lg text-sm font-medium border border-[rgb(30,58,95)] text-[rgb(30,58,95)] bg-transparent hover:bg-[rgba(30,58,95,0.08)] transition-all"
        @click="pedirNaoReceber"
      >
        Não receber campanhas de WhatsApp
      </button>
      <div
        v-else-if="naoReceberEtapa === 'confirmando'"
        class="rounded-lg border border-[rgb(203,213,225)] p-3 text-sm text-[rgb(51,65,85)]"
      >
        <p class="m-0 mb-2">
          Este número deixa de receber campanhas de WhatsApp (a fila de ligação
          não muda). Para voltar a receber, um administrador precisa reativar.
          Confirmar?
        </p>
        <div class="flex gap-2">
          <button
            class="flex-1 px-3 py-1.5 rounded-lg text-sm font-medium bg-[rgb(30,58,95)] text-white hover:bg-[rgb(22,49,82)]"
            @click="confirmarNaoReceber"
          >
            Sim, tirar
          </button>
          <button
            class="flex-1 px-3 py-1.5 rounded-lg text-sm font-medium border border-[rgb(203,213,225)] text-[rgb(51,65,85)] hover:bg-[rgb(241,245,249)]"
            @click="cancelarNaoReceber"
          >
            Cancelar
          </button>
        </div>
      </div>
      <p
        v-else-if="naoReceberEtapa === 'enviando'"
        class="m-0 text-sm text-[rgb(100,116,139)] text-center"
      >
        Tirando o número das campanhas...
      </p>
      <p
        v-else-if="naoReceberEtapa === 'feito'"
        class="m-0 text-sm text-[rgb(21,128,61)] text-center"
        role="status"
      >
        {{ naoReceberMensagem }}
      </p>
      <p
        v-if="naoReceberEtapa === 'erro'"
        class="m-0 mt-2 text-sm text-[rgb(185,28,28)] text-center"
        role="alert"
      >
        {{ naoReceberMensagem }}
      </p>
    </div>

    <div class="px-2 pb-8 list-group">
      <Draggable
        :list="conversationSidebarItems"
        animation="200"
        ghost-class="ghost"
        handle=".drag-handle"
        item-key="name"
        class="flex flex-col gap-3"
        @start="dragging = true"
        @end="onDragEnd"
      >
        <template #item="{ element }">
          <div
            v-if="element.name === 'conversation_actions'"
            class="conversation--actions"
          >
            <AccordionItem
              :title="$t('CONVERSATION_SIDEBAR.ACCORDION.CONVERSATION_ACTIONS')"
              :is-open="isContactSidebarItemOpen('is_conv_actions_open')"
              @toggle="
                value => toggleSidebarUIState('is_conv_actions_open', value)
              "
            >
              <ConversationAction
                :conversation-id="conversationId"
                :inbox-id="inboxId"
              />
            </AccordionItem>
          </div>
          <div
            v-else-if="element.name === 'conversation_participants'"
            class="conversation--actions"
          >
            <AccordionItem
              :title="$t('CONVERSATION_PARTICIPANTS.SIDEBAR_TITLE')"
              :is-open="isContactSidebarItemOpen('is_conv_participants_open')"
              @toggle="
                value =>
                  toggleSidebarUIState('is_conv_participants_open', value)
              "
            >
              <ConversationParticipant
                :conversation-id="conversationId"
                :inbox-id="inboxId"
              />
            </AccordionItem>
          </div>
          <div v-else-if="element.name === 'conversation_info'">
            <AccordionItem
              :title="$t('CONVERSATION_SIDEBAR.ACCORDION.CONVERSATION_INFO')"
              :is-open="isContactSidebarItemOpen('is_conv_details_open')"
              compact
              @toggle="
                value => toggleSidebarUIState('is_conv_details_open', value)
              "
            >
              <ConversationInfo
                :conversation-attributes="conversationAdditionalAttributes"
                :contact-attributes="contactAdditionalAttributes"
              />
            </AccordionItem>
          </div>
          <div v-else-if="element.name === 'contact_attributes'">
            <AccordionItem
              :title="$t('CONVERSATION_SIDEBAR.ACCORDION.CONTACT_ATTRIBUTES')"
              :is-open="isContactSidebarItemOpen('is_contact_attributes_open')"
              compact
              @toggle="
                value =>
                  toggleSidebarUIState('is_contact_attributes_open', value)
              "
            >
              <CustomAttributes
                attribute-type="contact_attribute"
                attribute-from="conversation_contact_panel"
                :contact-id="contact.id"
                :empty-state-message="
                  $t('CONVERSATION_CUSTOM_ATTRIBUTES.NO_RECORDS_FOUND')
                "
              />
            </AccordionItem>
          </div>
          <div v-else-if="element.name === 'previous_conversation'">
            <AccordionItem
              v-if="contact.id"
              :title="
                $t('CONVERSATION_SIDEBAR.ACCORDION.PREVIOUS_CONVERSATION')
              "
              :is-open="isContactSidebarItemOpen('is_previous_conv_open')"
              compact
              @toggle="
                value => toggleSidebarUIState('is_previous_conv_open', value)
              "
            >
              <ContactConversations
                :contact-id="contact.id"
                :conversation-id="conversationId"
              />
            </AccordionItem>
          </div>
          <woot-feature-toggle
            v-else-if="element.name === 'macros'"
            feature-key="macros"
          >
            <AccordionItem
              :title="$t('CONVERSATION_SIDEBAR.ACCORDION.MACROS')"
              :is-open="isContactSidebarItemOpen('is_macro_open')"
              compact
              @toggle="value => toggleSidebarUIState('is_macro_open', value)"
            >
              <MacrosList :conversation-id="conversationId" />
            </AccordionItem>
          </woot-feature-toggle>
          <div
            v-else-if="
              element.name === 'linear_issues' &&
              isLinearFeatureEnabled &&
              isLinearClientIdConfigured
            "
          >
            <AccordionItem
              :title="$t('CONVERSATION_SIDEBAR.ACCORDION.LINEAR_ISSUES')"
              :is-open="isContactSidebarItemOpen('is_linear_issues_open')"
              compact
              @toggle="
                value => toggleSidebarUIState('is_linear_issues_open', value)
              "
            >
              <LinearSetupCTA v-if="!isLinearConnected" />
              <LinearIssuesList v-else :conversation-id="conversationId" />
            </AccordionItem>
          </div>
          <div
            v-else-if="
              element.name === 'shopify_orders' && isShopifyFeatureEnabled
            "
          >
            <AccordionItem
              :title="$t('CONVERSATION_SIDEBAR.ACCORDION.SHOPIFY_ORDERS')"
              :is-open="isContactSidebarItemOpen('is_shopify_orders_open')"
              compact
              @toggle="
                value => toggleSidebarUIState('is_shopify_orders_open', value)
              "
            >
              <ShopifyOrdersList :contact-id="contactId" />
            </AccordionItem>
          </div>
          <div v-else-if="element.name === 'contact_notes'">
            <AccordionItem
              :title="$t('CONVERSATION_SIDEBAR.ACCORDION.CONTACT_NOTES')"
              :is-open="isContactSidebarItemOpen('is_contact_notes_open')"
              compact
              @toggle="
                value => toggleSidebarUIState('is_contact_notes_open', value)
              "
            >
              <ContactNotes :contact-id="contactId" />
            </AccordionItem>
          </div>
        </template>
      </Draggable>
    </div>
  </div>
</template>

<style lang="scss" scoped>
::v-deep {
  .contact--profile {
    @apply pb-3 border-b border-solid border-n-weak;
  }
}
</style>

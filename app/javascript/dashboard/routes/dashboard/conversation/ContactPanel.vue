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
import LinearIssuesList from 'dashboard/components/widgets/conversation/linear/IssuesList.vue';
import LinearSetupCTA from 'dashboard/components/widgets/conversation/linear/LinearSetupCTA.vue';
import { buildCriarNegocioMessage } from './helpers/criarNegocioMessage';
import { useTramaAtribuirAMim } from 'dashboard/composables/useTramaAtribuirAMim';
import { useAlert } from 'dashboard/composables';
import { copyTextToClipboard } from 'shared/helpers/clipboard';
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
// Textos do fluxo (pt-BR fixo do Trama, como as mensagens de resultado abaixo).
const TEXTOS_NAO_RECEBER = Object.freeze({
  botao: 'Não receber campanhas de WhatsApp',
  confirmacao:
    'Este número deixa de receber campanhas de WhatsApp (a fila de ligação não muda). Para voltar a receber, um administrador precisa reativar. Confirmar?',
  confirmar: 'Sim, tirar das campanhas',
  cancelar: 'Cancelar',
  enviando: 'Tirando o número das campanhas...',
});
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

// Trama: ações rápidas do perfil e blocos do painel (protótipo aprovado em 19/10).
// "Atribuir a mim" usa as mesmas chamadas do botão de ConversationAction.
const { souResponsavel, atribuirAMim } = useTramaAtribuirAMim();

const copiarNumero = async mensagemSucesso => {
  const telefone = contact.value?.phone_number;
  if (!telefone) return;
  await copyTextToClipboard(telefone);
  useAlert(mensagemSucesso);
};

// Quantas conversas anteriores (só quando a lista já foi carregada).
const contactConversationsGetter = useMapGetter(
  'contactConversations/getContactConversation'
);
const qtdConversasAnteriores = computed(() => {
  const getter = contactConversationsGetter.value;
  if (typeof getter !== 'function' || !contactId.value) return 0;
  const conversas = getter(contactId.value) || [];
  return conversas.filter(c => c.id !== Number(props.conversationId)).length;
});

const conversasAnterioresAbertas = computed(() =>
  isContactSidebarItemOpen('is_previous_conv_open')
);
const maisOpcoesAbertas = computed(() =>
  isContactSidebarItemOpen('is_trama_mais_opcoes_open')
);

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
  <div class="w-full trama-contato">
    <div class="trama-contato-h">
      <button
        type="button"
        class="trama-ib"
        :aria-label="$t('TRAMA_CONTATO.FECHAR')"
        :title="$t('TRAMA_CONTATO.FECHAR')"
        @click="closeContactPanel"
      >
        <span class="i-lucide-x size-5" aria-hidden="true" />
      </button>
      <h3>{{ $t('TRAMA_CONTATO.TITULO') }}</h3>
    </div>

    <div class="trama-contato-blk trama-contato-perfil">
      <ContactInfo :contact="contact" :channel-type="channelType" />

      <div class="trama-contato-quick">
        <!-- Adalink: Criar Negócio -->
        <button
          type="button"
          class="trama-contato-qb is-marca"
          data-testid="criar-negocio"
          @click="criarNegocio"
        >
          <span class="i-lucide-briefcase size-5" aria-hidden="true" />
          {{ $t('TRAMA_CONTATO.CRIAR_NEGOCIO') }}
        </button>
        <button
          type="button"
          class="trama-contato-qb"
          data-testid="painel-atribuir-a-mim"
          :disabled="souResponsavel"
          @click="atribuirAMim($t('CONVERSATION.CHANGE_AGENT'))"
        >
          <span class="i-lucide-user size-5" aria-hidden="true" />
          {{
            souResponsavel
              ? $t('TRAMA_CONTATO.COM_VOCE')
              : $t('TRAMA_CONTATO.ATRIBUIR_A_MIM')
          }}
        </button>
        <button
          type="button"
          class="trama-contato-qb"
          data-testid="painel-copiar-numero"
          :disabled="!contact.phone_number"
          @click="copiarNumero($t('CONTACT_PANEL.COPY_SUCCESSFUL'))"
        >
          <span class="i-lucide-copy size-5" aria-hidden="true" />
          {{ $t('TRAMA_CONTATO.COPIAR_NUMERO') }}
        </button>
      </div>
    </div>

    <div class="trama-contato-blk">
      <h4>{{ $t('TRAMA_CONTATO.RESPONSAVEL') }}</h4>
      <ConversationAction
        :conversation-id="conversationId"
        :inbox-id="inboxId"
        secao="responsavel"
      />
    </div>

    <div v-if="contact.id" class="trama-contato-blk">
      <button
        type="button"
        class="trama-contato-li !py-0.5"
        :aria-expanded="conversasAnterioresAbertas"
        @click="toggleSidebarUIState('is_previous_conv_open')"
      >
        <span
          class="i-lucide-history size-5 flex-shrink-0"
          aria-hidden="true"
        />
        <span class="flex-1 min-w-0">
          {{ $t('TRAMA_CONTATO.CONVERSAS_ANTERIORES') }}
          <small v-if="qtdConversasAnteriores">
            {{
              $t('TRAMA_CONTATO.QTD_CONVERSAS', { n: qtdConversasAnteriores })
            }}
          </small>
        </span>
        <span
          class="size-4 flex-shrink-0"
          :class="
            conversasAnterioresAbertas
              ? 'i-lucide-chevron-up'
              : 'i-lucide-chevron-down'
          "
          aria-hidden="true"
        />
      </button>
      <div v-if="conversasAnterioresAbertas" class="mt-2 -mx-6">
        <ContactConversations
          :contact-id="contact.id"
          :conversation-id="conversationId"
        />
      </div>
    </div>

    <!-- Adalink: Não receber campanhas (WhatsApp) -->
    <div
      v-if="podeNaoReceber"
      class="trama-contato-blk"
      data-testid="nao-receber-campanhas"
    >
      <button
        v-if="!naoReceberEtapa || naoReceberEtapa === 'erro'"
        type="button"
        class="trama-contato-li is-perigo"
        @click="pedirNaoReceber"
      >
        <span class="i-lucide-ban size-5 flex-shrink-0" aria-hidden="true" />
        <span>{{ TEXTOS_NAO_RECEBER.botao }}</span>
      </button>
      <div
        v-else-if="naoReceberEtapa === 'confirmando'"
        class="trama-contato-confirma"
      >
        <p>{{ TEXTOS_NAO_RECEBER.confirmacao }}</p>
        <div class="flex gap-2">
          <button
            type="button"
            class="trama-contato-btn is-perigo"
            @click="confirmarNaoReceber"
          >
            {{ TEXTOS_NAO_RECEBER.confirmar }}
          </button>
          <button
            type="button"
            class="trama-contato-btn is-contorno"
            @click="cancelarNaoReceber"
          >
            {{ TEXTOS_NAO_RECEBER.cancelar }}
          </button>
        </div>
      </div>
      <p
        v-else-if="naoReceberEtapa === 'enviando'"
        class="m-0 trama-contato-li !text-[var(--trama-wa-texto-2)]"
      >
        <span
          class="i-lucide-loader-circle size-5 flex-shrink-0 animate-spin"
          aria-hidden="true"
        />
        <span>{{ TEXTOS_NAO_RECEBER.enviando }}</span>
      </p>
      <p
        v-else-if="naoReceberEtapa === 'feito'"
        class="m-0 trama-contato-li !text-[var(--trama-wa-verde-escuro)]"
        role="status"
      >
        <span
          class="i-lucide-circle-check size-5 flex-shrink-0"
          aria-hidden="true"
        />
        <span>{{ naoReceberMensagem }}</span>
      </p>
      <p
        v-if="naoReceberEtapa === 'erro'"
        class="m-0 mb-2 text-sm text-[var(--trama-wa-perigo)]"
        role="alert"
      >
        {{ naoReceberMensagem }}
      </p>
    </div>

    <!-- Trama: o resto do painel do Chatwoot (time, prioridade, etiquetas,
         macros, participantes, informações, atributos, notas, Linear, Shopify)
         fica aqui, recolhido por padrão. -->
    <div class="trama-contato-blk">
      <button
        type="button"
        class="trama-contato-li !py-0.5"
        data-testid="mais-opcoes"
        :aria-expanded="maisOpcoesAbertas"
        @click="toggleSidebarUIState('is_trama_mais_opcoes_open')"
      >
        <span
          class="i-lucide-sliders-horizontal size-5 flex-shrink-0"
          aria-hidden="true"
        />
        <span class="flex-1 min-w-0">
          {{ $t('TRAMA_CONTATO.MAIS_OPCOES') }}
          <small>{{ $t('TRAMA_CONTATO.MAIS_OPCOES_DICA') }}</small>
        </span>
        <span
          class="size-4 flex-shrink-0"
          :class="
            maisOpcoesAbertas ? 'i-lucide-chevron-up' : 'i-lucide-chevron-down'
          "
          aria-hidden="true"
        />
      </button>
      <div v-if="maisOpcoesAbertas" class="pt-3 pb-2 -mx-4 list-group">
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
                :title="
                  $t('CONVERSATION_SIDEBAR.ACCORDION.CONVERSATION_ACTIONS')
                "
                :is-open="isContactSidebarItemOpen('is_conv_actions_open')"
                @toggle="
                  value => toggleSidebarUIState('is_conv_actions_open', value)
                "
              >
                <ConversationAction
                  :conversation-id="conversationId"
                  :inbox-id="inboxId"
                  secao="resto"
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
                :is-open="
                  isContactSidebarItemOpen('is_contact_attributes_open')
                "
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
  </div>
</template>

<style lang="scss" scoped>
::v-deep {
  .contact--profile {
    @apply pb-3 border-b border-solid border-n-weak;
  }
}
</style>

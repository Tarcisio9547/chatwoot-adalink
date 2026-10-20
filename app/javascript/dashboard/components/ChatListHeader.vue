<script setup>
import { computed } from 'vue';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { formatNumber } from '@chatwoot/utils';
import wootConstants from 'dashboard/constants/globals';

import ConversationBasicFilter from './widgets/conversation/ConversationBasicFilter.vue';
import SwitchLayout from 'dashboard/routes/dashboard/conversation/search/SwitchLayout.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import ComposeConversation from 'dashboard/components-next/NewConversation/ComposeConversation.vue';
import { emitter } from 'shared/helpers/mitt';
import { BUS_EVENTS } from 'shared/constants/busEvents';

const props = defineProps({
  pageTitle: { type: String, required: true },
  hasAppliedFilters: { type: Boolean, required: true },
  hasActiveFolders: { type: Boolean, required: true },
  isOnExpandedLayout: { type: Boolean, required: true },
  conversationStats: { type: Object, required: true },
  isListLoading: { type: Boolean, required: true },
});

const emit = defineEmits([
  'addFolders',
  'deleteFolders',
  'resetFilters',
  'basicFilterChange',
  'filtersModal',
]);

const { uiSettings, updateUISettings } = useUISettings();

// Trama: dentro do CRM o menu lateral do Chatwoot fica escondido (Dashboard.vue);
// "nova conversa" e configurações passam para o topo da lista.
const tramaEmbutido = (() => {
  try {
    return window.self !== window.top;
  } catch (e) {
    return true;
  }
})();
const abrirNovaConversa = toggle => {
  toggle();
  emitter.emit(BUS_EVENTS.NEW_CONVERSATION_MODAL, true);
};
const fecharNovaConversa = () => {
  emitter.emit(BUS_EVENTS.NEW_CONVERSATION_MODAL, false);
};

const onBasicFilterChange = (value, type) => {
  emit('basicFilterChange', value, type);
};

const hasAppliedFiltersOrActiveFolders = computed(() => {
  return props.hasAppliedFilters || props.hasActiveFolders;
});

const allCount = computed(() => props.conversationStats?.allCount || 0);
const formattedAllCount = computed(() => formatNumber(allCount.value));

const toggleConversationLayout = () => {
  const { LAYOUT_TYPES } = wootConstants;
  const {
    conversation_display_type: conversationDisplayType = LAYOUT_TYPES.CONDENSED,
  } = uiSettings.value;
  const newViewType =
    conversationDisplayType === LAYOUT_TYPES.CONDENSED
      ? LAYOUT_TYPES.EXPANDED
      : LAYOUT_TYPES.CONDENSED;
  updateUISettings({
    conversation_display_type: newViewType,
    previously_used_conversation_display_type: newViewType,
  });
};
</script>

<template>
  <div
    class="trama-lista-topo flex items-center justify-between gap-2 h-[60px] ltr:pl-[18px] ltr:pr-3 rtl:pr-[18px] rtl:pl-3"
    :class="{
      'trama-lista-topo--com-filtro': hasAppliedFiltersOrActiveFolders,
    }"
  >
    <div class="flex items-baseline min-w-0 gap-2">
      <h1
        class="trama-lista-titulo my-0 font-sora text-[21px] font-bold tracking-[-0.01em] truncate"
        :title="pageTitle"
      >
        {{ pageTitle }}
      </h1>
      <span
        v-if="
          allCount > 0 && hasAppliedFiltersOrActiveFolders && !isListLoading
        "
        class="trama-lista-contagem text-[12.5px] font-medium shrink-0"
        :title="allCount"
      >
        {{ formattedAllCount }}
      </span>
    </div>
    <div class="flex items-center gap-1">
      <template v-if="hasAppliedFilters && !hasActiveFolders">
        <div class="relative">
          <NextButton
            v-tooltip.top-end="$t('FILTER.CUSTOM_VIEWS.ADD.SAVE_BUTTON')"
            icon="i-lucide-save"
            slate
            xs
            faded
            @click="emit('addFolders')"
          />
          <div
            id="saveFilterTeleportTarget"
            class="absolute z-50 mt-2"
            :class="{ 'ltr:right-0 rtl:left-0': isOnExpandedLayout }"
          />
        </div>
        <NextButton
          v-tooltip.top-end="$t('FILTER.CLEAR_BUTTON_LABEL')"
          icon="i-lucide-circle-x"
          ruby
          faded
          xs
          @click="emit('resetFilters')"
        />
      </template>
      <template v-if="hasActiveFolders">
        <div class="relative">
          <NextButton
            id="toggleConversationFilterButton"
            v-tooltip.top-end="$t('FILTER.CUSTOM_VIEWS.EDIT.EDIT_BUTTON')"
            icon="i-lucide-pen-line"
            slate
            xs
            faded
            @click="emit('filtersModal')"
          />
          <div
            id="conversationFilterTeleportTarget"
            class="absolute z-50 mt-2"
            :class="{ 'ltr:right-0 rtl:left-0': isOnExpandedLayout }"
          />
        </div>
        <NextButton
          id="toggleConversationFilterButton"
          v-tooltip.top-end="$t('FILTER.CUSTOM_VIEWS.DELETE.DELETE_BUTTON')"
          icon="i-lucide-trash-2"
          ruby
          xs
          faded
          @click="emit('deleteFolders')"
        />
      </template>
      <div v-else class="relative">
        <NextButton
          id="toggleConversationFilterButton"
          v-tooltip.right="$t('FILTER.TOOLTIP_LABEL')"
          icon="i-lucide-list-filter"
          slate
          xs
          faded
          @click="emit('filtersModal')"
        />
        <div
          id="conversationFilterTeleportTarget"
          class="absolute z-50 mt-2"
          :class="{ 'ltr:right-0 rtl:left-0': isOnExpandedLayout }"
        />
      </div>
      <template v-if="tramaEmbutido">
        <ComposeConversation align-position="left" @close="fecharNovaConversa">
          <template #trigger="{ toggle }">
            <NextButton
              v-tooltip.top-end="$t('CONVERSATION.TRAMA_LISTA.NOVA_CONVERSA')"
              icon="i-lucide-pen-line"
              slate
              xs
              faded
              @click="abrirNovaConversa(toggle)"
            />
          </template>
        </ComposeConversation>
        <RouterLink
          v-tooltip.top-end="$t('CONVERSATION.TRAMA_LISTA.CONFIGURACOES')"
          :to="{ name: 'settings_home', params: $route.params }"
          class="inline-flex items-center justify-center size-7 rounded-lg text-n-slate-11 hover:bg-n-alpha-2"
        >
          <span class="i-lucide-settings size-4" />
        </RouterLink>
      </template>
      <SwitchLayout
        :is-on-expanded-layout="isOnExpandedLayout"
        @toggle="toggleConversationLayout"
      />
      <ConversationBasicFilter
        v-if="!hasAppliedFiltersOrActiveFolders"
        :is-on-expanded-layout="isOnExpandedLayout"
        show-status-trigger
        @change-filter="onBasicFilterChange"
      />
    </div>
  </div>
</template>

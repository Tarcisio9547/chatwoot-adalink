<script setup>
import { computed, ref, nextTick, onMounted } from 'vue';
import { useRouter } from 'vue-router';
import { useStore } from 'vuex';
import { useMapGetter } from 'dashboard/composables/store';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { useAccount } from 'dashboard/composables/useAccount';

import PageLayout from 'dashboard/components-next/captain/PageLayout.vue';
import CaptainPaywall from 'dashboard/components-next/captain/pageComponents/Paywall.vue';
import CreateAssistantDialog from 'dashboard/components-next/captain/pageComponents/assistant/CreateAssistantDialog.vue';
import AssistantPageEmptyState from 'dashboard/components-next/captain/pageComponents/emptyStates/AssistantPageEmptyState.vue';
import FeatureSpotlightPopover from 'dashboard/components-next/feature-spotlight/FeatureSpotlightPopover.vue';

const { isOnChatwootCloud } = useAccount();
const store = useStore();

const dialogType = ref('');
const uiFlags = useMapGetter('captainAssistants/getUIFlags');
const isFetching = computed(() => uiFlags.value.fetchingList);

const assistants = computed(() => store.getters['captainAssistants/getRecords']);
const isEmpty = computed(() => !isFetching.value && assistants.value.length === 0);

const selectedAssistant = ref(null);
const createAssistantDialog = ref(null);
const router = useRouter();

onMounted(() => {
  store.dispatch('captainAssistants/get');
});

const handleCreate = () => {
  dialogType.value = 'create';
  nextTick(() => createAssistantDialog.value.dialogRef.open());
};

const handleCreateClose = () => {
  dialogType.value = '';
  selectedAssistant.value = null;
};

const handleEdit = assistant => {
  router.push({
    name: 'captain_assistants_settings_index',
    params: {
      accountId: router.currentRoute.value.params.accountId,
      assistantId: assistant.id,
    },
  });
};

const handleAfterCreate = newAssistant => {
  if (newAssistant?.id) {
    router.push({
      name: 'captain_assistants_responses_index',
      params: {
        accountId: router.currentRoute.value.params.accountId,
        assistantId: newAssistant.id,
      },
    });
  }
};
</script>

<template>
  <PageLayout
    :header-title="$t('CAPTAIN.ASSISTANTS.HEADER')"
    :show-pagination-footer="false"
    :is-fetching="isFetching"
    :feature-flag="FEATURE_FLAGS.CAPTAIN"
    :is-empty="isEmpty"
    @click="handleCreate"
  >
    <template #knowMore>
      <FeatureSpotlightPopover
        :button-label="$t('CAPTAIN.HEADER_KNOW_MORE')"
        :title="$t('CAPTAIN.ASSISTANTS.EMPTY_STATE.FEATURE_SPOTLIGHT.TITLE')"
        :note="$t('CAPTAIN.ASSISTANTS.EMPTY_STATE.FEATURE_SPOTLIGHT.NOTE')"
        :hide-actions="!isOnChatwootCloud"
        fallback-thumbnail="/assets/images/dashboard/captain/assistant-popover-light.svg"
        fallback-thumbnail-dark="/assets/images/dashboard/captain/assistant-popover-dark.svg"
        learn-more-url="https://chwt.app/captain-assistant"
      />
    </template>
    <template #emptyState>
      <AssistantPageEmptyState @click="handleCreate" />
    </template>

    <template #paywall>
      <CaptainPaywall />
    </template>

    <!-- Lista de assistentes existentes -->
    <template v-if="!isEmpty" #default>
      <div class="grid gap-3 p-6">
        <div
          v-for="assistant in assistants"
          :key="assistant.id"
          class="flex items-center justify-between p-4 rounded-xl border border-n-weak bg-n-surface-2 hover:bg-n-surface-3 transition-colors cursor-pointer"
          @click="handleEdit(assistant)"
        >
          <div class="flex-1 min-w-0">
            <h3 class="text-sm font-semibold text-n-slate-12 truncate">{{ assistant.name }}</h3>
            <p class="text-xs text-n-slate-11 mt-0.5 truncate">{{ assistant.description }}</p>
          </div>
          <button
            class="ml-4 px-3 py-1.5 text-xs font-medium rounded-lg border border-n-weak text-n-slate-11 hover:text-n-slate-12 hover:bg-n-surface-4 transition-colors"
            @click.stop="handleEdit(assistant)"
          >
            Editar
          </button>
        </div>
      </div>
    </template>

    <CreateAssistantDialog
      v-if="dialogType"
      ref="createAssistantDialog"
      :type="dialogType"
      :selected-assistant="selectedAssistant"
      @close="handleCreateClose"
      @created="handleAfterCreate"
    />
  </PageLayout>
</template>

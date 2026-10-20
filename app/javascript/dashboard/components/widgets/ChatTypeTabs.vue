<script setup>
import { computed } from 'vue';
import { useKeyboardEvents } from 'dashboard/composables/useKeyboardEvents';
import wootConstants from 'dashboard/constants/globals';

const props = defineProps({
  items: {
    type: Array,
    default: () => [],
  },
  activeTab: {
    type: String,
    default: wootConstants.ASSIGNEE_TYPE.ME,
  },
});

const emit = defineEmits(['chatTabChange']);

const activeTabIndex = computed(() => {
  return props.items.findIndex(item => item.key === props.activeTab);
});

const onTabChange = selectedTabIndex => {
  if (selectedTabIndex >= 0 && selectedTabIndex < props.items.length) {
    const selectedItem = props.items[selectedTabIndex];
    if (selectedItem.key !== props.activeTab) {
      emit('chatTabChange', selectedItem.key);
    }
  }
};

const keyboardEvents = {
  'Alt+KeyN': {
    action: () => {
      if (props.activeTab === wootConstants.ASSIGNEE_TYPE.ALL) {
        onTabChange(0);
      } else {
        const nextIndex = (activeTabIndex.value + 1) % props.items.length;
        onTabChange(nextIndex);
      }
    },
  },
};

useKeyboardEvents(keyboardEvents);
</script>

<template>
  <!-- Trama: abas sublinhadas com cara de WhatsApp (contagem como número simples). -->
  <div
    role="tablist"
    class="trama-lista-abas flex w-full gap-5 px-[18px] pt-1 overflow-x-auto"
  >
    <button
      v-for="(item, index) in items"
      :key="item.key"
      type="button"
      role="tab"
      class="trama-lista-aba flex items-center flex-shrink-0 gap-1.5 pt-2 pb-2.5 text-sm font-semibold select-none"
      :class="{ 'trama-lista-aba--ativa': index === activeTabIndex }"
      :aria-selected="index === activeTabIndex"
      @click="onTabChange(index)"
    >
      {{ item.name }}
      <span class="trama-lista-aba-numero text-[12.5px] font-medium">
        {{ item.count }}
      </span>
    </button>
  </div>
</template>

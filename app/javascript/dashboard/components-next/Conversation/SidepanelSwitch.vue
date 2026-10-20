<script setup>
import { useUISettings } from 'dashboard/composables/useUISettings';
import { computed } from 'vue';
import { useKeyboardEvents } from 'dashboard/composables/useKeyboardEvents';

const { uiSettings, updateUISettings } = useUISettings();
const isContactSidebarOpen = computed(
  () => uiSettings.value.is_contact_sidebar_open
);

const toggleConversationSidebarToggle = () => {
  updateUISettings({
    is_contact_sidebar_open: !isContactSidebarOpen.value,
    is_copilot_panel_open: false,
  });
};

const keyboardEvents = {
  'Alt+KeyO': {
    action: toggleConversationSidebarToggle,
  },
};
useKeyboardEvents(keyboardEvents);
</script>

<!--
  Trama: o botão flutuante "Dados do Contato" saiu. Quem abre e fecha o painel
  agora é o cabeçalho da conversa (nome/avatar e o ícone (i)), como no WhatsApp.
  O atalho Alt+O continua aqui.
-->
<template>
  <span class="hidden" aria-hidden="true" />
</template>

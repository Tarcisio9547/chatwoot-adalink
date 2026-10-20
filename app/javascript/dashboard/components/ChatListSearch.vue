<script setup>
// Trama: campo de busca no topo da lista de conversas (cara de WhatsApp).
// Não filtra a lista carregada (ela é paginada e só teria parte das conversas):
// ao apertar Enter, abre a busca completa do Chatwoot (rota "search") já com o
// termo, que procura em conversas, mensagens e contatos.
import { ref } from 'vue';
import { useRouter } from 'vue-router';
import { useMapGetter } from 'dashboard/composables/store.js';
import { useEmitter } from 'dashboard/composables/emitter';

const router = useRouter();
const accountId = useMapGetter('getCurrentAccountId');

const term = ref('');

const openSearch = () => {
  const q = term.value.trim();
  router.push({
    name: 'search',
    params: { accountId: accountId.value },
    ...(q && { query: { q } }),
  });
};

useEmitter('clearSearchInput', () => {
  term.value = '';
});
</script>

<template>
  <form
    class="trama-lista-busca relative mx-3 mb-1.5"
    role="search"
    @submit.prevent="openSearch"
  >
    <span
      class="i-lucide-search trama-lista-busca-icone absolute size-4 top-2.5 ltr:left-3.5 rtl:right-3.5 pointer-events-none"
      aria-hidden="true"
    />
    <input
      v-model="term"
      type="search"
      enterkeyhint="search"
      class="reset-base trama-lista-busca-campo block w-full h-9 m-0 border-0 rounded-lg ltr:pl-11 ltr:pr-3 rtl:pr-11 rtl:pl-3 py-0 text-sm"
      :placeholder="$t('CHAT_LIST.SEARCH.LIST_PLACEHOLDER')"
      :aria-label="$t('CHAT_LIST.SEARCH.LIST_PLACEHOLDER')"
    />
  </form>
</template>

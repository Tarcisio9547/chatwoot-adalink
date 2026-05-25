# Multi-LLM no Chatwoot — Spec

**Data:** 2026-05-25
**Branch:** `feat/chatwoot-multi-llm` (saindo de `adalink-branding`)
**Backup tag:** `backup-pre-multi-llm-2026-05-25` (HEAD `4d1dad193`)
**Owner:** Agente Chatwoot
**Status:** Aguardando aprovação pra começar a implementação

---

## 1. Resumo do que vou fazer

Estender o fork pra que o seletor de modelo existente em **Configurações → Captain** liste e use providers além do OpenAI (DeepSeek primeiro; Anthropic/Gemini ficam com o `coming_soon` que já está no YAML). **Default permanece OpenAI** — nada quebra pra account que não trocar.

---

## 2. Estado atual (confirmado por survey read-only)

### 2.1 Abstração já existe (parcial)
- `lib/llm/config.rb` — wrapper sobre `ruby_llm` (gem **1.9.2** — suporta nativamente OpenAI, Anthropic, Gemini, **DeepSeek**, OpenRouter, Ollama, Bedrock).
- `config/llm.yml` — declaração dos providers, models e features. **Único arquivo que precisa ser estendido pra novos providers aparecerem.**
- `enterprise/app/services/llm/base_ai_service.rb` — todas as features Captain (V2) passam por aqui via `RubyLLM.chat(model:)`.
- UI: `app/javascript/dashboard/routes/dashboard/settings/captain/components/ModelDropdown.vue` — lê os models do `llm.yml` por feature.
- Persistência: `account.settings.captain_models` (jsonb) — `{ assistant: 'gpt-5.1', copilot: 'gpt-5-mini', ... }`.
- API: `PUT /api/v1/accounts/{id}/captain/preferences`.

### 2.2 Onde tá o pulo do gato (não é só adicionar no YAML)

| # | Problema | Caminho | Severidade |
|---|---|---|---|
| **G1** | `Llm::Config` só configura `openai_api_key`/`openai_api_base` no `ruby_llm`. Não passa key de DeepSeek/etc. | `lib/llm/config.rb:33-39` | 🔴 Bloqueante |
| **G2** | Reply suggestion, label suggestion, summary, rewrite usam `GPT_MODEL = Llm::Config::DEFAULT_MODEL` hardcoded — **ignoram** `account.captain_<feature>_model`. Trocar no dropdown não muda nada nessas. | `lib/captain/base_task_service.rb`, `reply_suggestion_service.rb`, `label_suggestion_service.rb`, `summary_service.rb`, `rewrite_service.rb` | 🔴 Bloqueante |
| **G3** | `Article#generate_search_terms` faz **HTTParty direta** pra `https://api.openai.com/v1/chat/completions` com `gpt-4o` hardcoded. Fora da abstração. | `enterprise/app/models/enterprise/concerns/article.rb:69-81` | 🟡 Alto |
| **G4** | `TranslateQuery` e `PaginatedFAQGenerator` têm modelos hardcoded (`gpt-4.1-nano`, `gpt-4.1-mini`). | `enterprise/app/services/captain/llm/translate_query_service.rb:2`, `enterprise/app/services/captain/llm/paginated_faq_generator_service.rb` | 🟡 Alto |
| **G5** | Typo no `llm.yml`: `aproviders:` em vez de `providers:` (linha 1). Não é lido em lugar nenhum hoje — cosmético, mas se eu fixar facilita extensões futuras. | `config/llm.yml:1` | 🟢 Baixo |
| **G6** | Embeddings: `text-embedding-3-small` (1536 dim) pra knowledge base. Trocar provider quebra `ArticleEmbedding.nearest_neighbors`. | `lib/llm_constants.rb:5`, `enterprise/app/services/captain/llm/embedding_service.rb` | 🔴 Fora de escopo (ver §5) |

### 2.3 Features de Captain confirmadas
Editor (rewrite), Assistant (Captain V2 conversation), Copilot (sugestão de resposta inline), Label Suggestion, Audio Transcription (Whisper), Help Center Search (embeddings), Reply Suggestion (templates clássicos), FAQ Generator (knowledge base), Translate Query.

---

## 3. Plano de execução (etapas pequenas, cada uma commit isolado)

### Etapa 1 — `config/llm.yml`: adicionar provider DeepSeek
- Corrigir typo `aproviders:` → `providers:`.
- Adicionar `deepseek:` em `providers:` (display_name "DeepSeek").
- Adicionar models `deepseek-v4-flash` e `deepseek-v4-pro` com `provider: deepseek`, sem `coming_soon: true` (eles vão funcionar).
- Adicionar esses dois models nas listas das features `editor`, `assistant`, `copilot`, `label_suggestion` (NÃO em `audio_transcription`/`help_center_search`).
- Sem mudar nenhum `default:` — defaults continuam OpenAI.

### Etapa 2 — `lib/llm/config.rb`: wiring de DeepSeek key
- Adicionar `system_deepseek_api_key` lendo `InstallationConfig('CAPTAIN_DEEPSEEK_API_KEY')`.
- Adicionar `system_deepseek_endpoint` (opcional — pra rota via OpenRouter no futuro).
- No `configure_ruby_llm`: setar `config.deepseek_api_key` quando presente.
- Expor `with_api_key` agnóstico: aceitar `provider:` como kwarg pra setar a key correta no `RubyLLM.context`.
- Mantém compatibilidade total com OpenAI (signature antiga continua funcionando).

### Etapa 3 — Fechar G2 (reply/label/summary/rewrite usam account preference)
- Em `lib/captain/base_task_service.rb`, trocar `GPT_MODEL = Llm::Config::DEFAULT_MODEL` por método `gpt_model_for_feature` que lê `account.captain_<feature>_model` com fallback no `DEFAULT_MODEL`.
- Atualizar `reply_suggestion_service.rb`, `label_suggestion_service.rb`, `summary_service.rb`, `rewrite_service.rb` pra passar `feature:` no construtor e usar o novo método.
- **Não muda comportamento pra account que não configurou** — fallback é o mesmo `gpt-4.1-mini`.

### Etapa 4 — Fechar G3 (Article#generate_search_terms)
- Refatorar a chamada HTTParty pra usar `RubyLLM.chat(model: account.captain_assistant_model)` via `Llm::Config.with_api_key`.
- Remover hardcode `'gpt-4o'`.

### Etapa 5 — Fechar G4 (TranslateQuery, PaginatedFAQGenerator)
- Mesma técnica: ler de account ou fallback.

### Etapa 6 — Roteamento de key por provider em runtime
- Hook account-level existente é OpenAI-only (`account.hooks.find_by(app_id: 'openai')`).
- Adicionar suporte pra hook `app_id: 'deepseek'` análogo (mesmo padrão, novo app_id).
- Quando o service precisa rodar com DeepSeek, busca key na ordem: hook account `deepseek` → `InstallationConfig CAPTAIN_DEEPSEEK_API_KEY`.
- Detecção: ler o `provider` do model selecionado no `llm.yml`.

### Etapa 7 — Smoke tests manuais
Para cada feature (assistant, copilot, label_suggestion, reply_suggestion, summary, rewrite):
- Rodar com OpenAI selecionado → bate igual ao baseline (sem regressão).
- Rodar com DeepSeek V4 Flash selecionado → resposta volta sem erro, com `provider=deepseek` nos logs.
- Account sem DeepSeek key configurada → erro claro ("DeepSeek API key não configurada"), não 500.

### Etapa 8 — Documentação
- `docs/multi-llm-setup.md`: como o admin Tarcisio adiciona a key DeepSeek (Installation Config no Super Admin OU Hook por account).
- Atualizar `App/docs/Como Desbloquear o Chatwoot.md` (no repo CRM) com a seção de provider config.

---

## 4. Riscos e mitigações

| Risco | Mitigação |
|---|---|
| Quebrar Captain da GVM (1.293 logs, uso real) | Default em OpenAI mantido. Backup tag pronta. Smoke test cada serviço antes de declarar pronto. Plano de rollback: `git revert` do merge ou checkout da tag. |
| `ruby_llm 1.9.2` ter bug em DeepSeek tool calling | Testar tool calling do Copilot em DeepSeek antes de declarar etapa 7 ok. Se quebrar: marcar DeepSeek pra "no-tools-features" (assistant/copilot ficam com OpenAI; editor/label rodam DeepSeek). |
| Account muda pra DeepSeek mas key não configurada | Erro defensivo claro + UI valida no `Testar conexão`. Não silenciar exceção. |
| Latência DeepSeek > OpenAI em copilot inline | Trabalho do PRD do CRM. Aqui só medir P95 nos logs e reportar. |
| Embeddings (G6) — usuário troca pra DeepSeek esperando funcionar tudo | `help_center_search` NÃO recebe DeepSeek na lista de models. Continua só OpenAI. Dropdown não oferece a troca. |

---

## 5. Escopo explicitamente FORA

- **Embeddings (`help_center_search`, `text-embedding-3-small`)** — trocar provider invalida 1536-dim vectors existentes. Migração séria (re-compute de todos os artigos). Fica pra outro projeto.
- **Whisper (`audio_transcription`)** — DeepSeek não faz transcrição de áudio. Mantém OpenAI.
- **Fork-customizar `ruby_llm`** — não é necessário. A gem 1.9.2 já suporta DeepSeek nativo.
- **Trocar default de OpenAI pra DeepSeek** — decisão do PRD/usuário, não desta entrega. Aqui só viabilizo.
- **UI nova de "provider config"** — usuário disse "no mesmo lugar". Reuso o ModelDropdown.

---

## 6. Critério de pronto

- Dropdown em **Configurações → Captain** lista DeepSeek V4 Flash e Pro.
- Selecionar DeepSeek em uma feature e mandar uma mensagem usa DeepSeek de verdade (verifico no log do service + dashboard de billing).
- Account sem trocar nada continua igual (OpenAI, mesmos modelos).
- Account sem key DeepSeek que tentou trocar recebe erro claro.
- 6 features testadas (assistant, copilot, label_suggestion, reply_suggestion, summary, rewrite) com OpenAI e DeepSeek.
- `docs/multi-llm-setup.md` escrito.

---

## 7. Decisões pendentes — preciso da sua resposta

| # | Decisão | Recomendação |
|---|---|---|
| **D1** | Chamada DeepSeek direta OU via OpenRouter? | **Direta** (mais barato, sem markup do roteador). OpenRouter só se LGPD pedir saída EU/US — DeepSeek tem endpoint global mas servidor primário é China. |
| **D2** | Key DeepSeek mora em `InstallationConfig` (1 chave pra toda a instância Chatwoot Railway) ou Hook por account (Adalink, GVM, Trama têm chaves separadas)? | **Hook por account**. Cada tenant paga sua própria conta DeepSeek. Mesmo padrão do OpenAI hoje. |
| **D3** | Adicionar Claude 4.5 e Gemini 3 (tirando `coming_soon: true` que está no YAML)? | **Não nessa entrega.** Mantém escopo. DeepSeek primeiro, prova o padrão, depois replico se você quiser. |
| **D4** | Etapas 4 e 5 (Article search_terms + TranslateQuery hardcodes) entram nessa PR ou em PR separada? | **Mesma PR**. Sem elas, "rodar tudo em DeepSeek" tem buracos onde silenciosamente vai cair em OpenAI. |

---

## 8. Tamanho da entrega

- **8 arquivos** tocados (estimativa): `config/llm.yml`, `lib/llm/config.rb`, 4 services em `lib/captain/`, `enterprise/.../article.rb`, `enterprise/.../translate_query_service.rb`, `enterprise/.../paginated_faq_generator_service.rb`, `app/javascript/dashboard/store/captain/preferences.js` (ordenação do provider).
- **Migration:** zero. Tudo em Settings/jsonb que já existe.
- **Estimativa:** 1 dia de implementação + 1 dia de smoke tests.
- **PR única** (vs várias pequenas): única, porque as etapas se quebram mutuamente se entregues parcialmente.

---

## 9. O que NÃO mudo no fork

- Nada em `app/services/captain/` que não esteja na lista de gaps.
- Nada em `app/javascript/` além do `preferences.js` (sort order).
- Nenhuma migration Postgres.
- Nenhum initializer (lembrete da regra do fork: zero DB writes em initializers).
- Nada relacionado a sino, Atendimento UI, kanban, etc — escopo é IA.

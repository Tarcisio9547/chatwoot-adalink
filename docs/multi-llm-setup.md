# Multi-LLM no Chatwoot — Guia de Setup

**Branch:** `feat/chatwoot-multi-llm` (saindo de `adalink-branding`)
**Backup tag:** `backup-pre-multi-llm-2026-05-25`
**Status:** implementação pronta — aguarda merge + cadastro da API key da OpenRouter

---

## TL;DR

Captain do Chatwoot agora **pode rodar em DeepSeek (via OpenRouter)** além de OpenAI. Default permanece OpenAI; trocar é por account no painel **Configurações → Captain**. Custo cai ~50% pra a mesma classe de tarefa.

---

## Features afetadas

| Feature do Chatwoot | Funciona com DeepSeek? | Onde escolhe |
|---|---|---|
| Captain V1 — Reply Suggestion | ✅ | dropdown `editor` |
| Captain V1 — Rewrite (editor) | ✅ | dropdown `editor` |
| Captain V1 — Summary | ✅ | dropdown `editor` |
| Captain V1 — Label Suggestion | ✅ | dropdown `label_suggestion` |
| Captain V2 — Copilot inline | ✅ | dropdown `copilot` |
| Captain V2 — Assistant (Lara) | ✅ | dropdown `assistant` |
| Captain V2 — Translate (interno) | ✅ | herda `label_suggestion` |
| Captain V2 — ConversationCompletion (interno) | ✅ | InstallationConfig system-wide |
| Article search terms (knowledge base) | ✅ | herda `assistant` |
| Legacy OpenAI Integration | ✅ (defensivo, deriva do model do payload) | hook da integração |
| **Captain V2 — FAQ Generator (PDF)** | ❌ **OpenAI-only** | usa Files API do OpenAI (sem equivalente) |
| **Captain V2 — PDF Processing** | ❌ **OpenAI-only** | mesmo motivo acima |
| **Audio Transcription (Whisper)** | ❌ **OpenAI-only** | sem equivalente em outros providers |
| **Embeddings (help_center_search)** | ❌ **OpenAI-only** | 1536-dim vectors existentes quebram se mudar provider |

Resumo: tudo o que é texto/chat pode trocar pra DeepSeek. PDFs, áudio e embeddings ficam OpenAI por dependência técnica.

---

## Setup em 3 passos

### 1) Cadastrar a API key da OpenRouter (uma vez por instância Chatwoot)

**Opção A — Super Admin (recomendado pra single-tenant):**

1. Acesse `/super_admin` no Chatwoot
2. **App Configs** → **Installation Configs**
3. Criar novo config:
   - Name: `CAPTAIN_OPENROUTER_API_KEY`
   - Value: `sk-or-...` (sua key da OpenRouter)
4. Opcional — endpoint custom (default `https://openrouter.ai/api/v1`):
   - Name: `CAPTAIN_OPENROUTER_ENDPOINT`
   - Value: `https://openrouter.ai/api/v1`

**Opção B — Per-account (multi-tenant, cada account paga sua conta):**

Cada account admin do tenant cria um Hook:

1. Account Settings → **Integrations** → **Apps**
2. Adicionar **OpenRouter** (app_id: `openrouter`)
3. Settings: `api_key = sk-or-...`
4. Status: enabled

A cascata de resolução é: hook account-level > InstallationConfig system. Account com hook configurado sobrescreve o system key.

### 2) Verificar `config/llm.yml`

Os 2 modelos DeepSeek via OpenRouter já estão registrados:

```yaml
deepseek/deepseek-v4-flash:
  provider: openrouter
  display_name: 'DeepSeek V4 Flash (OpenRouter)'
deepseek/deepseek-v4-pro:
  provider: openrouter
  display_name: 'DeepSeek V4 Pro (OpenRouter)'
```

E aparecem como opções nas features `editor`, `assistant`, `copilot`, `label_suggestion`. Audio/embedding NÃO recebem essas opções (intencionalmente).

### 3) Trocar no UI

Account admin acessa **Configurações → Captain**, clica numa feature (ex: Copilot) e seleciona `DeepSeek V4 Flash (OpenRouter)` no dropdown. Salvar.

A partir desse momento, toda chamada do Captain pra essa feature roda em DeepSeek.

---

## Smoke test recomendado pós-deploy

Validar uma feature de cada vez. Testes manuais no painel:

| Feature | Como testar | Verificação |
|---|---|---|
| Reply Suggestion | Conversa aberta no Atendimento → "Sugerir resposta" | Resposta volta em < 5s, faz sentido |
| Rewrite | Editor de mensagem → ícone "casual" | Texto reescrito |
| Summary | Conversa com ≥ 5 mensagens → "Resumir" | Resumo coerente |
| Label Suggestion | Conversa com ≥ 3 mensagens incoming → backend dispara | Label sugerida aparece (job background) |
| Copilot | Conversa aberta → painel Copilot → pergunta sobre o contato | Resposta vem com tool calls funcionando |
| Captain Assistant | Conversa onde Captain está ativo → cliente manda msg | Resposta gerada |

Verificar no CRM (`ai_usage_logs`) que custo aparece correto:

```sql
SELECT feature, model, metadata->>'provider' AS provider, cost_usd, created_at
FROM ai_usage_logs
WHERE feature LIKE 'captain.%' AND created_at > NOW() - INTERVAL '1 hour'
ORDER BY created_at DESC LIMIT 20;
```

Esperado pra DeepSeek: `model='deepseek/deepseek-v4-flash'`, `provider='openrouter'`, `cost_usd` proporcional ($0.14/1M input + $0.28/1M output).

---

## Rollback se algo quebrar

```bash
# Voltar pro estado pré-multi-llm na branch adalink-branding:
git tag -l backup-pre-multi-llm-2026-05-25  # confirma a tag existe
git checkout adalink-branding
git reset --hard backup-pre-multi-llm-2026-05-25
git push adalink adalink-branding --force-with-lease  # CUIDADO — só com autorização
```

**Antes do force-push**, criar branch de segurança no head atual:

```bash
git branch safety/before-revert-$(date +%Y%m%d)
git push adalink safety/before-revert-$(date +%Y%m%d)
```

Alternativa menos drástica: trocar default do dropdown de volta pra modelo OpenAI no painel. Não precisa rollback de código se só quer reverter o COMPORTAMENTO.

---

## Variáveis de ambiente

Nenhuma nova obrigatória. Opcionais (todas configuráveis em InstallationConfig do Super Admin):

| Nome | Função | Default |
|---|---|---|
| `CAPTAIN_OPEN_AI_API_KEY` | Key OpenAI system-wide | (necessário se usar OpenAI) |
| `CAPTAIN_OPEN_AI_ENDPOINT` | Endpoint OpenAI custom | `https://api.openai.com` |
| `CAPTAIN_OPEN_AI_MODEL` | Modelo OpenAI system-wide (fallback) | `gpt-4.1-mini` |
| `CAPTAIN_OPENROUTER_API_KEY` | **Novo** — Key OpenRouter system-wide | (necessário se usar DeepSeek) |
| `CAPTAIN_OPENROUTER_ENDPOINT` | **Novo** — Endpoint OpenRouter custom | `https://openrouter.ai/api/v1` |
| `CRM_LOG_USAGE_URL` | Endpoint do log-captain-usage no CRM | (skip silencioso se vazio) |
| `CRM_LOG_USAGE_SECRET` | Shared secret pro log-captain-usage | (skip silencioso se vazio) |

---

## Limitações e escopo fora

- **Embeddings continuam OpenAI** — `text-embedding-3-small` (1536 dim). Trocar invalida `ArticleEmbedding`s existentes.
- **PDF/Files API continua OpenAI** — `PaginatedFaqGeneratorService` e `PdfProcessingService` dependem da Files API do OpenAI (sem equivalente em DeepSeek/OpenRouter).
- **Whisper continua OpenAI** — transcrição de áudio sem equivalente.
- **Tool calling em DeepSeek** — `ruby_llm 1.9.2` suporta nativamente, mas vale validar com Copilot (feature mais dependente de tools). Se rejeitar, troca de volta pra OpenAI no dropdown da feature.
- **Latência** — DeepSeek V4 Flash TTFT ~1.24s vs ~400ms OpenAI. Aceitável pra todos os casos de uso (assistente, summary, label). Copilot inline pode ficar levemente mais lento.

---

## Mapping de feature → modelo default (sem trocar nada)

| Feature do Captain | Default model | Provider | Custo /1M tokens |
|---|---|---|---|
| editor | `gpt-4.1-mini` | openai | $0.40 / $1.60 |
| assistant | `gpt-5.1` | openai | $0.05 / $0.40 (estimativa) |
| copilot | `gpt-5.1` | openai | mesmo |
| label_suggestion | `gpt-4.1-nano` | openai | mesmo classe nano |
| audio_transcription | `whisper-1` | openai | n/a |
| help_center_search | `text-embedding-3-small` | openai | n/a |

Pós-troca pra DeepSeek V4 Flash (todas as features text): **~$0.14 / $0.28 por 1M tokens** — ~50% menos que `gpt-4.1-mini`, ~80% menos que `gpt-5.1`.

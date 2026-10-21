# Hub model sweep - October 2026

Per the supplied retirement notice, OpenRouter retires `openai/gpt-4o`, `openai/gpt-4o-mini`, `openai/gpt-4.1` and `openai/gpt-4.1-mini`, including dated IDs, on **2027-01-14**. This is an offline inventory, not a live provider-availability check.

The deployed code in `server/` and `integrations/update-thought-mcp/` has **zero retiring IDs**. Capture metadata extraction already uses `openai/gpt-6-luna`; embeddings use `openai/text-embedding-3-small`. No deployment model changes are needed. Upstream recipes, integrations, skills and existing documentation are unchanged.

One row per file follows. Lines include all matching references, including comments, bare OpenAI model names, examples and provenance. A provider label describes the referenced route; documentation and commented examples do not themselves execute calls. Direct OpenAI references are listed for visibility; the supplied OpenRouter notice does not establish their OpenAI retirement dates.

Scope: source, documentation and provenance examples, plus one deployment-manifest model reference returned by the initial search. Credential/environment files and other configuration files are excluded; this inventory does not certify excluded files. No dated retiring IDs or GPT-4.1 family references were found in the inspected files.

**31 file rows; 25 reference OpenRouter** (23 OpenRouter-only/default and 2 mixed-provider rows), 3 use OpenAI directly, and 3 contain provenance only. These are file-reference counts, not counts of deployed calls.

| File | Line(s) | Model ID(s) as written | Provider / route | Purpose |
| --- | --- | --- | --- | --- |
| `docs/examples/ingestion-metadata.example.json` | 26 | `openai/gpt-4o-mini` | None (provenance) | Example ingestion metadata; no model call. |
| `docs/ingestion-metadata-contract.md` | 104 | `openai/gpt-4o-mini` | None (provenance) | Example extractor provenance; no model call. |
| `docs/open-brain-assistant-gpt-context.md` | 67, 329 | `openai/gpt-4o-mini` | OpenRouter | Documentation of capture metadata extraction. |
| `integrations/consolidation-workers/bio/index.ts` | 328 | `gpt-4o` | OpenAI direct | Fallback user-profile synthesis; the retiring ID is in the direct OpenAI branch. |
| `integrations/kubernetes-deployment/index.ts` | 15, 40 | `gpt-4o-mini`, `openai/gpt-4o-mini` | OpenRouter (default) | Configurable capture metadata extraction. |
| `integrations/kubernetes-deployment/k8s/openbrain.yml` | 158 | `openai/gpt-4o-mini` | OpenRouter (default) | Deployment CHAT_MODEL setting consumed by the sibling capture server; no call in this file. |
| `integrations/open-brain-rest/index.ts` | 210 | `openai/gpt-4o-mini` | OpenRouter | REST capture metadata extraction. |
| `integrations/slack-capture/README.md` | 140 | `openai/gpt-4o-mini` | OpenRouter | Slack capture metadata extraction example. |
| `integrations/telegram-capture/README.md` | 152 | `openai/gpt-4o-mini` | OpenRouter | Telegram capture metadata extraction example. |
| `recipes/adaptive-capture-classification/capture-with-gating.ts` | 26 | `openai/gpt-4o-mini` | OpenRouter | Confidence-gated capture classification. |
| `recipes/chatgpt-conversation-import/README.md` | 119, 140, 174, 236, 305 | `gpt-4o-mini`, `gpt-4o`, `openai/gpt-4o-mini` | OpenRouter | Conversation import extraction, pricing and historical model provenance examples. |
| `recipes/chatgpt-conversation-import/import-chatgpt.py` | 359, 736, 737, 1111 | `openai/gpt-4o-mini`, `gpt-4o`, `gpt-4o-mini` | OpenRouter | Conversation import knowledge extraction and default CLI model. |
| `recipes/chatgpt-conversation-import/schema.sql` | 35 | `gpt-4o` | None (provenance) | Historical conversation model_slug example; no model call. |
| `recipes/editorial-policy/README.md` | 38, 177 | `gpt-4o-mini` | OpenRouter | Editorial auditor model guidance. |
| `recipes/editorial-policy/auditor/index.ts` | 281 | `openai/gpt-4o-mini` | OpenRouter | Editorial policy audit and findings generation. |
| `recipes/email-history-import/pull-gmail.ts` | 614 | `openai/gpt-4o-mini` | OpenRouter | Email import metadata extraction. |
| `recipes/entity-wiki/README.md` | 110, 195, 221, 282 | `gpt-4o-mini`, `openai/gpt-4o-mini` | OpenRouter (default) | Optional wiki synthesis model examples; endpoint is configurable. |
| `recipes/google-activity-import/README.md` | 166, 218 | `gpt-4o-mini` | OpenRouter | Activity import day summaries and thought extraction guidance. |
| `recipes/google-activity-import/import-google-activity.mjs` | 328, 339, 491, 653 | `gpt-4o-mini`, `openai/gpt-4o-mini` | OpenRouter | Activity import day summaries and thought extraction. |
| `recipes/obsidian-vault-import/README.md` | 168, 174 | `gpt-4o-mini` | OpenRouter | Vault import long-section distillation guidance. |
| `recipes/obsidian-vault-import/import-obsidian.py` | 59 | `openai/gpt-4o-mini` | OpenRouter | Vault import long-section distillation into thoughts. |
| `recipes/perplexity-conversation-import/README.md` | 145, 217 | `gpt-4o-mini` | OpenRouter | Conversation import summarization guidance. |
| `recipes/perplexity-conversation-import/import-perplexity.py` | 480, 1082 | `openai/gpt-4o-mini`, `gpt-4o-mini` | OpenRouter | Conversation import summarization and extraction. |
| `recipes/schema-aware-routing/README.md` | 179, 214, 237, 330 | `gpt-4o-mini`, `openai/gpt-4o-mini` | OpenRouter + OpenAI direct | Alternative provider examples for schema-aware metadata extraction. |
| `recipes/schema-aware-routing/index.ts` | 87, 91, 106 | `gpt-4o-mini`, `openai/gpt-4o-mini` | OpenRouter + OpenAI direct | Provider examples and commented extraction template; active extraction is a placeholder. |
| `recipes/source-filtering/backfill-metadata.ts` | 7, 75 | `gpt-4o-mini`, `openai/gpt-4o-mini` | OpenRouter | Backfill missing thought metadata. |
| `recipes/thought-enrichment/README.md` | 124 | `openai/gpt-4o-mini` | OpenRouter | Enrichment classifier model and cost guidance. |
| `recipes/thought-enrichment/enrich-thoughts.mjs` | 797 | `openai/gpt-4o-mini` | OpenRouter | Thought enrichment and classifier fallback model. |
| `recipes/vercel-neon-telegram/README.md` | 14, 33 | `gpt-4o-mini` | OpenAI direct | Telegram capture classification architecture description. |
| `recipes/vercel-neon-telegram/src/lib/ai.ts` | 17 | `gpt-4o-mini` | OpenAI direct | Capture metadata classification via the OpenAI SDK provider. |
| `recipes/weekly-digest/weekly-digest.mjs` | 499 | `openai/gpt-4o` | OpenRouter | Weekly digest synthesis; retiring ID appears only as a provider-format example, not the default. |

OB1 / Open Brain is a practical system from Nate B. Jones. Find more at [Nate's newsletter](https://substack.com/@natesnewsletter) and [natebjones.com](https://natebjones.com).

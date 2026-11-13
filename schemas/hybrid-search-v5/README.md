# Hybrid Search v5

```mermaid
flowchart LR
    Q[Query text + embedding] --> E[Eligible set: fixed exclusion X1-X4, then caller filter]
    E --> V[Vector leg: top pool by cosine, no threshold]
    E --> L[Lexical leg: simple + english full text]
    V --> F[Reciprocal rank fusion 1/(60+rank) per leg]
    L --> F
    F --> R[Bounded recency x0.85 to 1.00]
    R --> O[Top match_count]
```

## What it does

Adds `match_thoughts_v5`, a hybrid search function that finds exact tokens (issue keys, commit
prefixes, file names, version strings) that a pure embedding search can miss, and keeps close
paraphrases that a hard cosine threshold would drop. The existing `match_thoughts` and every caller of
it are untouched. The MCP server uses v5 only when `OB_SEARCH_VERSION=v5`.

This builds on Nate B. Jones's [Open Brain](../../docs/01-getting-started.md). More practical systems:
[Nate's newsletter](https://substack.com/@natesnewsletter) and [site](https://natebjones.com).

## What changes in the database (additive only)

| Object | Purpose |
| --- | --- |
| `thoughts.content_tsv` | generated, stored: `to_tsvector('simple', content) \|\| to_tsvector('english', content)` |
| `thoughts_content_tsv_idx` | GIN index on `content_tsv` (the only new index) |
| `thoughts_safe_date_v5(text)` | returns a date or NULL; a bad `last_verified` string never raises an error |
| `match_thoughts_v5(...)` | `SECURITY INVOKER`, `search_path = pg_catalog, public, extensions`, no dynamic SQL |

Nothing is dropped, renamed or rewritten. No `GRANT` or `REVOKE` statements are included, so the
function gets the same default privileges as the guide's `match_thoughts`. Because it is
`SECURITY INVOKER`, the caller still needs table access; compare `has_function_privilege` for both
functions after applying, and do not widen anything.

## The fixed exclusion

A row is excluded when ANY of these is true. The check is fail-closed: when in doubt, exclude.

| # | Condition |
| --- | --- |
| X1 | `metadata` is NULL or not a JSON object |
| X2 | a `sensitivity` key is present but is not a JSON string |
| X3 | `lower(btrim(metadata->>'sensitivity')) = 'restricted'` |
| X4 | the word `journal` appears anywhere in `lower(metadata::text)` (keys or values, any depth) |

A row with no `sensitivity` key, an object `metadata`, and no mention of the word is eligible.
The exclusion builds one eligible set, then applies the caller `filter` (containment) to it,
BEFORE either leg ranks, pools or fuses. An excluded row never takes a pool slot, a rank or a
score. No parameter and no `filter` value can turn the exclusion off. Over-exclusion (a row that
merely mentions the word) is accepted: that is the safe direction. This function is the only place
the exclusion lives; the server adds nothing, and `match_thoughts` is not changed.

## Search behavior

1. Vector leg: top `pool_size` (default 50) by cosine distance, with no threshold inside the pool.
2. Lexical leg: top `pool_size` by `ts_rank_cd` over `websearch_to_tsquery('simple', q) || websearch_to_tsquery('english', q)`. Empty query text means no lexical leg.
3. Fuse: `1/(60 + vector_rank) + 1/(60 + lexical_rank)`; a missing leg adds 0.
4. Recency (when `use_recency` is true): multiplier `0.85 + 0.15 * exp(-ln(2) * age_days / 90)`, age from `last_verified` (falling back to `created_at`). Rows that are rulings are exempt (`evidence_type = 'operator_ruling'`, `type = 'rule'`, a `subtype` matching `ruling|rule` (case-insensitive) without the pending-style words (also case-insensitive), or a ruling tag). References are not exempt.
5. Drop a row only when its cosine is under `match_threshold` AND it has no lexical hit.
6. `similarity` stays the cosine value. Order by final score, return `match_count`.

Known limit: like `match_thoughts`, the vector leg filters rows by `WHERE`, so a very selective
`filter` can return fewer than `pool_size` rows from an approximate index scan.

## Step-by-step

1. Test on an empty disposable database that has pgvector and the core `thoughts` table:

   ```sh
   psql "$TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f schemas/hybrid-search-v5/schema.sql
   psql "$TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f schemas/hybrid-search-v5/tests.sql
   cd server
   deno test --allow-env --no-lock --node-modules-dir=none search-version.test.ts
   ```

   `tests.sql` needs an EMPTY `thoughts` table and a `match_thoughts` function, uses only artificial
   rows, prints PASS or FAIL per test, and rolls back.
2. After independent review, apply `schema.sql` through your normal migration mechanism. It is safe to
   run more than once. Do not apply it by hand on a project you have not reviewed it for.
3. Turn it on by setting the server setting `OB_SEARCH_VERSION` to `v5`. Unset, empty, or any other
   value keeps v4. Tool inputs and output are unchanged.
4. Roll back by unsetting `OB_SEARCH_VERSION` (or setting it to `v4`). No data or schema change is needed.

## Not in scope

Re-embedding, a new embedding model, changing `match_thoughts`, changing capture, and the ChatGPT-shape
`search` tool (it stays on v4). The v4 function has no exclusion of its own; this build does not change that.

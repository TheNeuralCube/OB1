# ingest-thought (retired)

Retired on 2026-10-20 because it accepted unauthenticated writes without a key check, with JWT verification disabled. It was never used: there were no thoughts with source `api` or `slack`.

The deployed function now returns HTTP **410 Gone** with JSON `{"error":"gone"}` for every request. This stub preserves that behavior; it does not store thoughts.

Any rebuild must add a key check and Slack signature verification before accepting writes.

Part of Nate B. Jones's OB1 / Open Brain. Find practical systems at [Nate's newsletter](https://substack.com/@natesnewsletter) and [natebjones.com](https://natebjones.com).

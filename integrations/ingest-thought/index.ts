// ingest-thought: RETIRED 2026-10-20 by E0 at the operator's word.
// The previous version accepted unauthenticated writes (no key check, verify_jwt off).
// It was never used (no thoughts with source api or slack). Rebuild with a key check and
// Slack signature verification if Slack capture is ever wanted.
Deno.serve(() => new Response(JSON.stringify({ error: "gone" }), { status: 410, headers: { "Content-Type": "application/json" } }));

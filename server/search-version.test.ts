// Artificial transport tests for OB_SEARCH_VERSION. Never contacts a database or an external API.
// Run from server/: deno test --allow-env --no-lock --node-modules-dir=none search-version.test.ts
import { assert, assertEquals } from "jsr:@std/assert@1.0.14";
import { createClient } from "@supabase/supabase-js";

Deno.test("search_thoughts: OB_SEARCH_VERSION selects the RPC; default and unknown values stay on v4", async () => {
  const savedServe = Deno.serve;
  const savedFetch = globalThis.fetch;
  const envKeys = ["SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY", "OPENROUTER_API_KEY", "MCP_ACCESS_KEY"];
  const oldEnv = envKeys.map((k) => Deno.env.get(k));
  const oldFlag = Deno.env.get("OB_SEARCH_VERSION");
  let handler: (r: Request) => Response | Promise<Response>;
  const rpcs: { name: string; body: Record<string, unknown> }[] = [];
  const probe = createClient("http://artificial.invalid", "artificial-test-value", { auth: { autoRefreshToken: false, persistSession: false } });
  const proto = Object.getPrototypeOf(probe) as {
    _initSupabaseAuthClient: (...args: unknown[]) => { stopAutoRefresh(): Promise<void> };
  };
  const initAuth = proto._initSupabaseAuthClient;
  const authClients: { stopAutoRefresh(): Promise<void> }[] = [];
  proto._initSupabaseAuthClient = function (...args) {
    const auth = initAuth.apply(this, args);
    authClients.push(auth);
    return auth;
  };
  try {
    Deno.env.set("SUPABASE_URL", "http://artificial.invalid");
    for (const k of envKeys.slice(1)) Deno.env.set(k, "artificial-test-value");
    Deno.env.delete("OB_SEARCH_VERSION");
    Deno.serve = ((fn: typeof handler) => { handler = fn; return {}; }) as typeof Deno.serve;
    const row = {
      id: "artificial-id-1",
      content: "Artificial thought content",
      metadata: { type: "observation" },
      similarity: 0.9,
      created_at: "2026-01-01T00:00:00Z",
    };
    globalThis.fetch = async (input, init) => {
      const url = String(input);
      if (url === "https://openrouter.ai/api/v1/embeddings") {
        return Response.json({ data: [{ embedding: [0.1, 0.2] }] });
      }
      const m = url.match(/^http:\/\/artificial\.invalid\/rest\/v1\/rpc\/(match_thoughts(?:_v5)?)$/);
      assert(m, `unexpected URL ${url}`);
      rpcs.push({ name: m[1], body: JSON.parse(String(init?.body)) });
      return Response.json([row]);
    };
    await import("./index.ts");
    let id = 0;
    async function call(name: string, args: Record<string, unknown>) {
      const response = await handler(new Request("http://artificial.invalid/mcp", {
        method: "POST",
        headers: { "content-type": "application/json", "x-brain-key": "artificial-test-value" },
        body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method: "tools/call", params: { name, arguments: args } }),
      }));
      const body = await response.text();
      const data = body.startsWith("{") ? body : body.split("\n").find((l) => l.startsWith("data: "))?.slice(6);
      assert(data, body);
      return JSON.parse(data).result;
    }
    const args = { query: "ABC-123 sandbox", limit: 7, threshold: 0.6, filter: { project: "artificial" } };

    // Default (flag unset): v4 call, byte-for-byte the old argument set.
    const baseline = await call("search_thoughts", args);
    assertEquals(rpcs.length, 1);
    assertEquals(rpcs[0].name, "match_thoughts");
    assertEquals(rpcs[0].body, { query_embedding: [0.1, 0.2], match_threshold: 0.6, match_count: 7, filter: { project: "artificial" } });

    // Unknown and near-miss values stay on v4.
    for (const v of ["", "v4", "v6", "v5x", "5", "true"]) {
      Deno.env.set("OB_SEARCH_VERSION", v);
      await call("search_thoughts", args);
      assertEquals(rpcs.at(-1)!.name, "match_thoughts", `value ${JSON.stringify(v)}`);
    }

    // v5: same query text and embedding go to match_thoughts_v5; nothing else is added.
    Deno.env.set("OB_SEARCH_VERSION", "v5");
    const v5 = await call("search_thoughts", args);
    assertEquals(rpcs.at(-1)!.name, "match_thoughts_v5");
    assertEquals(rpcs.at(-1)!.body, {
      query_text: "ABC-123 sandbox",
      query_embedding: [0.1, 0.2],
      match_threshold: 0.6,
      match_count: 7,
      filter: { project: "artificial" },
    });
    // The caller's filter is passed through untouched; the exclusion lives only in the SQL.
    await call("search_thoughts", { query: "q", count: 3 });
    assertEquals(rpcs.at(-1)!.body.filter, {});
    assertEquals(rpcs.at(-1)!.body.match_count, 3);
    // Tool output shape is identical under v4 and v5 for the same rows.
    assertEquals(v5, baseline);

    // The ChatGPT-shape search tool stays on v4 even when the flag is v5.
    await call("search", { query: "anything" });
    assertEquals(rpcs.at(-1)!.name, "match_thoughts");
    assertEquals(rpcs.at(-1)!.body, { query_embedding: [0.1, 0.2], match_threshold: 0.5, match_count: 10, filter: {} });

    // Rollback: unsetting the flag returns to v4 with no other change.
    Deno.env.delete("OB_SEARCH_VERSION");
    await call("search_thoughts", args);
    assertEquals(rpcs.at(-1)!.name, "match_thoughts");
  } finally {
    for (const auth of authClients) await auth.stopAutoRefresh();
    proto._initSupabaseAuthClient = initAuth;
    Deno.serve = savedServe;
    globalThis.fetch = savedFetch;
    envKeys.forEach((k, i) => oldEnv[i] === undefined ? Deno.env.delete(k) : Deno.env.set(k, oldEnv[i]!));
    oldFlag === undefined ? Deno.env.delete("OB_SEARCH_VERSION") : Deno.env.set("OB_SEARCH_VERSION", oldFlag);
  }
});

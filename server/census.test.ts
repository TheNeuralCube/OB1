// Artificial transport tests. Never contacts a database or an external API.
// Run from server/: deno test --allow-env --no-lock --node-modules-dir=none census.test.ts
import { assert, assertEquals } from "jsr:@std/assert@1.0.14";
import { createClient } from "@supabase/supabase-js";

Deno.test("core census: auth, tool discovery, RPC arguments, results and errors", async () => {
  const savedServe = Deno.serve;
  const savedFetch = globalThis.fetch;
  const envKeys = ["SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY", "OPENROUTER_API_KEY", "MCP_ACCESS_KEY"];
  const oldEnv = envKeys.map((k) => Deno.env.get(k));
  let handler: (r: Request) => Response | Promise<Response>;
  let rpcCalls = 0;
  let responseMode = "ok";
  const calls: unknown[] = [];
  // Stop the real SDK's refresh timer on cleanup; keep leak sanitizers enabled.
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
    Deno.serve = ((fn: typeof handler) => { handler = fn; return {}; }) as typeof Deno.serve;
    globalThis.fetch = async (input, init) => {
      assertEquals(String(input), "http://artificial.invalid/rest/v1/rpc/thought_census");
      rpcCalls++;
      calls.push(JSON.parse(String(init?.body)));
      if (responseMode === "error") return Response.json({ message: "Artificial RPC rejection", code: "22023" }, { status: 400 });
      return Response.json({ key: "sensitivity", filter: {}, total: 1501, groups: { internal: 1500, "(none)": 1 } });
    };
    await import("./index.ts");
    let id = 0;
    async function rpc(method: string, params: unknown, auth = true) {
      const response = await handler(new Request("http://artificial.invalid/mcp", {
        method: "POST",
        headers: { "content-type": "application/json", ...(auth ? { "x-brain-key": "artificial-test-value" } : {}) },
        body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }),
      }));
      const body = await response.text();
      const data = body.startsWith("{") ? body : body.split("\n").find((l) => l.startsWith("data: "))?.slice(6);
      assert(data, body);
      return JSON.parse(data);
    }
    const denied = await rpc("tools/call", { name: "thought_census", arguments: { key: "sensitivity" } }, false);
    assertEquals(denied.error.code, -32001);
    assertEquals(rpcCalls, 0);
    const list = await rpc("tools/list", {});
    const names = list.result.tools.map((t: { name: string }) => t.name);
    for (const name of ["search", "fetch", "search_thoughts", "list_thoughts", "thought_stats", "capture_thought", "thought_census"]) assert(names.includes(name));
    assert(!names.includes("delete_thought") && !names.includes("update_thought"));
    assertEquals(list.result.tools.find((t: {name: string}) => t.name === "thought_census").annotations.readOnlyHint, true);
    const ok = await rpc("tools/call", { name: "thought_census", arguments: { key: "sensitivity" } });
    assertEquals(JSON.parse(ok.result.content[0].text).total, 1501);
    assertEquals(calls[0], { p_key: "sensitivity", p_filter: {} });
    await rpc("tools/call", { name: "thought_census", arguments: { key: "x'; SELECT 1; --", filter: { nested: { a: 1 } } } });
    assertEquals(calls[1], { p_key: "x'; SELECT 1; --", p_filter: { nested: { a: 1 } } });
    const before = rpcCalls;
    const invalid = await rpc("tools/call", { name: "thought_census", arguments: { key: "sensitivity", filter: [] } });
    assert(invalid.error || invalid.result?.isError);
    assertEquals(rpcCalls, before);
    responseMode = "error";
    const error = await rpc("tools/call", { name: "thought_census", arguments: { key: "sensitivity" } });
    assertEquals(error.result.isError, true);
    assertEquals(error.result.content[0].text, "thought_census error: Artificial RPC rejection");
  } finally {
    for (const auth of authClients) await auth.stopAutoRefresh();
    proto._initSupabaseAuthClient = initAuth;
    Deno.serve = savedServe;
    globalThis.fetch = savedFetch;
    envKeys.forEach((k, i) => oldEnv[i] === undefined ? Deno.env.delete(k) : Deno.env.set(k, oldEnv[i]!));
  }
});

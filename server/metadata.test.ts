import { extractMetadata } from "./metadata.ts";

function assertEquals(actual: unknown, expected: unknown) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}

Deno.test("metadata extraction: stubbed success and all failure reasons", async (t) => {
  const savedFetch = globalThis.fetch;
  const savedError = console.error;
  const logs: string[] = [];
  console.error = (...args: unknown[]) => {
    logs.push(args.join(" "));
  };
  const fallback = (reason: string) => ({
    type: "observation",
    topic: "uncategorized",
    people: [],
    tags: [],
    extraction_failed: true,
    extraction_error: reason,
  });
  const key = "artificial-test-value";
  try {
    await t.step(
      "http 429: bounded body logging and key redaction",
      async () => {
        globalThis.fetch = () =>
          Promise.resolve(new Response(key + "x".repeat(300), { status: 429 }));
        assertEquals(
          await extractMetadata("Artificial thought", key),
          fallback("http 429"),
        );
        assertEquals(logs, [
          `OpenRouter metadata extraction failed: 429 ${
            ("[redacted]" + "x".repeat(300)).slice(0, 200)
          }`,
        ]);
      },
    );
    await t.step(
      "no choices: missing, empty, null or missing content",
      async () => {
        for (
          const body of [{}, { choices: [] }, null, {
            choices: [{ message: {} }],
          }]
        ) {
          globalThis.fetch = () => Promise.resolve(Response.json(body));
          assertEquals(
            await extractMetadata("Artificial thought", key),
            fallback("no choices"),
          );
        }
      },
    );
    await t.step(
      "bad json: invalid response, invalid content and non-object content",
      async () => {
        globalThis.fetch = () => Promise.resolve(new Response("invalid json"));
        assertEquals(
          await extractMetadata("Artificial thought", key),
          fallback("bad json"),
        );
        for (const content of ["invalid json", "null", "[]", "42"]) {
          globalThis.fetch = () =>
            Promise.resolve(
              Response.json({ choices: [{ message: { content } }] }),
            );
          assertEquals(
            await extractMetadata("Artificial thought", key),
            fallback("bad json"),
          );
        }
      },
    );
    await t.step(
      "fetch error: thrown fetch does not leak exception details",
      async () => {
        globalThis.fetch = () =>
          Promise.reject(new Error("Artificial request failure"));
        assertEquals(
          await extractMetadata("Artificial thought", key),
          fallback("fetch error"),
        );
        assertEquals(logs.length, 1);
      },
    );
    await t.step("success preserves extracted metadata", async () => {
      const metadata = {
        type: "idea",
        topic: "Test coverage",
        tags: ["testing"],
      };
      globalThis.fetch = (_input, init) => {
        const request = JSON.parse(String(init?.body));
        assertEquals(request.model, "openai/gpt-6-luna");
        assertEquals(request.messages[1].content, "Artificial thought");
        return Promise.resolve(
          Response.json({
            choices: [{ message: { content: JSON.stringify(metadata) } }],
          }),
        );
      };
      assertEquals(await extractMetadata("Artificial thought", key), metadata);
    });
  } finally {
    globalThis.fetch = savedFetch;
    console.error = savedError;
  }
});

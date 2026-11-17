// Metadata failures are evidence on the saved thought, not capture failures.
export async function extractMetadata(
  text: string,
  apiKey: string,
): Promise<Record<string, unknown>> {
  const fallback = (reason: string) => ({
    type: "observation",
    topic: "uncategorized",
    people: [],
    tags: [],
    extraction_failed: true,
    extraction_error: reason,
  });
  let r: Response;
  try {
    r = await fetch("https://openrouter.ai/api/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "openai/gpt-6-luna",
        response_format: { type: "json_object" },
        messages: [
          {
            role: "system",
            // B5: original vocabulary, kept for continuity with the existing corpus.
            content:
              `Extract metadata from the user's captured thought. Return JSON with:
- "type": one of "idea", "decision", "reference", "personal", "task", "observation"
- "topic": a concise topic label (2-5 words)
- "people": array of people mentioned (empty array if none)
- "tags": array of 2-5 relevant keyword tags
- "action_items": array of implied to-dos (empty if none)
Only extract what's explicitly there.`,
          },
          { role: "user", content: text },
        ],
      }),
    });
  } catch {
    return fallback("fetch error");
  }
  if (!r.ok) {
    const body = await r.text().catch(() => "");
    const safeBody = apiKey ? body.split(apiKey).join("[redacted]") : body;
    console.error(
      `OpenRouter metadata extraction failed: ${r.status} ${
        safeBody.slice(0, 200)
      }`,
    );
    return fallback(`http ${r.status}`);
  }
  try {
    const d = await r.json();
    if (!d?.choices?.[0]?.message?.content) return fallback("no choices");
    const metadata = JSON.parse(d.choices[0].message.content);
    if (!metadata || typeof metadata !== "object" || Array.isArray(metadata)) {
      return fallback("bad json");
    }
    return metadata;
  } catch {
    return fallback("bad json");
  }
}

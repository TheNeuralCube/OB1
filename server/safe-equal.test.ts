import { safeEqual as serverSafeEqual } from "./safe-equal.ts";
import { safeEqual as updateSafeEqual } from "../integrations/update-thought-mcp/safe-equal.ts";

for (
  const [name, safeEqual] of [
    ["server", serverSafeEqual],
    ["update-thought-mcp", updateSafeEqual],
  ] as const
) {
  Deno.test(`${name}: safeEqual`, async (t) => {
    const cases: [
      string,
      string | null | undefined,
      string | null | undefined,
      boolean,
    ][] = [
      ["equal", "artificial-key", "artificial-key", true],
      ["unequal", "artificial-key", "artificial-keY", false],
      ["different lengths", "artificial-key", "artificial-key-longer", false],
      [
        "different lengths reversed",
        "artificial-key-longer",
        "artificial-key",
        false,
      ],
      ["empty input", "", "artificial-key", false],
      ["empty key", "artificial-key", "", false],
      ["both empty", "", "", false],
      ["unset key", "artificial-key", undefined, false],
      ["unset input", undefined, "artificial-key", false],
      ["missing header", null, "artificial-key", false],
      ["both unset", undefined, undefined, false],
      ["unicode equal", "人工-test", "人工-test", true],
      ["unicode unequal", "人工-test", "人-test", false],
    ];
    for (const [label, a, b, expected] of cases) {
      await t.step(label, async () => {
        const actual = await safeEqual(a, b);
        if (actual !== expected) {
          throw new Error(`Expected ${expected}, got ${actual}`);
        }
      });
    }
  });
}

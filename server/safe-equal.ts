// Hash first so the comparison always visits the same 32 digest bytes.
export async function safeEqual(
  a: string | null | undefined,
  b: string | null | undefined,
): Promise<boolean> {
  if (!a || !b) return false;
  const encoder = new TextEncoder();
  const [left, right] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(a)),
    crypto.subtle.digest("SHA-256", encoder.encode(b)),
  ]);
  const leftBytes = new Uint8Array(left);
  const rightBytes = new Uint8Array(right);
  let difference = 0;
  for (let i = 0; i < leftBytes.length; i++) {
    difference |= leftBytes[i] ^ rightBytes[i];
  }
  return difference === 0;
}

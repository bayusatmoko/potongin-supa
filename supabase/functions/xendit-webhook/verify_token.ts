// Constant-time comparison so a timing attack can't be used to guess the
// webhook token byte-by-byte from response latency.
export function isValidCallbackToken(received: string | null, expected: string): boolean {
  if (!received) return false;
  const receivedBytes = new TextEncoder().encode(received);
  const expectedBytes = new TextEncoder().encode(expected);
  if (receivedBytes.length !== expectedBytes.length) return false;

  let diff = 0;
  for (let i = 0; i < receivedBytes.length; i++) {
    diff |= receivedBytes[i] ^ expectedBytes[i];
  }
  return diff === 0;
}

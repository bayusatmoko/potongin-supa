import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { extractQrDetails } from "./extract_qr_details.ts";

Deno.test("extracts from the actions[]/PRESENT_TO_CUSTOMER shape", () => {
  const body = {
    payment_request_id: "pr-abc123",
    actions: [{ type: "PRESENT_TO_CUSTOMER", descriptor: "QR_STRING", value: "00020101..." }],
    channel_properties: { expires_at: "2026-08-22T10:00:00Z" },
  };
  assertEquals(extractQrDetails(body), {
    qrString: "00020101...",
    paymentRequestId: "pr-abc123",
    expiresAt: "2026-08-22T10:00:00Z",
  });
});

Deno.test("extracts from the paymentMethod.qrCode nested shape", () => {
  const body = {
    id: "pr-xyz789",
    paymentMethod: { qrCode: { qrString: "00020101..." } },
    channelProperties: { expiresAt: "2026-08-22T10:05:00Z" },
  };
  assertEquals(extractQrDetails(body), {
    qrString: "00020101...",
    paymentRequestId: "pr-xyz789",
    expiresAt: "2026-08-22T10:05:00Z",
  });
});

Deno.test("returns nulls when no known shape matches", () => {
  const body = { unexpected: true };
  assertEquals(extractQrDetails(body), { qrString: null, paymentRequestId: null, expiresAt: null });
});

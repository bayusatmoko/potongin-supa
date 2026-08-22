import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { buildPaymentRequestPayload } from "./build_payment_request.ts";

Deno.test("builds the flat PAY-type QRIS payload Xendit's real sandbox accepts", () => {
  const payload = buildPaymentRequestPayload("tx-abc123", 25000);
  assertEquals(payload, {
    reference_id: "tx-abc123",
    type: "PAY",
    country: "ID",
    currency: "IDR",
    request_amount: 25000,
    capture_method: "AUTOMATIC",
    channel_code: "QRIS",
  });
});

Deno.test("does not nest channel_code under a payment_method/qr_code wrapper", () => {
  const payload = buildPaymentRequestPayload("tx-def456", 15000) as unknown as Record<string, unknown>;
  assertEquals(payload.payment_method, undefined);
  assertEquals(payload.channel_code, "QRIS");
});

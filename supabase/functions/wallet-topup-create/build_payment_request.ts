export interface PaymentRequestPayload {
  reference_id: string;
  type: "PAY";
  country: "ID";
  currency: "IDR";
  request_amount: number;
  capture_method: "AUTOMATIC";
  channel_code: "QRIS";
}

// Confirmed against Xendit's real sandbox for api-version 2024-11-11 (found via
// the Task 8 smoke test): POST /v3/payment_requests rejects the
// payment_method.{type}.qr_code.channel_code nested-wrapper shape documented by
// some Xendit SDKs/docs, with "Either channel_code or payment_token_id is
// required". The flat shape below (channel_code as a top-level sibling of
// type/country/currency/request_amount) is what this account's sandbox
// actually accepts and returns 201 for. See
// docs/superpowers/specs/2026-08-22-supabase-backend-design.md.
export function buildPaymentRequestPayload(referenceId: string, amountCents: number): PaymentRequestPayload {
  return {
    reference_id: referenceId,
    type: "PAY",
    country: "ID",
    currency: "IDR",
    request_amount: amountCents,
    capture_method: "AUTOMATIC",
    channel_code: "QRIS",
  };
}

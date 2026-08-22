import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { parseTopupEvent } from "./parse_event.ts";

Deno.test("parses a succeeded event, snake_case data shape", () => {
  const body = { event: "payment_request.succeeded", data: { id: "pr-1", reference_id: "tx-1", status: "SUCCEEDED" } };
  assertEquals(parseTopupEvent(body), { referenceId: "tx-1", paymentRequestId: "pr-1", outcome: "succeeded" });
});

Deno.test("parses a succeeded event, camelCase data shape", () => {
  const body = { event: "payment_request.succeeded", data: { id: "pr-2", referenceId: "tx-2", status: "SUCCEEDED" } };
  assertEquals(parseTopupEvent(body), { referenceId: "tx-2", paymentRequestId: "pr-2", outcome: "succeeded" });
});

Deno.test("parses an expired event", () => {
  const body = { event: "payment_request.expired", data: { id: "pr-3", reference_id: "tx-3", status: "EXPIRED" } };
  assertEquals(parseTopupEvent(body), { referenceId: "tx-3", paymentRequestId: "pr-3", outcome: "expired" });
});

Deno.test("ignores an unrecognized event", () => {
  const body = { event: "something.else", data: { id: "pr-4", reference_id: "tx-4", status: "PENDING" } };
  assertEquals(parseTopupEvent(body), { referenceId: "tx-4", paymentRequestId: "pr-4", outcome: "ignored" });
});

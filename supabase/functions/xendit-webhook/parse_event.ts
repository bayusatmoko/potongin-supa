export type TopupOutcome = "succeeded" | "expired" | "failed" | "ignored";

export interface ParsedTopupEvent {
  referenceId: string | null;
  paymentRequestId: string | null;
  outcome: TopupOutcome;
}

export function parseTopupEvent(body: unknown): ParsedTopupEvent {
  const root = body as Record<string, unknown>;
  const eventName = typeof root.event === "string" ? root.event : "";
  const data = (root.data ?? root) as Record<string, unknown>;

  const referenceId = (data.referenceId as string | undefined) ?? (data.reference_id as string | undefined) ?? null;
  const paymentRequestId = (data.id as string | undefined) ?? (data.payment_request_id as string | undefined) ?? null;
  const status = typeof data.status === "string" ? data.status : "";

  let outcome: TopupOutcome = "ignored";
  if (eventName.includes("succeeded") || status === "SUCCEEDED") outcome = "succeeded";
  else if (eventName.includes("expired") || status === "EXPIRED") outcome = "expired";
  else if (eventName.includes("failed") || status === "FAILED") outcome = "failed";

  return { referenceId, paymentRequestId, outcome };
}

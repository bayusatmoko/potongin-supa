export type TopupOutcome = "succeeded" | "expired" | "failed" | "ignored";

export interface ParsedTopupEvent {
  referenceId: string | null;
  paymentRequestId: string | null;
  outcome: TopupOutcome;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

export function parseTopupEvent(body: unknown): ParsedTopupEvent {
  const root = isObject(body) ? body : {};
  const eventName = typeof root.event === "string" ? root.event : "";
  const data = isObject(root.data) ? root.data : root;

  const referenceId = (data.referenceId as string | undefined) ?? (data.reference_id as string | undefined) ?? null;
  const paymentRequestId = (data.id as string | undefined) ?? (data.payment_request_id as string | undefined) ?? null;
  const status = typeof data.status === "string" ? data.status : "";

  let outcome: TopupOutcome = "ignored";
  if (eventName.includes("succeeded") || status === "SUCCEEDED") outcome = "succeeded";
  else if (eventName.includes("expired") || status === "EXPIRED") outcome = "expired";
  else if (eventName.includes("failed") || status === "FAILED") outcome = "failed";

  return { referenceId, paymentRequestId, outcome };
}

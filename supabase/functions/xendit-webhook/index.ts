import { createClient } from "npm:@supabase/supabase-js@2";
import { isValidCallbackToken } from "./verify_token.ts";
import { parseTopupEvent } from "./parse_event.ts";

const XENDIT_WEBHOOK_TOKEN = Deno.env.get("XENDIT_WEBHOOK_TOKEN")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("method not allowed", { status: 405 });
  }

  const token = req.headers.get("x-callback-token");
  if (!isValidCallbackToken(token, XENDIT_WEBHOOK_TOKEN)) {
    return new Response("invalid token", { status: 401 });
  }

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return new Response("invalid JSON", { status: 400 });
  }

  const event = parseTopupEvent(body);
  const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  if (!event.referenceId) {
    return new Response(JSON.stringify({ received: true, note: "no reference_id, ignored" }), { status: 200 });
  }

  const { error: rawResponseError } = await adminClient
    .from("wallet_transactions")
    .update({ xendit_raw_response: body })
    .eq("id", event.referenceId);
  if (rawResponseError) {
    console.error("failed to persist raw webhook payload", event.referenceId, rawResponseError);
  }

  if (event.outcome === "succeeded") {
    const { error } = await adminClient.rpc("fn_credit_topup", { p_transaction_id: event.referenceId });
    if (error) {
      console.error("fn_credit_topup failed", error);
      return new Response("internal error", { status: 500 });
    }
  } else if (event.outcome === "expired" || event.outcome === "failed") {
    const { error: statusUpdateError } = await adminClient
      .from("wallet_transactions")
      .update({ status: event.outcome })
      .eq("id", event.referenceId)
      .eq("status", "pending");
    if (statusUpdateError) {
      console.error("failed to mark wallet_transactions row", event.outcome, event.referenceId, statusUpdateError);
    }
  }

  return new Response(JSON.stringify({ received: true }), { status: 200 });
});

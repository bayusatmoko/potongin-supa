import { createClient } from "npm:@supabase/supabase-js@2";
import { extractQrDetails } from "./extract_qr_details.ts";
import { buildPaymentRequestPayload } from "./build_payment_request.ts";

const XENDIT_SECRET_KEY = Deno.env.get("XENDIT_SECRET_KEY")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

interface TopupRequestBody {
  amount_cents: number;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "method not allowed" }), { status: 405 });
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });

  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData.user) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401 });
  }
  const barberId = userData.user.id;

  let body: TopupRequestBody;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "invalid JSON body" }), { status: 400 });
  }
  if (!Number.isInteger(body.amount_cents) || body.amount_cents <= 0) {
    return new Response(JSON.stringify({ error: "amount_cents must be a positive integer" }), { status: 400 });
  }

  const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  const { data: barber, error: barberError } = await adminClient
    .from("barbers")
    .select("id")
    .eq("id", barberId)
    .maybeSingle();
  if (barberError || !barber) {
    return new Response(JSON.stringify({ error: "caller is not a registered barber" }), { status: 403 });
  }

  const { data: tx, error: txError } = await adminClient
    .from("wallet_transactions")
    .insert({ barber_id: barberId, type: "topup", amount_cents: body.amount_cents, status: "pending" })
    .select("id")
    .single();
  if (txError || !tx) {
    return new Response(JSON.stringify({ error: "could not start top-up" }), { status: 500 });
  }

  let xenditResponse: Response;
  let xenditBody: unknown;
  try {
    xenditResponse = await fetch("https://api.xendit.co/v3/payment_requests", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "api-version": "2024-11-11",
        Authorization: `Basic ${btoa(`${XENDIT_SECRET_KEY}:`)}`,
      },
      body: JSON.stringify(buildPaymentRequestPayload(tx.id, body.amount_cents)),
    });
    xenditBody = await xenditResponse.json();
  } catch (err) {
    const { error: markFailedError } = await adminClient
      .from("wallet_transactions")
      .update({ status: "failed" })
      .eq("id", tx.id);
    if (markFailedError) {
      console.error("failed to mark wallet_transactions row failed after xendit call error", tx.id, markFailedError, err);
    }
    return new Response(JSON.stringify({ error: "could not reach xendit, try again" }), { status: 502 });
  }

  if (!xenditResponse.ok) {
    const { error: updateError } = await adminClient
      .from("wallet_transactions")
      .update({ status: "failed", xendit_raw_response: xenditBody })
      .eq("id", tx.id);
    if (updateError) {
      console.error("failed to persist xendit failure response", tx.id, updateError);
    }
    return new Response(JSON.stringify({ error: "xendit rejected the top-up request" }), { status: 502 });
  }

  const { qrString, paymentRequestId, expiresAt } = extractQrDetails(xenditBody);

  const { error: updateError } = await adminClient
    .from("wallet_transactions")
    .update({
      xendit_payment_request_id: paymentRequestId,
      xendit_qr_string: qrString,
      expires_at: expiresAt,
      xendit_raw_response: xenditBody,
    })
    .eq("id", tx.id);
  if (updateError) {
    console.error("failed to persist xendit success response", tx.id, updateError);
  }

  if (!qrString || !paymentRequestId) {
    return new Response(JSON.stringify({ error: "top-up created but QR code was not returned, try again" }), { status: 502 });
  }

  return new Response(
    JSON.stringify({ transaction_id: tx.id, qr_string: qrString, expires_at: expiresAt }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
});

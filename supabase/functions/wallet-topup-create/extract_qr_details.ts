interface ExtractedQrDetails {
  qrString: string | null;
  paymentRequestId: string | null;
  expiresAt: string | null;
}

// Xendit's own docs disagree with each other on the Payment Requests response
// shape across product generations, so this tries every documented path
// rather than trusting one. See docs/superpowers/specs/2026-08-22-supabase-backend-design.md.
export function extractQrDetails(xenditBody: unknown): ExtractedQrDetails {
  const body = xenditBody as Record<string, unknown>;

  const actions = Array.isArray(body.actions) ? body.actions as Array<Record<string, unknown>> : [];
  const presentAction = actions.find((a) => a.type === "PRESENT_TO_CUSTOMER");
  const paymentMethod = body.paymentMethod as Record<string, unknown> | undefined;
  const qrCode = paymentMethod?.qrCode as Record<string, unknown> | undefined;

  const qrString =
    (presentAction?.value as string | undefined) ??
    (qrCode?.qrString as string | undefined) ??
    (body.qr_string as string | undefined) ??
    null;

  const paymentRequestId =
    (body.id as string | undefined) ??
    (body.payment_request_id as string | undefined) ??
    null;

  const channelPropertiesCamel = body.channelProperties as Record<string, unknown> | undefined;
  const channelPropertiesSnake = body.channel_properties as Record<string, unknown> | undefined;

  const expiresAt =
    (channelPropertiesCamel?.expiresAt as string | undefined) ??
    (channelPropertiesSnake?.expires_at as string | undefined) ??
    null;

  return { qrString, paymentRequestId, expiresAt };
}

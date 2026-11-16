import { createClient } from "npm:@supabase/supabase-js@2";
// Settlement: customer money is collected into the platform (admin) merchant account.
// The company's share (payments.base_amount) is then paid out to the company's merchant number.
// The admin share (commission) simply stays in the collection account.
// Disbursement only runs when DISBURSEMENT_ENABLED=true and provider disbursement secrets exist.
// Anything that cannot be sent automatically stays 'pending' so the admin can pay it manually.
const digitsOf = (v: string) => {
  const d = String(v || "").replace(/\D/g, "");
  return d.startsWith("256") ? d : d.startsWith("0") ? `256${d.slice(1)}` : d;
};

async function mtnTransfer(amount: number, msisdn: string, ref: string) {
  const base = Deno.env.get("MTN_BASE_URL") || "https://sandbox.momodeveloper.mtn.com";
  const subKey = Deno.env.get("MTN_DISBURSEMENT_SUBSCRIPTION_KEY");
  const apiUser = Deno.env.get("MTN_DISBURSEMENT_API_USER");
  const apiKey = Deno.env.get("MTN_DISBURSEMENT_API_KEY");
  if (!subKey || !apiUser || !apiKey) throw new Error("MTN disbursement secrets are not configured");
  const env = Deno.env.get("MTN_TARGET_ENVIRONMENT") || "sandbox";
  const tokenRes = await fetch(`${base}/disbursement/token/`, {
    method: "POST",
    headers: { Authorization: `Basic ${btoa(`${apiUser}:${apiKey}`)}`, "Ocp-Apim-Subscription-Key": subKey },
  });
  if (!tokenRes.ok) throw new Error(`MTN disbursement token failed: ${tokenRes.status}`);
  const token = (await tokenRes.json()).access_token;
  const res = await fetch(`${base}/disbursement/v1_0/transfer`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`, "X-Reference-Id": ref, "X-Target-Environment": env,
      "Ocp-Apim-Subscription-Key": subKey, "Content-Type": "application/json",
    },
    body: JSON.stringify({
      amount: String(amount), currency: Deno.env.get("MTN_CURRENCY") || "EUR", externalId: ref,
      payee: { partyIdType: "MSISDN", partyId: msisdn }, payerMessage: "Daily Travel ticket sale", payeeNote: "Daily Travel payout",
    }),
  });
  if (res.status !== 202) throw new Error(`MTN transfer failed: ${res.status} ${await res.text()}`);
}

export async function settlePayment(admin: any, paymentId: string) {
  try {
    const { data: p } = await admin.from("payments").select("*").eq("id", paymentId).maybeSingle();
    if (!p || p.status !== "successful" || p.settlement_status === "settled") return;
    if (Deno.env.get("DISBURSEMENT_ENABLED") !== "true") return; // stays 'pending' for manual payout
    const { data: c } = await admin.from("bus_companies").select("merchant_mtn_code, merchant_airtel_code").eq("id", p.company_id).maybeSingle();
    const amount = Number(p.base_amount || 0);
    if (!c || amount <= 0) return;
    const wantsAirtel = p.payment_method === "airtel_money";
    const target = wantsAirtel ? c.merchant_airtel_code : c.merchant_mtn_code;
    if (wantsAirtel || !target) {
      // Airtel payouts need an encrypted PIN flow and merchant codes are not phone numbers: leave for manual payout.
      await admin.from("payments").update({ settlement_status: "manual_required" }).eq("id", p.id);
      return;
    }
    const ref = crypto.randomUUID();
    await mtnTransfer(amount, digitsOf(target), ref);
    await admin.from("payments").update({ settlement_status: "settled", settled_at: new Date().toISOString(), settlement_reference: ref }).eq("id", p.id);
  } catch (e) {
    console.error("settlement", e);
    await admin.from("payments").update({ settlement_status: "failed" }).eq("id", paymentId).catch(() => undefined);
  }
}


const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-payment-webhook-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
}
function secretKey() {
  const direct = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (direct) return direct;
  try { return JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") || "{}").default; } catch { return undefined; }
}
function normalize(body: any) {
  const status = String(body?.status || body?.transaction?.status || body?.data?.status || body?.result?.status || "").toUpperCase();
  const reference = body?.provider_reference || body?.externalId || body?.external_id || body?.transaction?.id || body?.data?.id || body?.reference;
  const success = ["SUCCESSFUL", "SUCCESS", "COMPLETED", "SUCCESSFUL_PAYMENT"].includes(status);
  const failure = ["FAILED", "FAILURE", "REJECTED", "CANCELLED", "EXPIRED"].includes(status);
  return { reference, status, success, failure };
}
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "POST required" }, 405);
  // Fail closed: without a configured secret nobody can mark a payment as paid.
  // Providers that cannot send custom headers (e.g. MTN) can append ?secret=... to the callback URL.
  const configuredSecret = Deno.env.get("PAYMENT_WEBHOOK_SECRET");
  if (!configuredSecret) return json({ error: "Webhook is not configured" }, 503);
  const suppliedSecret = req.headers.get("x-payment-webhook-secret") ?? new URL(req.url).searchParams.get("secret");
  if (suppliedSecret !== configuredSecret) return json({ error: "Invalid webhook secret" }, 401);
  try {
    const body = await req.json();
    const normalized = normalize(body);
    if (!normalized.reference || (!normalized.success && !normalized.failure)) return json({ received: true, ignored: true });
    const url = Deno.env.get("SUPABASE_URL"); const key = secretKey();
    if (!url || !key) return json({ error: "Supabase server secrets are not configured" }, 500);
    const admin = createClient(url, key);
    const { data: payment, error } = await admin.from("payments").select("id").eq("provider_reference", normalized.reference).maybeSingle();
    if (error || !payment) return json({ received: true, ignored: true });
    const { data, error: finalizeError } = await admin.rpc("finalize_payment", {
      p_payment_id: payment.id,
      p_success: normalized.success,
      p_provider_reference: normalized.reference,
      p_provider_status: normalized.status,
    });
    if (finalizeError) return json({ error: finalizeError.message }, 500);
    if (normalized.success) await settlePayment(admin, payment.id);
    return json({ received: true, status: normalized.success ? "successful" : "failed", result: data });
  } catch (error) {
    console.error(error);
    return json({ error: "Invalid webhook payload" }, 400);
  }
});

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
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
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
function publicKey() { return Deno.env.get("SUPABASE_PUBLISHABLE_KEY") || Deno.env.get("SUPABASE_ANON_KEY"); }
async function requireUser(req: Request) {
  const token = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "");
  const url = Deno.env.get("SUPABASE_URL"); const key = publicKey();
  if (!token || !url || !key) return null;
  const client = createClient(url, key, { global: { headers: { Authorization: `Bearer ${token}` } } });
  return (await client.auth.getUser(token)).data.user || null;
}
function paymentState(provider: string, body: any) {
  const raw = String(body?.status || body?.transaction?.status || body?.data?.status || body?.result?.status || "").toUpperCase();
  if (["SUCCESSFUL", "SUCCESS", "COMPLETED", "SUCCESSFUL_PAYMENT"].includes(raw)) return "successful";
  if (["FAILED", "FAILURE", "REJECTED", "CANCELLED", "EXPIRED"].includes(raw)) return "failed";
  return "processing";
}
async function providerStatus(payment: any) {
  const provider = payment.payment_method === "airtel_money" ? "airtel_money" : "mtn_momo";
  if (provider === "mtn_momo") {
    const base = Deno.env.get("MTN_BASE_URL") || "https://sandbox.momodeveloper.mtn.com";
    const subscriptionKey = Deno.env.get("MTN_COLLECTION_SUBSCRIPTION_KEY");
    const apiUser = Deno.env.get("MTN_API_USER"); const apiKey = Deno.env.get("MTN_API_KEY");
    const target = Deno.env.get("MTN_TARGET_ENVIRONMENT") || "sandbox";
    if (!subscriptionKey || !apiUser || !apiKey) throw new Error("MTN payment secrets are not configured");
    const tokenResponse = await fetch(`${base}/collection/token/`, {
      method: "POST",
      headers: { Authorization: `Basic ${btoa(`${apiUser}:${apiKey}`)}`, "Ocp-Apim-Subscription-Key": subscriptionKey, "Content-Type": "application/x-www-form-urlencoded" },
      body: "grant_type=client_credentials",
    });
    if (!tokenResponse.ok) throw new Error(`MTN token request failed: ${tokenResponse.status}`);
    const token = (await tokenResponse.json()).access_token;
    const response = await fetch(`${base}/collection/v1_0/requesttopay/${payment.provider_reference}`, {
      headers: { Authorization: `Bearer ${token}`, "X-Target-Environment": target, "Ocp-Apim-Subscription-Key": subscriptionKey },
    });
    if (!response.ok) throw new Error(`MTN status request failed: ${response.status}`);
    return await response.json();
  }
  const base = Deno.env.get("AIRTEL_BASE_URL") || "https://openapi.airtel.africa";
  const clientId = Deno.env.get("AIRTEL_CLIENT_ID"); const clientSecret = Deno.env.get("AIRTEL_CLIENT_SECRET");
  if (!clientId || !clientSecret) throw new Error("Airtel payment secrets are not configured");
  const tokenResponse = await fetch(`${base}/auth/oauth2/token`, {
    method: "POST",
    headers: { Authorization: `Basic ${btoa(`${clientId}:${clientSecret}`)}`, "Content-Type": "application/x-www-form-urlencoded" },
    body: "grant_type=client_credentials",
  });
  if (!tokenResponse.ok) throw new Error(`Airtel token request failed: ${tokenResponse.status}`);
  const token = (await tokenResponse.json()).access_token;
  const response = await fetch(`${base}${Deno.env.get("AIRTEL_PAYMENT_STATUS_PATH") || "/standard/v1/payments/"}${payment.provider_reference}`, {
    headers: { Authorization: `Bearer ${token}`, "X-Country": Deno.env.get("AIRTEL_COUNTRY") || "UG", "X-Currency": payment.currency || "UGX" },
  });
  if (!response.ok) throw new Error(`Airtel status request failed: ${response.status}`);
  return await response.json();
}
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "POST required" }, 405);
  try {
    const user = await requireUser(req);
    if (!user) return json({ error: "Authentication required" }, 401);
    const { payment_id: paymentId } = await req.json();
    if (!paymentId) return json({ error: "payment_id is required" }, 400);
    const url = Deno.env.get("SUPABASE_URL"); const key = secretKey();
    if (!url || !key) return json({ error: "Supabase server secrets are not configured" }, 500);
    const admin = createClient(url, key);
    const { data: payment, error } = await admin.from("payments").select("*").eq("id", paymentId).single();
    if (error || !payment) return json({ error: "Payment not found" }, 404);
    const { data: profile } = await admin.from("users").select("role").eq("id", user.id).maybeSingle();
    if (payment.customer_id !== user.id && profile?.role !== "admin") return json({ error: "Not allowed" }, 403);
    if (["successful", "failed", "refunded"].includes(payment.status)) return json({ status: payment.status, payment });
    if (payment.payment_method === "bank") return json({ status: payment.status, provider_status: "AWAITING_BANK_TRANSFER" }); // admin confirms bank transfers
    const providerBody = await providerStatus(payment);
    const state = paymentState(payment.payment_method, providerBody);
    const providerStatusValue = String(providerBody?.status || providerBody?.transaction?.status || providerBody?.data?.status || "PENDING");
    if (state === "successful" || state === "failed") {
      const { data: finalized, error: finalizeError } = await admin.rpc("finalize_payment", {
        p_payment_id: payment.id,
        p_success: state === "successful",
        p_provider_reference: payment.provider_reference,
        p_provider_status: providerStatusValue,
      });
      if (finalizeError) return json({ error: finalizeError.message }, 500);
      if (state === "successful") await settlePayment(admin, payment.id);
      return json({ status: state, provider_status: providerStatusValue, result: finalized });
    }
    await admin.from("payments").update({ status: "processing", provider_status: providerStatusValue }).eq("id", payment.id);
    return json({ status: "processing", provider_status: providerStatusValue });
  } catch (error) {
    console.error(error);
    return json({ error: error instanceof Error ? error.message : "Payment status failed" }, 502);
  }
});

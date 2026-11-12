import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function secretKey() {
  const direct = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (direct) return direct;
  try {
    return JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") || "{}").default;
  } catch {
    return undefined;
  }
}

function publicKey() {
  return Deno.env.get("SUPABASE_PUBLISHABLE_KEY") || Deno.env.get("SUPABASE_ANON_KEY");
}

function phoneDigits(value: string) {
  const digits = String(value || "").replace(/\D/g, "");
  if (digits.startsWith("256")) return digits;
  if (digits.startsWith("0")) return `256${digits.slice(1)}`;
  return digits;
}

async function requireUser(req: Request) {
  const token = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "");
  const url = Deno.env.get("SUPABASE_URL");
  const key = publicKey();
  if (!token || !url || !key) return null;
  const client = createClient(url, key, {
    global: { headers: { Authorization: `Bearer ${token}` } },
  });
  const { data } = await client.auth.getUser(token);
  return data.user || null;
}

async function mtnRequest(payment: any, booking: any, phone: string) {
  const base = Deno.env.get("MTN_BASE_URL") || "https://sandbox.momodeveloper.mtn.com";
  const subscriptionKey = Deno.env.get("MTN_COLLECTION_SUBSCRIPTION_KEY");
  const apiUser = Deno.env.get("MTN_API_USER");
  const apiKey = Deno.env.get("MTN_API_KEY");
  const targetEnvironment = Deno.env.get("MTN_TARGET_ENVIRONMENT") || "sandbox";
  if (!subscriptionKey || !apiUser || !apiKey) {
    throw new Error("MTN payment secrets are not configured");
  }
  const tokenResponse = await fetch(`${base}/collection/token/`, {
    method: "POST",
    headers: {
      Authorization: `Basic ${btoa(`${apiUser}:${apiKey}`)}`,
      "Ocp-Apim-Subscription-Key": subscriptionKey,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: "grant_type=client_credentials",
  });
  if (!tokenResponse.ok) throw new Error(`MTN token request failed: ${tokenResponse.status}`);
  const token = (await tokenResponse.json()).access_token;
  const reference = crypto.randomUUID();
  const requestResponse = await fetch(`${base}/collection/v1_0/requesttopay`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "X-Reference-Id": reference,
      "X-Target-Environment": targetEnvironment,
      "Ocp-Apim-Subscription-Key": subscriptionKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      amount: String(payment.amount),
      currency: payment.currency || "UGX",
      externalId: booking.booking_reference,
      payer: { partyIdType: "MSISDN", partyId: phoneDigits(phone) },
      payerMessage: `Daily Travel ${booking.booking_reference}`,
      payeeNote: "Daily Travel bus booking",
    }),
  });
  if (!requestResponse.ok) {
    throw new Error(`MTN payment request failed: ${requestResponse.status} ${await requestResponse.text()}`);
  }
  return { provider: "mtn_momo", reference, status: "PENDING" };
}

async function airtelRequest(payment: any, booking: any, phone: string) {
  const base = Deno.env.get("AIRTEL_BASE_URL") || "https://openapi.airtel.africa";
  const clientId = Deno.env.get("AIRTEL_CLIENT_ID");
  const clientSecret = Deno.env.get("AIRTEL_CLIENT_SECRET");
  if (!clientId || !clientSecret) {
    throw new Error("Airtel payment secrets are not configured");
  }
  const tokenResponse = await fetch(`${base}/auth/oauth2/token`, {
    method: "POST",
    headers: {
      Authorization: `Basic ${btoa(`${clientId}:${clientSecret}`)}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: "grant_type=client_credentials",
  });
  if (!tokenResponse.ok) throw new Error(`Airtel token request failed: ${tokenResponse.status}`);
  const token = (await tokenResponse.json()).access_token;
  const reference = crypto.randomUUID();
  const paymentResponse = await fetch(
    `${base}${Deno.env.get("AIRTEL_PAYMENT_PATH") || "/merchant/v1/payments/"}`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
        "X-Country": Deno.env.get("AIRTEL_COUNTRY") || "UG",
        "X-Currency": payment.currency || "UGX",
      },
      body: JSON.stringify({
        reference,
        subscriber: {
          country: Deno.env.get("AIRTEL_COUNTRY") || "UG",
          currency: payment.currency || "UGX",
          msisdn: phoneDigits(phone),
        },
        transaction: {
          amount: payment.amount,
          country: Deno.env.get("AIRTEL_COUNTRY") || "UG",
          currency: payment.currency || "UGX",
          id: reference,
        },
      }),
    },
  );
  if (!paymentResponse.ok) {
    throw new Error(`Airtel payment request failed: ${paymentResponse.status} ${await paymentResponse.text()}`);
  }
  return { provider: "airtel_money", reference, status: "PENDING" };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "POST required" }, 405);
  let adminClient: any = null;
  let paymentId: string | undefined;
  try {
    const user = await requireUser(req);
    if (!user) return json({ error: "Authentication required" }, 401);
    const body = await req.json();
    paymentId = body.payment_id;
    const phone = body.phone;
    if (!paymentId || !phone) return json({ error: "payment_id and phone are required" }, 400);
    const url = Deno.env.get("SUPABASE_URL");
    const key = secretKey();
    if (!url || !key) return json({ error: "Supabase server secrets are not configured" }, 500);
    const admin = createClient(url, key);
    adminClient = admin;
    const { data: payment, error: paymentError } = await admin
      .from("payments")
      .select("*")
      .eq("id", paymentId)
      .single();
    if (paymentError || !payment) return json({ error: "Payment not found" }, 404);
    const { data: profile } = await admin.from("users").select("role").eq("id", user.id).maybeSingle();
    if (payment.customer_id !== user.id && profile?.role !== "admin") return json({ error: "Not allowed" }, 403);
    const { data: booking } = await admin.from("bookings").select("*").eq("id", payment.booking_id).single();
    if (!booking) return json({ error: "Booking not found" }, 404);
    if (["successful", "failed", "refunded"].includes(payment.status)) return json({ payment });
    const provider = payment.payment_method === "airtel_money" ? "airtel_money" : "mtn_momo";
    const request = provider === "airtel_money"
      ? await airtelRequest(payment, booking, phone)
      : await mtnRequest(payment, booking, phone);
    await admin.from("payments").update({
      status: "processing",
      provider_reference: request.reference,
      provider_status: request.status,
    }).eq("id", payment.id);
    return json({ payment_id: payment.id, provider, provider_reference: request.reference, status: "processing" });
  } catch (error) {
    console.error(error);
    if (adminClient && paymentId) {
      await adminClient.rpc("finalize_payment", {
        p_payment_id: paymentId,
        p_success: false,
        p_provider_status: "INITIATION_FAILED",
      }).catch(() => undefined);
    }
    return json({ error: error instanceof Error ? error.message : "Payment initiation failed" }, 502);
  }
});

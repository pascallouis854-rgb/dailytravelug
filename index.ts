import { createClient } from "npm:@supabase/supabase-js@2";
import { PDFDocument, StandardFonts, rgb } from "npm:pdf-lib@1.17.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
};
function secretKey() {
  const direct = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (direct) return direct;
  try { return JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") || "{}").default; } catch { return undefined; }
}
function publicKey() { return Deno.env.get("SUPABASE_PUBLISHABLE_KEY") || Deno.env.get("SUPABASE_ANON_KEY"); }
function errorResponse(message: string, status: number) { return new Response(JSON.stringify({ error: message }), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } }); }
async function userFromRequest(req: Request) {
  const token = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "");
  const url = Deno.env.get("SUPABASE_URL"); const key = publicKey();
  if (!token || !url || !key) return null;
  const client = createClient(url, key, { global: { headers: { Authorization: `Bearer ${token}` } } });
  return (await client.auth.getUser(token)).data.user || null;
}
function text(value: unknown) { return String(value ?? ""); }
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "GET") return errorResponse("GET required", 405);
  try {
    const user = await userFromRequest(req);
    if (!user) return errorResponse("Authentication required", 401);
    const bookingId = new URL(req.url).searchParams.get("booking_id");
    if (!bookingId) return errorResponse("booking_id is required", 400);
    const url = Deno.env.get("SUPABASE_URL"); const key = secretKey();
    if (!url || !key) return errorResponse("Supabase server secrets are not configured", 500);
    const admin = createClient(url, key);
    const { data: booking, error: bookingError } = await admin.from("bookings").select("*").eq("id", bookingId).single();
    if (bookingError || !booking) return errorResponse("Booking not found", 404);
    const { data: profile } = await admin.from("users").select("role").eq("id", user.id).maybeSingle();
    if (booking.customer_id !== user.id && profile?.role !== "admin") return errorResponse("Not allowed", 403);
    const { data: payment } = await admin.from("payments").select("*").eq("booking_id", booking.id).order("created_at", { ascending: false }).limit(1).maybeSingle();
    if (!payment || payment.status !== "successful") return errorResponse("Receipt is available after successful payment", 409);
    const { data: tickets } = await admin.from("tickets").select("ticket_code, seat_number, status").eq("booking_id", booking.id).order("seat_number");
    const { data: company } = booking.company_id ? await admin.from("bus_companies").select("company_name, trading_name").eq("id", booking.company_id).maybeSingle() : { data: null };
    const { data: schedule } = booking.schedule_id ? await admin.from("schedules").select("departure_datetime, arrival_datetime, route_id").eq("id", booking.schedule_id).maybeSingle() : { data: null };
    const { data: route } = booking.route_id ? await admin.from("routes").select("origin_city, destination_city, origin_terminal, destination_terminal").eq("id", booking.route_id).maybeSingle() : { data: null };

    const pdf = await PDFDocument.create();
    const page = pdf.addPage([595, 842]);
    const regular = await pdf.embedFont(StandardFonts.Helvetica);
    const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
    const blue = rgb(0.03, 0.6, 0.89);
    page.drawText("DAILY TRAVEL", { x: 48, y: 780, size: 22, font: bold, color: blue });
    page.drawText("Official payment receipt", { x: 48, y: 754, size: 11, font: regular, color: rgb(0.35, 0.35, 0.35) });
    page.drawLine({ start: { x: 48, y: 738 }, end: { x: 547, y: 738 }, thickness: 1, color: rgb(0.85, 0.85, 0.85) });
    const lines = [
      ["Booking reference", text(booking.booking_reference)],
      ["Payment reference", text(payment.provider_reference || payment.id)],
      ["Payment status", text(payment.status)],
      ["Payment method", text(payment.payment_method)],
      ["Payment date", new Date(payment.created_at || Date.now()).toLocaleString("en-UG")],
      ["Company", text(company?.company_name || booking.company_id)],
      ["Route", `${text(route?.origin_city || "")} → ${text(route?.destination_city || "")}`],
      ["Departure", schedule?.departure_datetime ? new Date(schedule.departure_datetime).toLocaleString("en-UG") : ""],
      ["Seats", (Array.isArray(booking.seat_numbers) ? booking.seat_numbers : []).join(", ")],
      ["Base fare", `UGX ${Number(booking.base_fare || 0).toLocaleString("en-UG")}`],
      ["Platform fee", `UGX ${Number(booking.admin_charge || 0).toLocaleString("en-UG")}`],
      ["Total paid", `UGX ${Number(payment.amount || booking.total_amount || 0).toLocaleString("en-UG")}`],
      ["Tickets", (tickets || []).map((ticket) => ticket.ticket_code).join(", ")],
    ];
    let y = 700;
    for (const [label, value] of lines) {
      page.drawText(label, { x: 48, y, size: 10, font: bold, color: rgb(0.25, 0.25, 0.25) });
      page.drawText(value, { x: 210, y, size: 10, font: regular, color: rgb(0.1, 0.1, 0.1), maxWidth: 330 });
      y -=  thirty;
    }
    page.drawText("Keep this receipt for your records.", { x: 48, y: 90, size: 10, font: regular, color: rgb(0.4, 0.4, 0.4) });
    const bytes = await pdf.save();
    return new Response(bytes, {
      headers: {
        ...corsHeaders,
        "Content-Type": "application/pdf",
        "Content-Disposition": `attachment; filename="receipt-${booking.booking_reference}.pdf"`,
      },
    });
  } catch (error) {
    console.error(error);
    return errorResponse(error instanceof Error ? error.message : "Receipt generation failed", 500);
  }
});
const thirty = 30;

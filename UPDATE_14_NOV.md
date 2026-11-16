# Daily Travel: update of 14 November (adjustments document)

## How to install (in this order)
1. **SQL Editor:** run `supabase/20261114_adjustments.sql` once (after the two earlier files). It can be run again safely.
2. **Edge Functions:** deploy these (Dashboard > Edge Functions, or `supabase functions deploy <name>`):
   `payment-initiate`, `payment-status`, `payment-webhook`, `receipt-download` (all four changed), and the two new ones `delete-account` and `recover-password`. The folder `supabase/functions/_shared` must be deployed with them (it holds the payout code).
   - `recover-password` must be deployed with **JWT verification turned off** (it is called before login): `supabase functions deploy recover-password --no-verify-jwt`.
3. **Auth email template (needed for password recovery):** Authentication > Email Templates > *Reset Password*. Put the code in the message body: `Your Daily Travel code is {{ .Token }}`.
4. **Storage:** the migration creates public buckets `avatars` and `company-media` (PNG/JPG, 2 MB). Nothing to do unless the SQL output reports a problem.
5. Upload the new `index.html` and `admin.html` to GitHub (Netlify/Pages redeploys). Hard-refresh the browser.
6. Optional secrets: `DISBURSEMENT_ENABLED=true` plus `MTN_DISBURSEMENT_SUBSCRIPTION_KEY`, `MTN_DISBURSEMENT_API_USER`, `MTN_DISBURSEMENT_API_KEY` (see "Payments" below). Optional: enable `pg_cron` so departure alerts go out even when nobody has the app open.

## What is new
**Customers**: only upcoming trips from active companies are shown; one final price per ticket (the commission is already inside it, no breakdown); several destinations per trip, each with its own price; search by company or route; MTN, Airtel or bank transfer; seat map (blue = taken, yellow = yours, grey = staff/blocked); one PDF ticket per seat with QR code, company, seat, price, branch, route, purchase and departure time, arrive-by time (30 min before) and branch/company contacts; notifications (payment confirmation, 30-minute alert, departure alert, messages from companies and admin); profile photo (PNG/JPG up to 2 MB); delete account; forgot password by email or phone number with a 6-digit code.
**Companies**: branches with routes under them; bus layout 2+2 or 2+3 and staff seats; a price table per trip (extra destinations); block seats for offline sales; days-ahead booking window; daily/weekly/monthly earnings charts with "delete records"; messages to all or one customer; sale notifications; logo and photos; support contacts shown on tickets; delete account; registration-fee step when registering.
**Admin**: approved / pending / suspended / rejected lists; suspend hides the company from customers at once and unsuspend brings it back; delete removes the company completely (login too) so it can register again; registration-fee payments to confirm or reject; adjustable and removable registration fee (default and per company); commission percentage added on top of every ticket; notifications inbox (new registrations) and messages to all companies, one company or all customers; daily/weekly/monthly earnings; bank, MTN and Airtel account details; confirm bank transfers.

## Payments: what is automatic and what is not
- Customers pay the final price into the **platform merchant account** through MTN/Airtel. The company's share is then paid out with `settlePayment` **only if** `DISBURSEMENT_ENABLED=true` and MTN Disbursement credentials exist. Merchant codes are not phone numbers, so the payout uses the number saved as the company's MTN code: use a phone number there if you want automatic payouts. Airtel payouts, and anything that fails, stay as *pending / manual_required* in the company's and admin's payment lists for you to pay by hand. The admin commission simply stays in the collection account.
- **Bank transfers** are confirmed by the admin in Transactions (Pending bank payments). Seats are held for 60 minutes.
- **Registration fee** is paid manually to your MTN/Airtel merchant code; the company enters the transaction ID and you confirm it in the company card.
- **Password recovery by phone**: the code is sent to the email on that account (SMS needs an SMS provider). The person confirms the email address and types the code.
- Not tested against your live Supabase project: please do the end-to-end check from `FIXES_AND_SETUP.md` after installing.

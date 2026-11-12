# Daily Travel: what was fixed and how to switch it on

## Run order (about 10 minutes)

1. **Back up** the Supabase project (Database > Backups).
2. **SQL Editor:** run `verify_live_schema.sql`, save the output. Then run `supabase/20261111_link_apps_fix.sql` once. It is additive and safe to re-run; it does not drop tables or data.
3. **Create the admin.** Authentication > Users > Add user (email + password). Then run this in the SQL Editor (put your email in):
   ```sql
   INSERT INTO public.users (id, full_name, email, role, status)
   SELECT id, 'Administrator', email, 'admin', 'active' FROM auth.users WHERE email = 'YOU@EXAMPLE.COM'
   ON CONFLICT (id) DO UPDATE SET role = 'admin', status = 'active';
   ```
4. **Auth settings:** set Site URL and Redirect URLs to your Vercel URL. "Confirm email" can stay on; sign-up now works either way.
5. **Edge Function secrets:** set `PAYMENT_WEBHOOK_SECRET` (required, the webhook now refuses all calls without it) plus the MTN/Airtel secrets from `supabase/README.md`. Redeploy `payment-webhook`. Callback URL: `https://<project-ref>.supabase.co/functions/v1/payment-webhook?secret=<PAYMENT_WEBHOOK_SECRET>` (works for providers that cannot send custom headers).
6. Optional: enable `pg_cron` (Database > Extensions) so abandoned seat holds are released every minute. Holds are also released lazily whenever someone books.
7. Upload `index.html` and `admin.html` to GitHub/Vercel.

## End-to-end check

1. Register a company in the client app, then sign in to `admin.html` and approve it.
2. Sign in as the company: Buses > Routes > Schedules. Publish one schedule (seats are created automatically).
3. Open the client app on another device/browser: the trip appears (also live, without refresh).
4. Sign up a customer, book a seat. After the provider confirms payment the booking, ticket and receipt appear; the company dashboard and admin payments update live.

## What changed

**Database (`20261111_link_apps_fix.sql`)**
- Adds every column the apps use; fixes `seat_numbers` type; removes old CHECK constraints that blocked `held` seats.
- Profiles are created by a database trigger on sign-up, so sign-up works even when email confirmation is on. Company registration metadata creates the `bus_companies` row (pending approval). Nobody can sign up as admin.
- Schedules automatically generate their seats; `available_seats` is kept in sync.
- Seat holds expire after 10 minutes.
- `reserve_booking` checks the price against the schedule, schedule status and departure time. `finalize_payment` is idempotent (webhook + polling can both call it).
- **`finalize_payment` was callable by anyone** (Postgres grants EXECUTE to PUBLIC by default). It is now service-role only.
- RLS rewritten as one consistent set: browser can no longer insert/update bookings or payments, customers cannot confirm their own booking, company owners cannot approve themselves, users cannot self-promote to admin.
- Realtime enabled for every table the apps subscribe to.

**`index.html` (customer app + company dashboard)**
- Company dashboard: real Overview, Profile, Buses, Routes, Schedules (+ seat blocking), Bookings (+ ticket check at boarding), Payments, Earnings and Notifications backed by Supabase with live updates. Fake numbers removed.
- Customer catalogue shows the live database (even when empty), refreshes live, and shows a visible error banner instead of silently falling back to demo data.
- Removed prototype logins (`gateway123`, `123456`, ...), the browser-side booking/payment/ticket writer, and the SHA-256 password hash stored in `users`.

**`admin.html`**
- Data loads **after** login (it used to load before, get empty results, and keep demo data). Realtime also starts after login.
- Login requires an active admin row in `public.users`.
- Approve/suspend/delete/payout writes report failures and reload the real data instead of silently showing a change that never saved.
- Removed hard-coded stats (1,284 customers, bookings + 42, fixed registration fees) and demo state.
- Credential change verifies the current password with Supabase Auth.

**`payment-webhook`**: fails closed without `PAYMENT_WEBHOOK_SECRET`.

## Known remaining items

- **Payment provider credentials** are still needed; test MTN/Airtel in sandbox first. The Airtel endpoint/payload must be confirmed against your Airtel portal app.
- Approved companies' rows (including merchant codes and contact email) are readable by anyone, because row-level security cannot hide columns. If that matters, move the public fields to a view.
- The Branch login is not implemented (it now says so instead of using a fake account).
- Not verified here: the real Supabase project, real mobile-money providers, or email confirmation. The migration was tested on a local Postgres 16 (legacy schema, then migration twice, then a full booking/payment/permissions flow), and both pages were exercised in a browser against a mock Supabase client.

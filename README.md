# Daily Travel Uganda

The package preserves the existing Daily Travel client and admin UI and connects it to the existing Supabase project.

## Implemented

- Supabase Auth sign-in and sign-up wiring.
- Live company, route, schedule, seat, booking, payment, ticket, and admin data reads.
- Supabase Realtime publication and client subscriptions for customer/admin updates.
- Atomic `reserve_booking` database function for seat locking and pending payment creation.
- Trusted `finalize_payment` database function for payment completion, seat confirmation/release, and ticket creation.
- Deployed Supabase Edge Functions: `payment-initiate`, `payment-status`, `payment-webhook`, and `receipt-download`.
- Server-generated downloadable PDF receipts after successful payment.
- Admin persistence for company approvals/statuses, payout settings, support settings, account updates, and audit logs.

## Important payment status

The payment Edge Functions are deployed, but MTN/Airtel provider credentials and production callback configuration still need to be added as Supabase Edge Function secrets. Until that is done, payment initiation will not move real money. Do not test with production funds until sandbox testing and provider verification are complete.

The Airtel Uganda endpoint and payload must be confirmed against the Airtel developer portal application before production activation.

## Start here

See `FIXES_AND_SETUP.md` for the run order, admin bootstrap and the list of fixes. Run `supabase/20261111_link_apps_fix.sql` before using the apps.

## Safe setup

1. Keep the GitHub repository private.
2. Do **not** run `supabase_schema_final.sql` against the existing project. It is a reference schema with permissive anonymous policies and columns that do not match the live database.
3. The realtime/booking/payment migration has been applied to the connected project. Keep `supabase/20261110_realtime_booking_payments.sql` in source control.
4. Configure the payment secrets described in `supabase/README.md` through Supabase Edge Function secrets. Never put them in HTML or GitHub.
5. Create or invite an admin user in Supabase Auth; the admin HTML does not ship with a default password.
6. Upload the latest `index.html` and `admin.html` to the private GitHub repository and deploy the static site through Vercel.
7. Add the Vercel production URL to Supabase Auth Site URL and redirect allow-list.
8. Replace the current permissive anonymous policies with least-privilege RLS policies before production.

## Current data note

The live database currently has no schedules. The client therefore retains demo schedules as a fallback. Fully relational cross-device booking requires creating live routes, schedules, and schedule seats with UUIDs.

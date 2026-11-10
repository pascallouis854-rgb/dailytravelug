# Daily Travel Uganda

The package preserves the existing Daily Travel client and admin UI and adds schema-compatible Supabase integration without running database migrations.

## Current integration

- Supabase publishable client initialization in both HTML apps.
- Customer/company Supabase Auth sign-in and sign-up attempts.
- Live company, route, schedule, seat, booking, payment, and ticket reads when data exists.
- Customer/company profile writes using the live schema column names.
- Booking writes with required fare/charge fields plus related payment and ticket records.
- Admin reads for companies, payments, audit logs, payout settings, and support settings.
- Admin persistence for company approvals/statuses, payout settings, support settings, account updates, and audit logs.
- Existing demo data remains as a fallback when the live catalog is empty.

## Supabase project

The HTML files use the existing Daily Travel Supabase project and only the browser-safe publishable key. Never place a secret/service-role key in HTML or GitHub.

## Safe setup

1. Keep the GitHub repository private.
2. Do **not** run `supabase_schema_final.sql` against the existing project. It is a reference schema with permissive anonymous policies and columns that do not match the live database.
3. Run `verify_live_schema.sql` in the Supabase SQL Editor for a read-only baseline.
4. Create or invite an admin user in Supabase Auth; the admin HTML does not ship with a default password.
5. Import the private repository into Vercel as a static site. The client is `/` or `/index.html`; the admin is `/admin.html`.
6. Add the Vercel production URL to Supabase Auth Site URL and redirect allow-list.
7. Replace the current permissive anonymous policies with least-privilege RLS policies before production.

## Important limitation

The existing booking UI still simulates payment confirmation in the browser. Real MTN/Airtel collection, callbacks, reconciliation, and merchant disbursement must be implemented server-side before accepting money. Browser success state is not proof of payment.

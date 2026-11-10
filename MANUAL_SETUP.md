# Daily Travel Uganda — Manual setup checklist

This package contains the existing Daily Travel UI plus a Supabase-connected client and admin HTML bundle. The visual layout and product flow were preserved; the integration adds database/auth wiring and schema-compatible persistence without applying database migrations.

## Important safety warning

The supplied file is a reference schema, not a safe migration for the existing Daily Travel Supabase project. The live project already has a different schema, existing rows, and permissive anonymous policies. Running it as-is can fail or expose every table to anonymous users.

Do not make the repository public. Do not paste service-role keys into HTML or GitHub. Rotate any real credentials that were included in the supplied files before production use.

## 1. Upload the exact files to GitHub

Repository: `pascallouis854-rgb/daily-travel`

1. Open the repository on GitHub.
2. Select **Add file → Upload files**.
3. Upload these four files from this package to the repository root:
   - `index.html`
   - `admin.html`
   - `README.md`
   - `supabase_schema_final.sql`
4. Keep the repository **Private**.
5. Commit directly to the `main` branch, or create a pull request and merge it.
6. Confirm the repository root shows both HTML files.

The two apps are then available as:
- Client app: `/index.html` (or `/` when the host uses `index.html` as the root)
- Admin app: `/admin.html`

## 2. Verify Supabase before changing anything

1. Open the existing Supabase project named **Daily Travel**.
2. Open **SQL Editor**.
3. Run `verify_live_schema.sql` from this package. It contains read-only `SELECT` statements.
4. Save the result as a baseline or export a database backup.

Expected current findings include additional live tables and column names that do not match `supabase_schema_final.sql`.

## 3. Do not run the supplied final SQL on the existing project

The supplied file includes:

- permissive `allow_all` anonymous policies on application tables;
- table and column definitions that differ from the current project;
- seed values and payment settings that should not be applied blindly.

The old plaintext admin seed has been removed from the downloadable SQL reference. A safe production migration must be written against the live schema after deciding whether to preserve or replace the existing database. That migration should use Supabase Auth for passwords, least-privilege RLS policies, and server-side payment operations.

If you intentionally start a completely new, disposable Supabase project, review the SQL line-by-line first and test it there. Do not use it as a production security model without hardening it.

## 4. What “linking” means

GitHub stores source files. Supabase stores application data. Uploading a SQL file to GitHub does not execute it or connect the HTML apps to Supabase.

The connected Supabase project now has the realtime/booking/payment migration applied. The client and admin apps:

- use Supabase Auth for customer, company, and admin sessions;
- load live companies, routes, schedules, seats, bookings, payments, and tickets;
- subscribe to live booking, payment, ticket, company, and admin changes;
- reserve seats atomically through `reserve_booking`;
- finalize seats and tickets only through trusted payment finalization;
- request server-generated PDF receipts after successful payment.

The live database currently has no schedules, so the client keeps demo schedules as a fallback. Create live routes, schedules, and schedule seats with UUIDs before testing relational bookings across devices.

The Supabase Edge Functions are included under `supabase/functions/` and are deployed to the connected project. Provider credentials are intentionally not included.

## 5. Auth, payment activation, and production security

1. In Supabase Auth, create or invite an admin user. The admin HTML does not ship with a default password.
2. Set the Supabase Auth Site URL and redirect allow-list to the deployed Vercel URL.
3. Keep only the publishable key in the HTML. Never put a secret/service-role key in the repository or browser.
4. Configure the MTN/Airtel secrets listed in `supabase/README.md` under Supabase Edge Function secrets.
5. Configure the provider callback URL as `https://<project-ref>.supabase.co/functions/v1/payment-webhook` when supported.
6. Test in provider sandbox first. Do not accept production funds until initiation, status polling, callbacks, idempotency, and refunds have been verified.
7. Replace the current permissive anonymous policies with least-privilege RLS policies before production.
8. Keep the browser out of payment confirmation: only the Edge Functions may mark a payment successful.

Receipts become downloadable PDF files only after the corresponding payment is successfully finalized.

## 6. Vercel deployment after GitHub upload

1. Import the private `daily-travel` repository into Vercel.
2. Choose **Other** / static site if Vercel asks for a framework.
3. Leave build and install commands empty.
4. Keep the root directory as `/`.
5. Deploy the `main` branch.
6. Test:
   - `/` or `/index.html` for the client app;
   - `/admin.html` for the admin app.

After Vercel provides the production URL, add that URL to the Supabase Auth Site URL and redirect allow-list. Do not use `http://localhost:3000` in production.

## 7. Minimum acceptance checks

- Both HTML files are visible in the GitHub repository root.
- The client and admin pages load from Vercel.
- Supabase Auth redirect settings contain the real production URL.
- A test record written through the app can be read back after a refresh.
- After RLS hardening, anonymous users cannot read or modify other users’ private data.
- Payment status is confirmed by a trusted server callback, not by a browser alert or local state.

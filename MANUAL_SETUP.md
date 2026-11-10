# Daily Travel Uganda — Manual setup checklist

This package contains the existing Daily Travel UI plus a Supabase-connected client and admin HTML bundle. The visual layout and product flow were preserved; the integration adds database/auth wiring and schema-compatible persistence without applying database migrations.

## Important safety warning

The supplied `supabase_schema_final.sql` is a reference file, not a safe migration for the existing Daily Travel Supabase project. The live project already has a different schema, existing rows, and permissive anonymous policies. Running the file as-is can fail, overwrite the admin password, or expose every table to anonymous users.

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

The updated HTML files initialize the Supabase publishable client and expose `window.dailyTravelSupabase` and the compatibility bridge used by the existing bundle. The client now:

- attempts Supabase Auth sign-in/sign-up for customers and companies;
- loads live companies, routes, schedules, seats, bookings, payments, and tickets when rows exist;
- writes customer/company profiles using the live column names;
- writes bookings with the live required fare/charge fields and creates related payment/ticket rows;
- retains the bundled demo catalog only when the live catalog is empty.

The admin now loads live companies, payments, audit logs, payout settings, and support settings, and persists company status changes, payout settings, support settings, account updates, and audit logs.

This is not a payment gateway implementation: the existing UI still simulates payment confirmation in the browser. Real MTN/Airtel collection and callbacks must be implemented server-side before accepting money. The current live project also has permissive anonymous policies, so harden RLS before production.

## 5. Auth and production security

1. In Supabase Auth, create or invite an admin user. The admin HTML does not ship with a default password.
2. Set the Supabase Auth Site URL and redirect allow-list to the deployed Vercel URL.
3. Keep only the publishable key in the HTML. Never put a secret/service-role key in the repository or browser.
4. Replace the current permissive anonymous policies with least-privilege RLS policies before production.
5. Configure server-side MTN/Airtel payment initiation and trusted callbacks. Do not treat the browser’s simulated success state as proof of payment.

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
- RLS prevents anonymous users from reading or modifying other users’ private data.
- Payment status is confirmed by a trusted server callback, not by a browser alert or local state.

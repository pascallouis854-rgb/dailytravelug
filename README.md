# Daily Travel Supabase backend

This directory contains the production backend pieces for booking, realtime updates, payment initiation/status callbacks, and PDF receipts.

## Database migrations

The connected project has applied both:

- `20261110_realtime_booking_payments.sql` for Realtime, atomic seat reservation, and payment finalization;
- `20261110_rls_hardening.sql` for identity-scoped policies.

Keep both migrations in source control. They do not seed credentials or open anonymous write access.

## Edge Functions

Deploy these to the existing Supabase project:

- `payment-initiate`
- `payment-status`
- `payment-webhook` (JWT verification disabled because providers call it)
- `receipt-download`

## Required Supabase secrets

Never put these in the HTML app:

```text
MTN_BASE_URL=https://sandbox.momodeveloper.mtn.com
MTN_TARGET_ENVIRONMENT=sandbox
MTN_COLLECTION_SUBSCRIPTION_KEY=...
MTN_API_USER=...
MTN_API_KEY=...

AIRTEL_BASE_URL=https://openapi.airtel.africa
AIRTEL_COUNTRY=UG
AIRTEL_CLIENT_ID=...
AIRTEL_CLIENT_SECRET=...
AIRTEL_PAYMENT_PATH=/merchant/v1/payments/
AIRTEL_PAYMENT_STATUS_PATH=/standard/v1/payments/

PAYMENT_WEBHOOK_SECRET=...
```

Use production provider URLs and credentials only after sandbox testing. The Airtel endpoint and payload must be confirmed against the Uganda application in the Airtel developer portal before production activation.

The Edge Functions use the Supabase project URL and server key supplied by the Supabase runtime. Do not copy a service-role key into the browser.

## Payment activation sequence

1. Apply the migration.
2. Deploy the functions.
3. Configure the secrets in Supabase Edge Function settings.
4. Configure the provider callback URL as (the secret is required):
   `https://<project-ref>.supabase.co/functions/v1/payment-webhook?secret=<PAYMENT_WEBHOOK_SECRET>`
5. Test MTN and Airtel in sandbox.
6. Confirm successful callbacks update `payments`, `bookings`, `schedule_seats`, and `tickets`.
7. Only then switch to production provider credentials.

-- Daily Travel: link customer app, company dashboard and admin on Supabase.
-- Idempotent and additive: safe to re-run. Does NOT drop tables or data.
-- Run in Supabase SQL Editor AFTER taking a backup, then run the "ADMIN BOOTSTRAP" block at the bottom.

-- ---------------------------------------------------------------------------
-- 1. Make sure every column the apps use exists (names match the client code)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.users (id uuid PRIMARY KEY);
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS full_name text,
  ADD COLUMN IF NOT EXISTS phone text,
  ADD COLUMN IF NOT EXISTS email text,
  ADD COLUMN IF NOT EXISTS role text DEFAULT 'customer',
  ADD COLUMN IF NOT EXISTS status text DEFAULT 'active',
  ADD COLUMN IF NOT EXISTS profile_picture_url text,
  ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now(),
  ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT now();
-- Passwords live in Supabase Auth only.
DO $$ BEGIN
  ALTER TABLE public.users ALTER COLUMN password_hash DROP NOT NULL;
EXCEPTION WHEN undefined_column THEN NULL; END $$;
UPDATE public.users SET password_hash = NULL WHERE password_hash IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.bus_companies (id uuid PRIMARY KEY DEFAULT gen_random_uuid());
ALTER TABLE public.bus_companies
  ADD COLUMN IF NOT EXISTS owner_id uuid,
  ADD COLUMN IF NOT EXISTS company_name text,
  ADD COLUMN IF NOT EXISTS trading_name text,
  ADD COLUMN IF NOT EXISTS registration_number text,
  ADD COLUMN IF NOT EXISTS description text,
  ADD COLUMN IF NOT EXISTS phone text,
  ADD COLUMN IF NOT EXISTS email text,
  ADD COLUMN IF NOT EXISTS address text,
  ADD COLUMN IF NOT EXISTS operating_location text,
  ADD COLUMN IF NOT EXISTS rep_name text,
  ADD COLUMN IF NOT EXISTS rep_phone text,
  ADD COLUMN IF NOT EXISTS rep_email text,
  ADD COLUMN IF NOT EXISTS logo_url text,
  ADD COLUMN IF NOT EXISTS photos jsonb DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS merchant_mtn_code text,
  ADD COLUMN IF NOT EXISTS merchant_airtel_code text,
  ADD COLUMN IF NOT EXISTS registration_fee_amount integer DEFAULT 0,
  ADD COLUMN IF NOT EXISTS rejection_reason text,
  ADD COLUMN IF NOT EXISTS status text DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS approval_status text DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now(),
  ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT now();
DO $$ BEGIN
  ALTER TABLE public.bus_companies ALTER COLUMN password_hash DROP NOT NULL;
EXCEPTION WHEN undefined_column THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS public.buses (id uuid PRIMARY KEY DEFAULT gen_random_uuid());
ALTER TABLE public.buses
  ADD COLUMN IF NOT EXISTS company_id uuid,
  ADD COLUMN IF NOT EXISTS registration_number text,
  ADD COLUMN IF NOT EXISTS bus_type text DEFAULT 'Standard',
  ADD COLUMN IF NOT EXISTS capacity integer DEFAULT 45,
  ADD COLUMN IF NOT EXISTS layout text DEFAULT '2-3',
  ADD COLUMN IF NOT EXISTS staff_seats text[] DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS status text DEFAULT 'active',
  ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now();

CREATE TABLE IF NOT EXISTS public.routes (id uuid PRIMARY KEY DEFAULT gen_random_uuid());
ALTER TABLE public.routes
  ADD COLUMN IF NOT EXISTS company_id uuid,
  ADD COLUMN IF NOT EXISTS origin_city text,
  ADD COLUMN IF NOT EXISTS destination_city text,
  ADD COLUMN IF NOT EXISTS origin_terminal text,
  ADD COLUMN IF NOT EXISTS destination_terminal text,
  ADD COLUMN IF NOT EXISTS distance_km integer,
  ADD COLUMN IF NOT EXISTS base_price integer,
  ADD COLUMN IF NOT EXISTS status text DEFAULT 'active',
  ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now();

CREATE TABLE IF NOT EXISTS public.schedules (id uuid PRIMARY KEY DEFAULT gen_random_uuid());
ALTER TABLE public.schedules
  ADD COLUMN IF NOT EXISTS company_id uuid,
  ADD COLUMN IF NOT EXISTS bus_id uuid,
  ADD COLUMN IF NOT EXISTS route_id uuid,
  ADD COLUMN IF NOT EXISTS departure_datetime timestamptz,
  ADD COLUMN IF NOT EXISTS arrival_datetime timestamptz,
  ADD COLUMN IF NOT EXISTS base_fare integer,
  ADD COLUMN IF NOT EXISTS available_seats integer,
  ADD COLUMN IF NOT EXISTS status text DEFAULT 'scheduled',
  ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now();

CREATE TABLE IF NOT EXISTS public.schedule_seats (id uuid PRIMARY KEY DEFAULT gen_random_uuid());
ALTER TABLE public.schedule_seats
  ADD COLUMN IF NOT EXISTS schedule_id uuid,
  ADD COLUMN IF NOT EXISTS seat_number text,
  ADD COLUMN IF NOT EXISTS status text DEFAULT 'available',
  ADD COLUMN IF NOT EXISTS booked_by_booking_id uuid,
  ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now();
CREATE UNIQUE INDEX IF NOT EXISTS schedule_seats_unique_seat ON public.schedule_seats (schedule_id, seat_number);

CREATE TABLE IF NOT EXISTS public.bookings (id uuid PRIMARY KEY DEFAULT gen_random_uuid());
ALTER TABLE public.bookings
  ADD COLUMN IF NOT EXISTS booking_reference text,
  ADD COLUMN IF NOT EXISTS customer_id uuid,
  ADD COLUMN IF NOT EXISTS company_id uuid,
  ADD COLUMN IF NOT EXISTS branch_id uuid,
  ADD COLUMN IF NOT EXISTS schedule_id uuid,
  ADD COLUMN IF NOT EXISTS route_id uuid,
  ADD COLUMN IF NOT EXISTS passenger_count integer,
  ADD COLUMN IF NOT EXISTS seat_numbers jsonb DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS passenger_details jsonb DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS base_fare integer DEFAULT 0,
  ADD COLUMN IF NOT EXISTS admin_charge integer DEFAULT 0,
  ADD COLUMN IF NOT EXISTS flutterwave_charge integer DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_amount integer DEFAULT 0,
  ADD COLUMN IF NOT EXISTS currency text DEFAULT 'UGX',
  ADD COLUMN IF NOT EXISTS status text DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS payment_status text DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now(),
  ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT now();
-- Old reference schema stored seat_numbers as text[]; the functions and apps use jsonb.
DO $$
BEGIN
  IF (SELECT data_type FROM information_schema.columns
      WHERE table_schema='public' AND table_name='bookings' AND column_name='seat_numbers') = 'ARRAY' THEN
    ALTER TABLE public.bookings ALTER COLUMN seat_numbers DROP DEFAULT;
    ALTER TABLE public.bookings ALTER COLUMN seat_numbers TYPE jsonb USING to_jsonb(seat_numbers);
    ALTER TABLE public.bookings ALTER COLUMN seat_numbers SET DEFAULT '[]'::jsonb;
  END IF;
END $$;
ALTER TABLE public.bookings ALTER COLUMN booking_reference
  SET DEFAULT ('DT-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)));
UPDATE public.bookings SET booking_reference = 'DT-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,8))
 WHERE booking_reference IS NULL;

CREATE TABLE IF NOT EXISTS public.payments (id uuid PRIMARY KEY DEFAULT gen_random_uuid());
ALTER TABLE public.payments
  ADD COLUMN IF NOT EXISTS booking_id uuid,
  ADD COLUMN IF NOT EXISTS company_id uuid,
  ADD COLUMN IF NOT EXISTS customer_id uuid,
  ADD COLUMN IF NOT EXISTS amount integer,
  ADD COLUMN IF NOT EXISTS base_amount integer,
  ADD COLUMN IF NOT EXISTS admin_amount integer,
  ADD COLUMN IF NOT EXISTS flutterwave_amount integer DEFAULT 0,
  ADD COLUMN IF NOT EXISTS currency text DEFAULT 'UGX',
  ADD COLUMN IF NOT EXISTS payment_method text,
  ADD COLUMN IF NOT EXISTS provider_reference text,
  ADD COLUMN IF NOT EXISTS provider_status text,
  ADD COLUMN IF NOT EXISTS settlement_status text DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS status text DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now();
CREATE INDEX IF NOT EXISTS payments_provider_reference_idx ON public.payments (provider_reference);

CREATE TABLE IF NOT EXISTS public.tickets (id uuid PRIMARY KEY DEFAULT gen_random_uuid());
ALTER TABLE public.tickets
  ADD COLUMN IF NOT EXISTS booking_id uuid,
  ADD COLUMN IF NOT EXISTS ticket_code text,
  ADD COLUMN IF NOT EXISTS passenger_name text,
  ADD COLUMN IF NOT EXISTS seat_number text,
  ADD COLUMN IF NOT EXISTS status text DEFAULT 'valid',
  ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now();
ALTER TABLE public.tickets ALTER COLUMN ticket_code
  SET DEFAULT ('TKT-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,10)));
UPDATE public.tickets SET ticket_code = 'TKT-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,10))
 WHERE ticket_code IS NULL;

CREATE TABLE IF NOT EXISTS public.notifications (id uuid PRIMARY KEY DEFAULT gen_random_uuid());
ALTER TABLE public.notifications
  ADD COLUMN IF NOT EXISTS user_id uuid,
  ADD COLUMN IF NOT EXISTS company_id uuid,
  ADD COLUMN IF NOT EXISTS audience_type text DEFAULT 'all',
  ADD COLUMN IF NOT EXISTS title text,
  ADD COLUMN IF NOT EXISTS message text,
  ADD COLUMN IF NOT EXISTS is_read boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now();

CREATE TABLE IF NOT EXISTS public.admin_settings (id uuid PRIMARY KEY DEFAULT gen_random_uuid());
ALTER TABLE public.admin_settings
  ADD COLUMN IF NOT EXISTS mtn_merchant_code text,
  ADD COLUMN IF NOT EXISTS airtel_merchant_code text,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT now();

CREATE TABLE IF NOT EXISTS public.support_settings (id uuid PRIMARY KEY DEFAULT gen_random_uuid());
ALTER TABLE public.support_settings
  ADD COLUMN IF NOT EXISTS audience_type text,
  ADD COLUMN IF NOT EXISTS phone text,
  ADD COLUMN IF NOT EXISTS email text,
  ADD COLUMN IF NOT EXISTS whatsapp text,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT now();
-- The admin app reads/writes faqs as an array.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='support_settings' AND column_name='faqs') THEN
    ALTER TABLE public.support_settings ADD COLUMN faqs jsonb DEFAULT '[]'::jsonb;
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.audit_logs (id uuid PRIMARY KEY DEFAULT gen_random_uuid());
ALTER TABLE public.audit_logs
  ADD COLUMN IF NOT EXISTS action text,
  ADD COLUMN IF NOT EXISTS entity_type text,
  ADD COLUMN IF NOT EXISTS entity_id text,
  ADD COLUMN IF NOT EXISTS actor_role text,
  ADD COLUMN IF NOT EXISTS reason text,
  ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now();

CREATE TABLE IF NOT EXISTS public.company_documents (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid);
CREATE TABLE IF NOT EXISTS public.registration_payments (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid);
CREATE TABLE IF NOT EXISTS public.financial_ledger (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid);
CREATE TABLE IF NOT EXISTS public.branches (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid);

-- ---------------------------------------------------------------------------
-- 2. Normalise statuses and drop old CHECK constraints that block 'held' etc.
-- ---------------------------------------------------------------------------
DO $$
DECLARE c record;
BEGIN
  FOR c IN
    SELECT conrelid::regclass AS tbl, conname
    FROM pg_constraint
    WHERE contype = 'c'
      AND connamespace = 'public'::regnamespace
      AND conrelid::regclass::text IN
        ('schedule_seats','schedules','routes','bookings','payments','buses','tickets')
      AND pg_get_constraintdef(oid) ILIKE '%status%'
  LOOP
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', c.tbl, c.conname);
  END LOOP;
END $$;
UPDATE public.schedules SET status = 'scheduled' WHERE status IS NULL OR status = 'active';
ALTER TABLE public.schedules ALTER COLUMN status SET DEFAULT 'scheduled';
UPDATE public.routes SET status = 'active' WHERE status IS NULL;
ALTER TABLE public.schedule_seats ADD CONSTRAINT schedule_seats_status_chk
  CHECK (status IN ('available','held','booked','blocked'));

-- ---------------------------------------------------------------------------
-- 3. Profiles are created by the database, not by the browser.
--    This works even when "Confirm email" is on (no session at sign-up time).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  m jsonb := coalesce(NEW.raw_user_meta_data, '{}'::jsonb);
BEGIN
  IF m->>'role' = 'company' THEN
    INSERT INTO public.bus_companies (
      owner_id, company_name, trading_name, registration_number, description,
      phone, email, address, operating_location, rep_name, rep_phone, rep_email,
      merchant_mtn_code, merchant_airtel_code, status, approval_status
    ) VALUES (
      NEW.id, m->>'company_name', coalesce(m->>'trading_name', m->>'company_name'),
      m->>'registration_number', m->>'description', m->>'phone', NEW.email,
      m->>'address', m->>'operating_location', m->>'rep_name', m->>'rep_phone', m->>'rep_email',
      m->>'merchant_mtn_code', m->>'merchant_airtel_code', 'pending', 'pending'
    );
  ELSE
    -- Metadata can never grant admin: new accounts are always customers.
    INSERT INTO public.users (id, full_name, phone, email, role, status)
    VALUES (NEW.id, m->>'full_name', m->>'phone', NEW.email, 'customer', 'active')
    ON CONFLICT (id) DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS on_auth_user_created_daily_travel ON auth.users;
CREATE TRIGGER on_auth_user_created_daily_travel
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_auth_user();

-- Backfill profile rows for Auth users that have none (excluding company owners).
INSERT INTO public.users (id, full_name, phone, email, role, status)
SELECT au.id, au.raw_user_meta_data->>'full_name', au.raw_user_meta_data->>'phone', au.email, 'customer', 'active'
FROM auth.users au
WHERE NOT EXISTS (SELECT 1 FROM public.users u WHERE u.id = au.id)
  AND NOT EXISTS (SELECT 1 FROM public.bus_companies c WHERE c.owner_id = au.id)
  AND coalesce(au.raw_user_meta_data->>'role','') <> 'company';

-- ---------------------------------------------------------------------------
-- 4. Seats are generated automatically when a schedule is created.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.generate_schedule_seats()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_capacity integer := 45;
  v_staff text[] := '{}';
BEGIN
  IF NEW.bus_id IS NOT NULL THEN
    SELECT coalesce(capacity, 45), coalesce(staff_seats, '{}') INTO v_capacity, v_staff
    FROM public.buses WHERE id = NEW.bus_id;
  END IF;
  INSERT INTO public.schedule_seats (schedule_id, seat_number, status)
  SELECT NEW.id, n::text,
         CASE WHEN n::text = ANY (v_staff) THEN 'blocked' ELSE 'available' END
  FROM generate_series(1, greatest(v_capacity, 1)) AS n
  ON CONFLICT (schedule_id, seat_number) DO NOTHING;
  UPDATE public.schedules
  SET available_seats = (SELECT count(*) FROM public.schedule_seats
                         WHERE schedule_id = NEW.id AND status = 'available')
  WHERE id = NEW.id;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS schedules_generate_seats ON public.schedules;
CREATE TRIGGER schedules_generate_seats
  AFTER INSERT ON public.schedules
  FOR EACH ROW EXECUTE FUNCTION public.generate_schedule_seats();

-- Backfill seats for any schedule that already exists without seats.
INSERT INTO public.schedule_seats (schedule_id, seat_number, status)
SELECT s.id, n::text, 'available'
FROM public.schedules s
CROSS JOIN LATERAL generate_series(1, coalesce((SELECT capacity FROM public.buses b WHERE b.id = s.bus_id), 45)) n
WHERE NOT EXISTS (SELECT 1 FROM public.schedule_seats ss WHERE ss.schedule_id = s.id)
ON CONFLICT (schedule_id, seat_number) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 5. Seat holds expire (default 10 minutes) so abandoned payments free seats.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.release_expired_holds(p_minutes integer DEFAULT 10)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r record;
  n integer := 0;
BEGIN
  FOR r IN
    SELECT b.id AS booking_id, b.schedule_id
    FROM public.bookings b
    JOIN public.payments p ON p.booking_id = b.id
    WHERE b.status = 'pending'
      AND p.status IN ('pending','processing')
      AND b.created_at < now() - make_interval(mins => p_minutes)
    FOR UPDATE OF b SKIP LOCKED
  LOOP
    UPDATE public.payments SET status = 'failed', provider_status = coalesce(provider_status,'EXPIRED')
      WHERE booking_id = r.booking_id AND status IN ('pending','processing');
    UPDATE public.bookings SET status = 'cancelled', payment_status = 'failed', updated_at = now()
      WHERE id = r.booking_id;
    UPDATE public.schedule_seats SET status = 'available', booked_by_booking_id = NULL
      WHERE booked_by_booking_id = r.booking_id AND status = 'held';
    UPDATE public.schedules SET available_seats = (
        SELECT count(*) FROM public.schedule_seats WHERE schedule_id = r.schedule_id AND status = 'available')
      WHERE id = r.schedule_id;
    n := n + 1;
  END LOOP;
  RETURN n;
END;
$$;
REVOKE ALL ON FUNCTION public.release_expired_holds(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.release_expired_holds(integer) TO authenticated, service_role;

-- Optional: run it every minute when pg_cron is available (Database > Extensions > pg_cron).
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('release-expired-seat-holds', '* * * * *', 'select public.release_expired_holds(10)');
  END IF;
EXCEPTION WHEN OTHERS THEN NULL; END $$;

-- ---------------------------------------------------------------------------
-- 6. Booking + payment functions (fixed: expiry, idempotency, seat counts)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reserve_booking(
  p_company_id uuid, p_schedule_id uuid, p_route_id uuid, p_customer_id uuid,
  p_seat_numbers jsonb, p_passenger_count integer, p_base_fare integer,
  p_admin_charge integer, p_flutterwave_charge integer, p_total_amount integer,
  p_currency text DEFAULT 'UGX', p_payment_method text DEFAULT 'mtn_momo',
  p_passenger_details jsonb DEFAULT '[]'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_schedule public.schedules%ROWTYPE;
  v_booking public.bookings%ROWTYPE;
  v_payment public.payments%ROWTYPE;
  v_seat_count integer;
  v_distinct integer;
BEGIN
  IF auth.uid() IS NULL OR auth.uid() <> p_customer_id THEN
    RAISE EXCEPTION 'You must be signed in as the booking customer';
  END IF;
  IF p_payment_method NOT IN ('mtn_momo','airtel_money') THEN
    RAISE EXCEPTION 'Unsupported payment method';
  END IF;
  IF jsonb_typeof(p_seat_numbers) <> 'array' OR jsonb_array_length(p_seat_numbers) = 0 THEN
    RAISE EXCEPTION 'At least one seat is required';
  END IF;
  SELECT count(*) INTO v_distinct FROM (SELECT DISTINCT value FROM jsonb_array_elements_text(p_seat_numbers)) s;
  IF v_distinct <> jsonb_array_length(p_seat_numbers) THEN RAISE EXCEPTION 'Duplicate seats are not allowed'; END IF;
  IF p_total_amount < 0 OR p_base_fare < 0 OR p_admin_charge < 0 OR p_flutterwave_charge < 0 THEN
    RAISE EXCEPTION 'Amounts cannot be negative';
  END IF;

  PERFORM public.release_expired_holds(10);

  SELECT * INTO v_schedule FROM public.schedules WHERE id = p_schedule_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Schedule not found'; END IF;
  IF v_schedule.company_id <> p_company_id THEN RAISE EXCEPTION 'Company does not own this schedule'; END IF;
  IF v_schedule.status <> 'scheduled' THEN RAISE EXCEPTION 'This schedule is not open for booking'; END IF;
  IF v_schedule.departure_datetime IS NOT NULL AND v_schedule.departure_datetime < now() THEN
    RAISE EXCEPTION 'This schedule has already departed';
  END IF;
  -- Price comes from the schedule, not the browser.
  IF v_schedule.base_fare IS NOT NULL
     AND p_total_amount <> v_schedule.base_fare * jsonb_array_length(p_seat_numbers) THEN
    RAISE EXCEPTION 'Fare mismatch; please refresh and try again';
  END IF;

  SELECT count(*) INTO v_seat_count FROM public.schedule_seats
   WHERE schedule_id = p_schedule_id
     AND seat_number IN (SELECT value FROM jsonb_array_elements_text(p_seat_numbers));
  IF v_seat_count <> jsonb_array_length(p_seat_numbers) THEN RAISE EXCEPTION 'One or more seats do not exist'; END IF;
  IF EXISTS (SELECT 1 FROM public.schedule_seats
              WHERE schedule_id = p_schedule_id
                AND seat_number IN (SELECT value FROM jsonb_array_elements_text(p_seat_numbers))
                AND status <> 'available') THEN
    RAISE EXCEPTION 'One or more seats are no longer available';
  END IF;

  INSERT INTO public.bookings (
    customer_id, company_id, schedule_id, route_id, passenger_count, seat_numbers, passenger_details,
    base_fare, admin_charge, flutterwave_charge, total_amount, currency, status, payment_status
  ) VALUES (
    p_customer_id, p_company_id, p_schedule_id, coalesce(p_route_id, v_schedule.route_id),
    coalesce(p_passenger_count, jsonb_array_length(p_seat_numbers)),
    p_seat_numbers, coalesce(p_passenger_details,'[]'::jsonb),
    p_base_fare, p_admin_charge, p_flutterwave_charge, p_total_amount,
    coalesce(p_currency,'UGX'), 'pending', 'pending'
  ) RETURNING * INTO v_booking;

  INSERT INTO public.payments (
    booking_id, company_id, customer_id, amount, base_amount, admin_amount, flutterwave_amount,
    currency, payment_method, status, settlement_status
  ) VALUES (
    v_booking.id, p_company_id, p_customer_id, p_total_amount, p_base_fare, p_admin_charge,
    p_flutterwave_charge, coalesce(p_currency,'UGX'), p_payment_method, 'pending', 'pending'
  ) RETURNING * INTO v_payment;

  UPDATE public.schedule_seats SET status = 'held', booked_by_booking_id = v_booking.id
   WHERE schedule_id = p_schedule_id
     AND seat_number IN (SELECT value FROM jsonb_array_elements_text(p_seat_numbers));
  UPDATE public.schedules SET available_seats = greatest(0, coalesce(available_seats,0) - v_seat_count)
   WHERE id = p_schedule_id;

  RETURN jsonb_build_object('booking', to_jsonb(v_booking), 'payment', to_jsonb(v_payment));
END;
$$;

CREATE OR REPLACE FUNCTION public.finalize_payment(
  p_payment_id uuid, p_success boolean,
  p_provider_reference text DEFAULT NULL, p_provider_status text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_payment public.payments%ROWTYPE;
  v_booking public.bookings%ROWTYPE;
  v_tickets jsonb;
  v_seat_count integer;
BEGIN
  SELECT * INTO v_payment FROM public.payments WHERE id = p_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found'; END IF;
  SELECT * INTO v_booking FROM public.bookings WHERE id = v_payment.booking_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Booking not found'; END IF;

  -- Idempotent: a finished payment is never changed again (webhook + polling can both call this).
  IF v_payment.status IN ('successful','failed','refunded') THEN
    SELECT coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) INTO v_tickets FROM public.tickets t WHERE t.booking_id = v_booking.id;
    RETURN jsonb_build_object('booking', to_jsonb(v_booking), 'payment', to_jsonb(v_payment), 'tickets', v_tickets);
  END IF;

  IF p_success THEN
    UPDATE public.payments SET status='successful', provider_status=coalesce(p_provider_status,'SUCCESSFUL'),
           provider_reference=coalesce(p_provider_reference, provider_reference),
           settlement_status=coalesce(settlement_status,'pending')
     WHERE id = v_payment.id;
    UPDATE public.bookings SET status='confirmed', payment_status='successful', updated_at=now() WHERE id = v_booking.id;
    UPDATE public.schedule_seats SET status='booked' WHERE booked_by_booking_id = v_booking.id;

    INSERT INTO public.tickets (booking_id, passenger_name, seat_number, status)
    SELECT v_booking.id,
           nullif(coalesce(v_booking.passenger_details -> (ord::int - 1) ->> 'name',
                           v_booking.passenger_details -> 0 ->> 'name'), ''),
           seat.value, 'valid'
    FROM jsonb_array_elements_text(v_booking.seat_numbers) WITH ORDINALITY AS seat(value, ord)
    WHERE NOT EXISTS (SELECT 1 FROM public.tickets t WHERE t.booking_id = v_booking.id AND t.seat_number = seat.value);
  ELSE
    UPDATE public.payments SET status='failed', provider_status=coalesce(p_provider_status,'FAILED'),
           provider_reference=coalesce(p_provider_reference, provider_reference)
     WHERE id = v_payment.id;
    UPDATE public.bookings SET status='cancelled', payment_status='failed', updated_at=now() WHERE id = v_booking.id;
    SELECT count(*) INTO v_seat_count FROM public.schedule_seats WHERE booked_by_booking_id = v_booking.id;
    UPDATE public.schedule_seats SET status='available', booked_by_booking_id=NULL WHERE booked_by_booking_id = v_booking.id;
    UPDATE public.schedules SET available_seats = coalesce(available_seats,0) + v_seat_count WHERE id = v_booking.schedule_id;
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) INTO v_tickets FROM public.tickets t WHERE t.booking_id = v_booking.id;
  SELECT * INTO v_payment FROM public.payments WHERE id = v_payment.id;
  SELECT * INTO v_booking FROM public.bookings WHERE id = v_booking.id;
  RETURN jsonb_build_object('booking', to_jsonb(v_booking), 'payment', to_jsonb(v_payment), 'tickets', v_tickets);
END;
$$;

-- IMPORTANT: Postgres grants EXECUTE to PUBLIC by default. Without these REVOKEs anyone could call
-- finalize_payment() from the browser and mark a payment as paid.
REVOKE ALL ON FUNCTION public.finalize_payment(uuid, boolean, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.finalize_payment(uuid, boolean, text, text) TO service_role;
REVOKE ALL ON FUNCTION public.reserve_booking(uuid, uuid, uuid, uuid, jsonb, integer, integer, integer, integer, integer, text, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reserve_booking(uuid, uuid, uuid, uuid, jsonb, integer, integer, integer, integer, integer, text, text, jsonb) TO authenticated;

-- ---------------------------------------------------------------------------
-- 7. RLS: replace every policy on these tables with a clean, consistent set.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.current_user_is_admin() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.users WHERE id = auth.uid() AND role = 'admin' AND status = 'active');
$$;
CREATE OR REPLACE FUNCTION public.current_user_owns_company(p_company_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.bus_companies WHERE id = p_company_id AND owner_id = auth.uid());
$$;
GRANT EXECUTE ON FUNCTION public.current_user_is_admin() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.current_user_owns_company(uuid) TO anon, authenticated;

DO $$
DECLARE p record; t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['admin_settings','audit_logs','bookings','branches','bus_companies','buses',
    'company_documents','financial_ledger','notifications','payments','registration_payments','routes',
    'schedule_seats','schedules','support_settings','tickets','users'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    FOR p IN SELECT policyname FROM pg_policies WHERE schemaname='public' AND tablename=t LOOP
      EXECUTE format('DROP POLICY %I ON public.%I', p.policyname, t);
    END LOOP;
  END LOOP;
END $$;

-- users
CREATE POLICY users_select ON public.users FOR SELECT TO authenticated
  USING (id = auth.uid() OR public.current_user_is_admin());
CREATE POLICY users_update ON public.users FOR UPDATE TO authenticated
  USING (id = auth.uid() OR public.current_user_is_admin())
  WITH CHECK ((id = auth.uid() AND role = 'customer') OR public.current_user_is_admin()); -- cannot self-promote
-- (inserts happen via the auth trigger, which bypasses RLS)

-- companies
CREATE POLICY companies_read ON public.bus_companies FOR SELECT TO anon, authenticated
  USING ((approval_status = 'approved' AND coalesce(status,'approved') NOT IN ('deleted','suspended'))
         OR owner_id = auth.uid() OR public.current_user_is_admin());
CREATE POLICY companies_owner_update ON public.bus_companies FOR UPDATE TO authenticated
  USING (owner_id = auth.uid()) WITH CHECK (owner_id = auth.uid());
CREATE POLICY companies_admin_all ON public.bus_companies FOR ALL TO authenticated
  USING (public.current_user_is_admin()) WITH CHECK (public.current_user_is_admin());
-- NOTE: owners can edit their profile; approval fields are protected by the trigger below.

-- catalogue: public read of live data, owner/admin write
CREATE POLICY buses_rw ON public.buses FOR ALL TO authenticated
  USING (public.current_user_owns_company(company_id) OR public.current_user_is_admin())
  WITH CHECK (public.current_user_owns_company(company_id) OR public.current_user_is_admin());
CREATE POLICY branches_rw ON public.branches FOR ALL TO authenticated
  USING (public.current_user_owns_company(company_id) OR public.current_user_is_admin())
  WITH CHECK (public.current_user_owns_company(company_id) OR public.current_user_is_admin());
CREATE POLICY routes_read ON public.routes FOR SELECT TO anon, authenticated
  USING (status = 'active' OR public.current_user_owns_company(company_id) OR public.current_user_is_admin());
CREATE POLICY routes_write ON public.routes FOR ALL TO authenticated
  USING (public.current_user_owns_company(company_id) OR public.current_user_is_admin())
  WITH CHECK (public.current_user_owns_company(company_id) OR public.current_user_is_admin());
CREATE POLICY schedules_read ON public.schedules FOR SELECT TO anon, authenticated
  USING (status = 'scheduled' OR public.current_user_owns_company(company_id) OR public.current_user_is_admin());
CREATE POLICY schedules_write ON public.schedules FOR ALL TO authenticated
  USING (public.current_user_owns_company(company_id) OR public.current_user_is_admin())
  WITH CHECK (public.current_user_owns_company(company_id) OR public.current_user_is_admin());
CREATE POLICY seats_read ON public.schedule_seats FOR SELECT TO anon, authenticated
  USING (EXISTS (SELECT 1 FROM public.schedules s WHERE s.id = schedule_seats.schedule_id
                 AND (s.status = 'scheduled' OR public.current_user_owns_company(s.company_id) OR public.current_user_is_admin())));
-- Companies may only block/unblock seats; booking/holding is done by the SECURITY DEFINER functions.
CREATE POLICY seats_company_update ON public.schedule_seats FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.schedules s WHERE s.id = schedule_seats.schedule_id
                 AND (public.current_user_owns_company(s.company_id) OR public.current_user_is_admin())))
  WITH CHECK (status IN ('available','blocked'));

-- private money data: read-only from the browser. All writes go through functions / Edge Functions.
CREATE POLICY bookings_read ON public.bookings FOR SELECT TO authenticated
  USING (customer_id = auth.uid() OR public.current_user_owns_company(company_id) OR public.current_user_is_admin());
CREATE POLICY payments_read ON public.payments FOR SELECT TO authenticated
  USING (customer_id = auth.uid() OR public.current_user_owns_company(company_id) OR public.current_user_is_admin());
CREATE POLICY tickets_read ON public.tickets FOR SELECT TO authenticated
  USING (public.current_user_is_admin() OR EXISTS (
    SELECT 1 FROM public.bookings b WHERE b.id = tickets.booking_id
      AND (b.customer_id = auth.uid() OR public.current_user_owns_company(b.company_id))));
-- Companies may mark their own tickets as used (boarding check) but nothing else.
CREATE POLICY tickets_company_update ON public.tickets FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.bookings b WHERE b.id = tickets.booking_id AND public.current_user_owns_company(b.company_id)))
  WITH CHECK (status IN ('valid','used'));
CREATE POLICY financial_ledger_read ON public.financial_ledger FOR SELECT TO authenticated
  USING (public.current_user_owns_company(company_id) OR public.current_user_is_admin());
CREATE POLICY registration_payments_read ON public.registration_payments FOR SELECT TO authenticated
  USING (public.current_user_owns_company(company_id) OR public.current_user_is_admin());
CREATE POLICY company_documents_rw ON public.company_documents FOR ALL TO authenticated
  USING (public.current_user_owns_company(company_id) OR public.current_user_is_admin())
  WITH CHECK (public.current_user_owns_company(company_id) OR public.current_user_is_admin());

-- notifications / support / admin
CREATE POLICY notifications_read ON public.notifications FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.current_user_owns_company(company_id) OR public.current_user_is_admin());
CREATE POLICY notifications_update ON public.notifications FOR UPDATE TO authenticated
  USING (user_id = auth.uid() OR public.current_user_owns_company(company_id) OR public.current_user_is_admin())
  WITH CHECK (user_id = auth.uid() OR public.current_user_owns_company(company_id) OR public.current_user_is_admin());
CREATE POLICY notifications_admin_insert ON public.notifications FOR INSERT TO authenticated
  WITH CHECK (public.current_user_is_admin());
CREATE POLICY support_read ON public.support_settings FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY support_admin_write ON public.support_settings FOR ALL TO authenticated
  USING (public.current_user_is_admin()) WITH CHECK (public.current_user_is_admin());
CREATE POLICY admin_settings_admin ON public.admin_settings FOR ALL TO authenticated
  USING (public.current_user_is_admin()) WITH CHECK (public.current_user_is_admin());
CREATE POLICY audit_logs_admin_read ON public.audit_logs FOR SELECT TO authenticated
  USING (public.current_user_is_admin());
CREATE POLICY audit_logs_admin_insert ON public.audit_logs FOR INSERT TO authenticated
  WITH CHECK (public.current_user_is_admin());

-- Company owners must not be able to approve themselves or change payout/approval fields.
CREATE OR REPLACE FUNCTION public.protect_company_admin_fields() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.current_user_is_admin() AND auth.uid() IS NOT NULL THEN
    NEW.approval_status := OLD.approval_status;
    NEW.status := OLD.status;
    NEW.owner_id := OLD.owner_id;
    NEW.registration_fee_amount := OLD.registration_fee_amount;
    NEW.rejection_reason := OLD.rejection_reason;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS bus_companies_protect_fields ON public.bus_companies;
CREATE TRIGGER bus_companies_protect_fields BEFORE UPDATE ON public.bus_companies
  FOR EACH ROW EXECUTE FUNCTION public.protect_company_admin_fields();

-- ---------------------------------------------------------------------------
-- 8. Realtime for everything the dashboards subscribe to
-- ---------------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['bookings','payments','tickets','schedule_seats','schedules','routes','buses',
                           'notifications','bus_companies','audit_logs','admin_settings','support_settings'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename=t) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
    END IF;
    EXECUTE format('ALTER TABLE public.%I REPLICA IDENTITY FULL', t);
  END LOOP;
END $$;

-- Seed one settings row each so the admin screens have something to update.
INSERT INTO public.admin_settings (mtn_merchant_code, airtel_merchant_code)
SELECT '', '' WHERE NOT EXISTS (SELECT 1 FROM public.admin_settings);
INSERT INTO public.support_settings (audience_type) SELECT 'customer'
 WHERE NOT EXISTS (SELECT 1 FROM public.support_settings WHERE audience_type = 'customer');
INSERT INTO public.support_settings (audience_type) SELECT 'company'
 WHERE NOT EXISTS (SELECT 1 FROM public.support_settings WHERE audience_type = 'company');

-- ---------------------------------------------------------------------------
-- 9. ADMIN BOOTSTRAP — run once, after creating the admin user in Supabase Auth
--    (Authentication > Users > Add user). Replace the email, then run just this statement:
--
--   INSERT INTO public.users (id, full_name, email, role, status)
--   SELECT id, 'Administrator', email, 'admin', 'active' FROM auth.users WHERE email = 'YOU@EXAMPLE.COM'
--   ON CONFLICT (id) DO UPDATE SET role = 'admin', status = 'active';
-- ---------------------------------------------------------------------------

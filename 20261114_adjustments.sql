-- Daily Travel adjustments (run AFTER 20261111_link_apps_fix.sql and 20261113_signup_fix.sql).
-- Idempotent and additive. Adds: pricing/commission settings, branches, multi-destination stops,
-- visibility rules (suspended / past / booking window), server-side pricing, bank payments,
-- notifications, earnings clearing, account purge, registration fee payments and storage buckets.

-- ---------------------------------------------------------------------------
-- 1. Columns and tables
-- ---------------------------------------------------------------------------
-- Make sure buses.staff_seats is a text[] (an older version of the table may have it as jsonb/text).
DO $$
DECLARE v_type text;
BEGIN
  SELECT data_type INTO v_type FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'buses' AND column_name = 'staff_seats';
  IF v_type IS NULL THEN
    ALTER TABLE public.buses ADD COLUMN staff_seats text[] DEFAULT '{}';
  ELSIF v_type <> 'ARRAY' THEN
    ALTER TABLE public.buses ALTER COLUMN staff_seats DROP DEFAULT;
    IF v_type IN ('jsonb', 'json') THEN
      CREATE OR REPLACE FUNCTION public._dt_json_to_text_array(j jsonb) RETURNS text[]
        LANGUAGE sql IMMUTABLE AS $f$
          SELECT CASE WHEN j IS NULL OR jsonb_typeof(j) <> 'array' THEN '{}'::text[]
                      ELSE ARRAY(SELECT jsonb_array_elements_text(j)) END $f$;
      ALTER TABLE public.buses ALTER COLUMN staff_seats TYPE text[] USING public._dt_json_to_text_array(staff_seats::jsonb);
      DROP FUNCTION public._dt_json_to_text_array(jsonb);
    ELSE
      ALTER TABLE public.buses ALTER COLUMN staff_seats TYPE text[] USING
        CASE WHEN staff_seats IS NULL OR btrim(staff_seats::text) IN ('', '[]', '{}') THEN '{}'::text[]
             ELSE string_to_array(regexp_replace(staff_seats::text, '[\[\]{}"'' ]', '', 'g'), ',') END;
    END IF;
    ALTER TABLE public.buses ALTER COLUMN staff_seats SET DEFAULT '{}';
  END IF;
END $$;

ALTER TABLE public.admin_settings
  ADD COLUMN IF NOT EXISTS commission_percent numeric DEFAULT 2,
  ADD COLUMN IF NOT EXISTS registration_fee_amount integer DEFAULT 0,
  ADD COLUMN IF NOT EXISTS bank_name text,
  ADD COLUMN IF NOT EXISTS bank_account_name text,
  ADD COLUMN IF NOT EXISTS bank_account_number text;
UPDATE public.admin_settings SET commission_percent = 2 WHERE commission_percent IS NULL;
UPDATE public.admin_settings SET registration_fee_amount = 0 WHERE registration_fee_amount IS NULL;

ALTER TABLE public.bus_companies
  ADD COLUMN IF NOT EXISTS booking_window_days integer DEFAULT 5,
  ADD COLUMN IF NOT EXISTS support_phone text,
  ADD COLUMN IF NOT EXISTS support_email text,
  ADD COLUMN IF NOT EXISTS registration_fee_amount integer;
-- NULL = use the platform default, 0 = fee removed for this company.
ALTER TABLE public.bus_companies ALTER COLUMN registration_fee_amount DROP DEFAULT;
ALTER TABLE public.bus_companies ALTER COLUMN registration_fee_amount DROP NOT NULL;

CREATE TABLE IF NOT EXISTS public.registration_payments (id uuid PRIMARY KEY DEFAULT gen_random_uuid());
ALTER TABLE public.registration_payments
  ADD COLUMN IF NOT EXISTS company_id uuid,
  ADD COLUMN IF NOT EXISTS amount integer,
  ADD COLUMN IF NOT EXISTS method text,
  ADD COLUMN IF NOT EXISTS reference text,
  ADD COLUMN IF NOT EXISTS status text DEFAULT 'submitted',
  ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now(),
  ADD COLUMN IF NOT EXISTS confirmed_at timestamptz;

ALTER TABLE public.branches
  ADD COLUMN IF NOT EXISTS name text,
  ADD COLUMN IF NOT EXISTS location text,
  ADD COLUMN IF NOT EXISTS manager_name text,
  ADD COLUMN IF NOT EXISTS manager_phone text,
  ADD COLUMN IF NOT EXISTS manager_email text,
  ADD COLUMN IF NOT EXISTS status text DEFAULT 'active',
  ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now();

ALTER TABLE public.routes ADD COLUMN IF NOT EXISTS branch_id uuid;
ALTER TABLE public.schedules
  ADD COLUMN IF NOT EXISTS branch_id uuid,
  ADD COLUMN IF NOT EXISTS layout text,
  ADD COLUMN IF NOT EXISTS seat_total integer;
ALTER TABLE public.schedule_seats ADD COLUMN IF NOT EXISTS label text;

CREATE TABLE IF NOT EXISTS public.schedule_stops (id uuid PRIMARY KEY DEFAULT gen_random_uuid());
ALTER TABLE public.schedule_stops
  ADD COLUMN IF NOT EXISTS schedule_id uuid REFERENCES public.schedules(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS company_id uuid,
  ADD COLUMN IF NOT EXISTS destination_city text,
  ADD COLUMN IF NOT EXISTS destination_terminal text,
  ADD COLUMN IF NOT EXISTS price integer,
  ADD COLUMN IF NOT EXISTS sort_order integer DEFAULT 0,
  ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now();
CREATE INDEX IF NOT EXISTS schedule_stops_schedule_idx ON public.schedule_stops (schedule_id);

ALTER TABLE public.bookings
  ADD COLUMN IF NOT EXISTS stop_id uuid,
  ADD COLUMN IF NOT EXISTS destination_city text;
ALTER TABLE public.payments
  ADD COLUMN IF NOT EXISTS company_hidden boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS settled_at timestamptz,
  ADD COLUMN IF NOT EXISTS settlement_reference text;

-- Older schemas restrict payment_method to MTN/Airtel; bank payments need to be allowed too.
DO $$
DECLARE c record;
BEGIN
  FOR c IN SELECT conname FROM pg_constraint
           WHERE contype='c' AND conrelid IN ('public.payments'::regclass, 'public.bookings'::regclass)
             AND pg_get_constraintdef(oid) ILIKE '%payment_method%'
  LOOP
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I',
                   (SELECT conrelid::regclass FROM pg_constraint WHERE conname = c.conname LIMIT 1), c.conname);
  END LOOP;
END $$;
DO $$
DECLARE c record;
BEGIN
  FOR c IN SELECT conname FROM pg_constraint
           WHERE contype='c' AND conrelid='public.payments'::regclass AND pg_get_constraintdef(oid) ILIKE '%settlement_status%'
  LOOP
    EXECUTE format('ALTER TABLE public.payments DROP CONSTRAINT %I', c.conname);
  END LOOP;
END $$;

-- Notifications: new audience model
ALTER TABLE public.notifications
  ADD COLUMN IF NOT EXISTS audience_type text,
  ADD COLUMN IF NOT EXISTS user_id uuid,
  ADD COLUMN IF NOT EXISTS company_id uuid,
  ADD COLUMN IF NOT EXISTS sender_company_id uuid,
  ADD COLUMN IF NOT EXISTS sender_role text DEFAULT 'system',
  ADD COLUMN IF NOT EXISTS kind text DEFAULT 'message',
  ADD COLUMN IF NOT EXISTS booking_id uuid,
  ADD COLUMN IF NOT EXISTS dedupe_key text,
  ADD COLUMN IF NOT EXISTS is_read boolean DEFAULT false;
ALTER TABLE public.notifications ALTER COLUMN audience_type DROP DEFAULT;
ALTER TABLE public.notifications ALTER COLUMN audience_type DROP NOT NULL;
-- the old schema may restrict audience_type / type values
DO $$
DECLARE c record;
BEGIN
  FOR c IN SELECT conname FROM pg_constraint
           WHERE contype='c' AND conrelid='public.notifications'::regclass
  LOOP
    EXECUTE format('ALTER TABLE public.notifications DROP CONSTRAINT %I', c.conname);
  END LOOP;
END $$;
UPDATE public.notifications SET audience_type = CASE
    WHEN user_id IS NOT NULL THEN 'customer'
    WHEN company_id IS NOT NULL THEN 'company'
    ELSE 'customer_broadcast' END
 WHERE audience_type IS NULL OR audience_type NOT IN
   ('customer','customer_broadcast','company','company_broadcast','admin');
CREATE UNIQUE INDEX IF NOT EXISTS notifications_dedupe_key_idx ON public.notifications (dedupe_key);

CREATE TABLE IF NOT EXISTS public.notification_reads (
  notification_id uuid NOT NULL REFERENCES public.notifications(id) ON DELETE CASCADE,
  reader_id uuid NOT NULL,
  read_at timestamptz DEFAULT now(),
  PRIMARY KEY (notification_id, reader_id)
);

-- Foreign keys that would block account/company deletion: keep history, drop the link instead.
CREATE OR REPLACE FUNCTION public._dt_fk_set_null(p_table text, p_col text, p_ref text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE c record;
BEGIN
  IF to_regclass('public.' || p_table) IS NULL THEN RETURN; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name=p_table AND column_name=p_col) THEN RETURN; END IF;
  EXECUTE format('ALTER TABLE public.%I ALTER COLUMN %I DROP NOT NULL', p_table, p_col);
  FOR c IN
    SELECT con.conname FROM pg_constraint con
    JOIN pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = ANY (con.conkey)
    WHERE con.contype = 'f' AND con.conrelid = ('public.' || p_table)::regclass AND att.attname = p_col
  LOOP
    EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT %I', p_table, c.conname);
  END LOOP;
  EXECUTE format('ALTER TABLE public.%I ADD FOREIGN KEY (%I) REFERENCES public.%I(id) ON DELETE SET NULL', p_table, p_col, p_ref);
END $$;
DO $$ BEGIN
PERFORM public._dt_fk_set_null('bookings','company_id','bus_companies');
PERFORM public._dt_fk_set_null('bookings','schedule_id','schedules');
PERFORM public._dt_fk_set_null('bookings','route_id','routes');
PERFORM public._dt_fk_set_null('bookings','branch_id','branches');
PERFORM public._dt_fk_set_null('bookings','customer_id','users');
PERFORM public._dt_fk_set_null('payments','company_id','bus_companies');
PERFORM public._dt_fk_set_null('payments','customer_id','users');
PERFORM public._dt_fk_set_null('financial_ledger','company_id','bus_companies');
PERFORM public._dt_fk_set_null('registration_payments','company_id','bus_companies');
END $$;
DROP FUNCTION public._dt_fk_set_null(text, text, text);

-- ---------------------------------------------------------------------------
-- 2. Visibility helpers (used by RLS): suspended / past / outside window = hidden from customers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.company_is_public(p_company_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.bus_companies c
                 WHERE c.id = p_company_id AND c.approval_status = 'approved'
                   AND coalesce(c.status,'approved') NOT IN ('suspended','deleted','rejected','pending'));
$$;
CREATE OR REPLACE FUNCTION public.schedule_is_public(p_schedule_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.schedules s JOIN public.bus_companies c ON c.id = s.company_id
    WHERE s.id = p_schedule_id AND s.status = 'scheduled'
      AND s.departure_datetime > now()
      AND s.departure_datetime <= now() + make_interval(days => greatest(coalesce(c.booking_window_days, 5), 1))
      AND c.approval_status = 'approved'
      AND coalesce(c.status,'approved') NOT IN ('suspended','deleted','rejected','pending'));
$$;
CREATE OR REPLACE FUNCTION public.customer_has_booking_with(p_company_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.bookings b WHERE b.company_id = p_company_id AND b.customer_id = auth.uid());
$$;
GRANT EXECUTE ON FUNCTION public.company_is_public(uuid), public.schedule_is_public(uuid),
  public.customer_has_booking_with(uuid) TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. RLS for the changed / new tables
-- ---------------------------------------------------------------------------
DO $$
DECLARE p record; t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['routes','schedules','schedule_seats','schedule_stops','branches','notifications',
                           'notification_reads','registration_payments'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    FOR p IN SELECT policyname FROM pg_policies WHERE schemaname='public' AND tablename=t LOOP
      EXECUTE format('DROP POLICY %I ON public.%I', p.policyname, t);
    END LOOP;
  END LOOP;
END $$;

CREATE POLICY routes_read ON public.routes FOR SELECT TO anon, authenticated
  USING ((status = 'active' AND public.company_is_public(company_id))
         OR public.current_user_owns_company(company_id) OR public.current_user_is_admin());
CREATE POLICY routes_write ON public.routes FOR ALL TO authenticated
  USING (public.current_user_owns_company(company_id) OR public.current_user_is_admin())
  WITH CHECK (public.current_user_owns_company(company_id) OR public.current_user_is_admin());

CREATE POLICY schedules_read ON public.schedules FOR SELECT TO anon, authenticated
  USING (public.schedule_is_public(id) OR public.current_user_owns_company(company_id) OR public.current_user_is_admin());
CREATE POLICY schedules_write ON public.schedules FOR ALL TO authenticated
  USING (public.current_user_owns_company(company_id) OR public.current_user_is_admin())
  WITH CHECK (public.current_user_owns_company(company_id) OR public.current_user_is_admin());

CREATE POLICY seats_read ON public.schedule_seats FOR SELECT TO anon, authenticated
  USING (public.schedule_is_public(schedule_id)
         OR EXISTS (SELECT 1 FROM public.schedules s WHERE s.id = schedule_seats.schedule_id
                    AND (public.current_user_owns_company(s.company_id) OR public.current_user_is_admin())));
CREATE POLICY seats_company_update ON public.schedule_seats FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.schedules s WHERE s.id = schedule_seats.schedule_id
                 AND (public.current_user_owns_company(s.company_id) OR public.current_user_is_admin())))
  WITH CHECK (status IN ('available','blocked'));

CREATE POLICY stops_read ON public.schedule_stops FOR SELECT TO anon, authenticated
  USING (public.schedule_is_public(schedule_id) OR public.current_user_owns_company(company_id) OR public.current_user_is_admin());
CREATE POLICY stops_write ON public.schedule_stops FOR ALL TO authenticated
  USING (public.current_user_owns_company(company_id) OR public.current_user_is_admin())
  WITH CHECK (public.current_user_owns_company(company_id) OR public.current_user_is_admin());

CREATE POLICY branches_read ON public.branches FOR SELECT TO anon, authenticated
  USING (public.company_is_public(company_id) OR public.current_user_owns_company(company_id) OR public.current_user_is_admin());
CREATE POLICY branches_write ON public.branches FOR ALL TO authenticated
  USING (public.current_user_owns_company(company_id) OR public.current_user_is_admin())
  WITH CHECK (public.current_user_owns_company(company_id) OR public.current_user_is_admin());

CREATE POLICY registration_payments_read ON public.registration_payments FOR SELECT TO authenticated
  USING (public.current_user_owns_company(company_id) OR public.current_user_is_admin());
CREATE POLICY registration_payments_admin ON public.registration_payments FOR UPDATE TO authenticated
  USING (public.current_user_is_admin()) WITH CHECK (public.current_user_is_admin());

-- notifications: direct reads follow the audience rules (also drives realtime)
CREATE POLICY notifications_read ON public.notifications FOR SELECT TO authenticated
  USING (
    public.current_user_is_admin()
    OR (audience_type = 'customer' AND user_id = auth.uid())
    OR (audience_type = 'customer_broadcast' AND EXISTS (SELECT 1 FROM public.users u WHERE u.id = auth.uid())
        AND (sender_company_id IS NULL OR public.customer_has_booking_with(sender_company_id)))
    OR (audience_type = 'company' AND public.current_user_owns_company(company_id))
    OR (audience_type = 'company_broadcast' AND EXISTS (SELECT 1 FROM public.bus_companies c WHERE c.owner_id = auth.uid()))
  );
CREATE POLICY notifications_mark_read ON public.notifications FOR UPDATE TO authenticated
  USING ((audience_type = 'customer' AND user_id = auth.uid())
         OR (audience_type = 'company' AND public.current_user_owns_company(company_id))
         OR public.current_user_is_admin())
  WITH CHECK ((audience_type = 'customer' AND user_id = auth.uid())
         OR (audience_type = 'company' AND public.current_user_owns_company(company_id))
         OR public.current_user_is_admin());
CREATE POLICY notification_reads_own ON public.notification_reads FOR ALL TO authenticated
  USING (reader_id = auth.uid()) WITH CHECK (reader_id = auth.uid());

-- ---------------------------------------------------------------------------
-- 4. Schedules: copy bus layout; seats get 'staff' label
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.schedules_fill_from_bus() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE b public.buses%ROWTYPE;
BEGIN
  IF NEW.bus_id IS NOT NULL THEN
    SELECT * INTO b FROM public.buses WHERE id = NEW.bus_id;
    IF FOUND THEN
      NEW.layout := coalesce(NEW.layout, b.layout, '2-3');
      NEW.seat_total := coalesce(NEW.seat_total, b.capacity, 45);
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS schedules_fill_from_bus_trg ON public.schedules;
CREATE TRIGGER schedules_fill_from_bus_trg BEFORE INSERT ON public.schedules
  FOR EACH ROW EXECUTE FUNCTION public.schedules_fill_from_bus();

CREATE OR REPLACE FUNCTION public.generate_schedule_seats() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_capacity integer := 45; v_staff text[] := '{}';
BEGIN
  IF NEW.bus_id IS NOT NULL THEN
    SELECT coalesce(capacity, 45), coalesce(staff_seats, '{}') INTO v_capacity, v_staff FROM public.buses WHERE id = NEW.bus_id;
  END IF;
  INSERT INTO public.schedule_seats (schedule_id, seat_number, status, label)
  SELECT NEW.id, n::text,
         CASE WHEN n::text = ANY (v_staff) THEN 'blocked' ELSE 'available' END,
         CASE WHEN n::text = ANY (v_staff) THEN 'staff' ELSE NULL END
  FROM generate_series(1, greatest(v_capacity, 1)) AS n
  ON CONFLICT (schedule_id, seat_number) DO NOTHING;
  UPDATE public.schedules SET available_seats =
    (SELECT count(*) FROM public.schedule_seats WHERE schedule_id = NEW.id AND status = 'available')
  WHERE id = NEW.id;
  RETURN NEW;
END $$;
UPDATE public.schedule_seats SET label = 'staff'
 WHERE label IS NULL AND status = 'blocked' AND EXISTS (
   SELECT 1 FROM public.schedules s JOIN public.buses b ON b.id = s.bus_id
   WHERE s.id = schedule_seats.schedule_id AND schedule_seats.seat_number = ANY (coalesce(b.staff_seats,'{}')));

-- ---------------------------------------------------------------------------
-- 5. Public pricing / bank / registration fee
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_public_pricing() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT jsonb_build_object(
    'commission_percent', coalesce((SELECT commission_percent FROM public.admin_settings LIMIT 1), 2),
    'registration_fee_amount', coalesce((SELECT registration_fee_amount FROM public.admin_settings LIMIT 1), 0),
    'mtn_merchant_code', coalesce((SELECT mtn_merchant_code FROM public.admin_settings LIMIT 1), ''),
    'airtel_merchant_code', coalesce((SELECT airtel_merchant_code FROM public.admin_settings LIMIT 1), ''),
    'bank_enabled', coalesce((SELECT nullif(bank_account_number,'') IS NOT NULL FROM public.admin_settings LIMIT 1), false));
$$;
CREATE OR REPLACE FUNCTION public.get_bank_details() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT jsonb_build_object('bank_name', bank_name, 'bank_account_name', bank_account_name,
                            'bank_account_number', bank_account_number)
  FROM public.admin_settings LIMIT 1;
$$;
GRANT EXECUTE ON FUNCTION public.get_public_pricing() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_bank_details() TO authenticated;

CREATE OR REPLACE FUNCTION public.set_company_registration_fee(p_company_id uuid, p_amount integer)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.current_user_is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  UPDATE public.bus_companies SET registration_fee_amount = p_amount WHERE id = p_company_id;
END $$;
GRANT EXECUTE ON FUNCTION public.set_company_registration_fee(uuid, integer) TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. Create a schedule together with its destination prices
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_schedule_with_stops(
  p_bus_id uuid, p_route_id uuid, p_branch_id uuid, p_departure timestamptz, p_arrival timestamptz,
  p_base_fare integer, p_stops jsonb DEFAULT '[]'::jsonb
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_bus public.buses%ROWTYPE; v_route public.routes%ROWTYPE; v_id uuid; v_stop jsonb; v_i integer := 0;
BEGIN
  SELECT * INTO v_bus FROM public.buses WHERE id = p_bus_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Bus not found'; END IF;
  IF NOT (public.current_user_owns_company(v_bus.company_id) OR public.current_user_is_admin()) THEN
    RAISE EXCEPTION 'You do not own this bus';
  END IF;
  SELECT * INTO v_route FROM public.routes WHERE id = p_route_id;
  IF NOT FOUND OR v_route.company_id <> v_bus.company_id THEN RAISE EXCEPTION 'Route does not belong to this company'; END IF;
  IF p_departure IS NULL OR p_departure <= now() THEN RAISE EXCEPTION 'Departure must be in the future'; END IF;
  IF coalesce(p_base_fare, 0) <= 0 THEN RAISE EXCEPTION 'Enter the fare for the final destination'; END IF;

  INSERT INTO public.schedules (company_id, bus_id, route_id, branch_id, departure_datetime, arrival_datetime, base_fare, status)
  VALUES (v_bus.company_id, p_bus_id, p_route_id, coalesce(p_branch_id, v_route.branch_id), p_departure, p_arrival, p_base_fare, 'scheduled')
  RETURNING id INTO v_id;

  FOR v_stop IN SELECT * FROM jsonb_array_elements(coalesce(p_stops, '[]'::jsonb)) LOOP
    v_i := v_i + 1;
    IF coalesce(v_stop->>'destination_city','') = '' OR coalesce((v_stop->>'price')::integer, 0) <= 0 THEN
      RAISE EXCEPTION 'Each stop needs a destination and a price';
    END IF;
    INSERT INTO public.schedule_stops (schedule_id, company_id, destination_city, destination_terminal, price, sort_order)
    VALUES (v_id, v_bus.company_id, v_stop->>'destination_city', v_stop->>'destination_terminal', (v_stop->>'price')::integer, v_i);
  END LOOP;
  INSERT INTO public.schedule_stops (schedule_id, company_id, destination_city, destination_terminal, price, sort_order)
  VALUES (v_id, v_bus.company_id, v_route.destination_city, v_route.destination_terminal, p_base_fare, 1000);
  RETURN v_id;
END $$;
GRANT EXECUTE ON FUNCTION public.create_schedule_with_stops(uuid, uuid, uuid, timestamptz, timestamptz, integer, jsonb) TO authenticated;

-- ---------------------------------------------------------------------------
-- 7. Booking: server-side price + commission, stops, bank method
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.reserve_booking(uuid, uuid, uuid, uuid, jsonb, integer, integer, integer, integer, integer, text, text, jsonb);

CREATE OR REPLACE FUNCTION public.reserve_booking(
  p_company_id uuid, p_schedule_id uuid, p_stop_id uuid, p_customer_id uuid, p_seat_numbers jsonb,
  p_passenger_details jsonb, p_payment_method text, p_expected_total integer
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_schedule public.schedules%ROWTYPE; v_stop public.schedule_stops%ROWTYPE;
  v_booking public.bookings%ROWTYPE; v_payment public.payments%ROWTYPE;
  v_seats integer; v_distinct integer; v_fare integer; v_base integer; v_admin integer; v_total integer;
  v_pct numeric; v_dest text;
BEGIN
  IF auth.uid() IS NULL OR auth.uid() <> p_customer_id THEN RAISE EXCEPTION 'You must be signed in as the booking customer'; END IF;
  IF p_payment_method NOT IN ('mtn_momo','airtel_money','bank') THEN RAISE EXCEPTION 'Unsupported payment method'; END IF;
  IF p_payment_method = 'bank' AND NOT coalesce((SELECT nullif(bank_account_number,'') IS NOT NULL FROM public.admin_settings LIMIT 1), false) THEN
    RAISE EXCEPTION 'Bank payment is not available right now';
  END IF;
  IF jsonb_typeof(p_seat_numbers) <> 'array' OR jsonb_array_length(p_seat_numbers) = 0 THEN RAISE EXCEPTION 'At least one seat is required'; END IF;
  v_seats := jsonb_array_length(p_seat_numbers);
  SELECT count(*) INTO v_distinct FROM (SELECT DISTINCT value FROM jsonb_array_elements_text(p_seat_numbers)) s;
  IF v_distinct <> v_seats THEN RAISE EXCEPTION 'Duplicate seats are not allowed'; END IF;

  PERFORM public.release_expired_holds(10);

  SELECT * INTO v_schedule FROM public.schedules WHERE id = p_schedule_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Schedule not found'; END IF;
  IF v_schedule.company_id <> p_company_id THEN RAISE EXCEPTION 'Company does not own this schedule'; END IF;
  IF NOT public.schedule_is_public(p_schedule_id) THEN RAISE EXCEPTION 'This trip is not open for booking'; END IF;

  IF p_stop_id IS NOT NULL THEN
    SELECT * INTO v_stop FROM public.schedule_stops WHERE id = p_stop_id AND schedule_id = p_schedule_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Destination not found for this trip'; END IF;
    v_fare := v_stop.price; v_dest := v_stop.destination_city;
  ELSE
    v_fare := v_schedule.base_fare;
    SELECT destination_city INTO v_dest FROM public.routes WHERE id = v_schedule.route_id;
  END IF;
  IF coalesce(v_fare, 0) <= 0 THEN RAISE EXCEPTION 'This trip has no fare set'; END IF;

  v_pct := coalesce((SELECT commission_percent FROM public.admin_settings LIMIT 1), 2);
  v_base := v_fare * v_seats;
  v_admin := round(v_base * v_pct / 100.0)::integer;
  v_total := v_base + v_admin;
  IF p_expected_total IS DISTINCT FROM v_total THEN RAISE EXCEPTION 'The price changed. Please refresh and try again.'; END IF;

  IF (SELECT count(*) FROM public.schedule_seats WHERE schedule_id = p_schedule_id
        AND seat_number IN (SELECT value FROM jsonb_array_elements_text(p_seat_numbers))) <> v_seats THEN
    RAISE EXCEPTION 'One or more seats do not exist';
  END IF;
  IF EXISTS (SELECT 1 FROM public.schedule_seats WHERE schedule_id = p_schedule_id
               AND seat_number IN (SELECT value FROM jsonb_array_elements_text(p_seat_numbers)) AND status <> 'available') THEN
    RAISE EXCEPTION 'One or more seats are no longer available';
  END IF;

  INSERT INTO public.bookings (customer_id, company_id, schedule_id, route_id, branch_id, stop_id, destination_city,
      passenger_count, seat_numbers, passenger_details, base_fare, admin_charge, flutterwave_charge, total_amount,
      currency, status, payment_status)
  VALUES (p_customer_id, p_company_id, p_schedule_id, v_schedule.route_id, v_schedule.branch_id, p_stop_id, v_dest,
      v_seats, p_seat_numbers, coalesce(p_passenger_details,'[]'::jsonb), v_base, v_admin, 0, v_total,
      'UGX', 'pending', 'pending')
  RETURNING * INTO v_booking;

  INSERT INTO public.payments (booking_id, company_id, customer_id, amount, base_amount, admin_amount, flutterwave_amount,
      currency, payment_method, status, settlement_status)
  VALUES (v_booking.id, p_company_id, p_customer_id, v_total, v_base, v_admin, 0, 'UGX', p_payment_method, 'pending', 'pending')
  RETURNING * INTO v_payment;

  UPDATE public.schedule_seats SET status = 'held', booked_by_booking_id = v_booking.id
   WHERE schedule_id = p_schedule_id AND seat_number IN (SELECT value FROM jsonb_array_elements_text(p_seat_numbers));
  UPDATE public.schedules SET available_seats = greatest(0, coalesce(available_seats,0) - v_seats) WHERE id = p_schedule_id;

  RETURN jsonb_build_object('booking', to_jsonb(v_booking), 'payment', to_jsonb(v_payment));
END $$;
REVOKE ALL ON FUNCTION public.reserve_booking(uuid, uuid, uuid, uuid, jsonb, jsonb, text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reserve_booking(uuid, uuid, uuid, uuid, jsonb, jsonb, text, integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.release_expired_holds(p_minutes integer DEFAULT 10) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r record; n integer := 0;
BEGIN
  FOR r IN
    SELECT b.id AS booking_id, b.schedule_id
    FROM public.bookings b JOIN public.payments p ON p.booking_id = b.id
    WHERE b.status = 'pending' AND p.status IN ('pending','processing')
      AND b.created_at < now() - make_interval(mins => CASE WHEN p.payment_method = 'bank' THEN 60 ELSE p_minutes END)
    FOR UPDATE OF b SKIP LOCKED
  LOOP
    UPDATE public.payments SET status = 'failed', provider_status = coalesce(provider_status,'EXPIRED')
      WHERE booking_id = r.booking_id AND status IN ('pending','processing');
    UPDATE public.bookings SET status = 'cancelled', payment_status = 'failed', updated_at = now() WHERE id = r.booking_id;
    UPDATE public.schedule_seats SET status = 'available', booked_by_booking_id = NULL
      WHERE booked_by_booking_id = r.booking_id AND status = 'held';
    UPDATE public.schedules SET available_seats = (SELECT count(*) FROM public.schedule_seats
        WHERE schedule_id = r.schedule_id AND status = 'available') WHERE id = r.schedule_id;
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.release_expired_holds(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.release_expired_holds(integer) TO authenticated, service_role;

-- finalize_payment: same behaviour as before + notifications
CREATE OR REPLACE FUNCTION public.finalize_payment(
  p_payment_id uuid, p_success boolean, p_provider_reference text DEFAULT NULL, p_provider_status text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_payment public.payments%ROWTYPE; v_booking public.bookings%ROWTYPE; v_tickets jsonb; v_seat_count integer;
  v_company_name text; v_company_owner uuid;
BEGIN
  SELECT * INTO v_payment FROM public.payments WHERE id = p_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found'; END IF;
  SELECT * INTO v_booking FROM public.bookings WHERE id = v_payment.booking_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Booking not found'; END IF;

  IF v_payment.status IN ('successful','failed','refunded') THEN
    SELECT coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) INTO v_tickets FROM public.tickets t WHERE t.booking_id = v_booking.id;
    RETURN jsonb_build_object('booking', to_jsonb(v_booking), 'payment', to_jsonb(v_payment), 'tickets', v_tickets);
  END IF;

  IF p_success THEN
    UPDATE public.payments SET status='successful', provider_status=coalesce(p_provider_status,'SUCCESSFUL'),
           provider_reference=coalesce(p_provider_reference, provider_reference), settlement_status='pending'
     WHERE id = v_payment.id;
    UPDATE public.bookings SET status='confirmed', payment_status='successful', updated_at=now() WHERE id = v_booking.id;
    UPDATE public.schedule_seats SET status='booked' WHERE booked_by_booking_id = v_booking.id;
    INSERT INTO public.tickets (booking_id, passenger_name, seat_number, status)
    SELECT v_booking.id,
           nullif(coalesce(v_booking.passenger_details -> (ord::int - 1) ->> 'name', v_booking.passenger_details -> 0 ->> 'name'), ''),
           seat.value, 'valid'
    FROM jsonb_array_elements_text(v_booking.seat_numbers) WITH ORDINALITY AS seat(value, ord)
    WHERE NOT EXISTS (SELECT 1 FROM public.tickets t WHERE t.booking_id = v_booking.id AND t.seat_number = seat.value);

    SELECT company_name INTO v_company_name FROM public.bus_companies WHERE id = v_booking.company_id;
    IF v_booking.customer_id IS NOT NULL THEN
      INSERT INTO public.notifications (audience_type, user_id, kind, booking_id, title, message, sender_role, dedupe_key)
      VALUES ('customer', v_booking.customer_id, 'payment', v_booking.id, 'Payment received',
              'Your payment for ' || coalesce(v_company_name,'your bus') || ' (' || coalesce(v_booking.destination_city,'') ||
              ') was successful. Seats: ' || (SELECT string_agg(value, ', ') FROM jsonb_array_elements_text(v_booking.seat_numbers)) ||
              '. Booking ' || coalesce(v_booking.booking_reference,''), 'system', v_booking.id || ':payment')
      ON CONFLICT (dedupe_key) DO NOTHING;
    END IF;
    IF v_booking.company_id IS NOT NULL THEN
      INSERT INTO public.notifications (audience_type, company_id, kind, booking_id, title, message, sender_role, dedupe_key)
      VALUES ('company', v_booking.company_id, 'ticket_sale', v_booking.id, 'New ticket purchased',
              'Booking ' || coalesce(v_booking.booking_reference,'') || ': seats ' ||
              (SELECT string_agg(value, ', ') FROM jsonb_array_elements_text(v_booking.seat_numbers)) ||
              ' to ' || coalesce(v_booking.destination_city,'') || '.', 'system', v_booking.id || ':sale')
      ON CONFLICT (dedupe_key) DO NOTHING;
    END IF;
  ELSE
    UPDATE public.payments SET status='failed', provider_status=coalesce(p_provider_status,'FAILED'),
           provider_reference=coalesce(p_provider_reference, provider_reference) WHERE id = v_payment.id;
    UPDATE public.bookings SET status='cancelled', payment_status='failed', updated_at=now() WHERE id = v_booking.id;
    SELECT count(*) INTO v_seat_count FROM public.schedule_seats WHERE booked_by_booking_id = v_booking.id;
    UPDATE public.schedule_seats SET status='available', booked_by_booking_id=NULL WHERE booked_by_booking_id = v_booking.id;
    UPDATE public.schedules SET available_seats = coalesce(available_seats,0) + v_seat_count WHERE id = v_booking.schedule_id;
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) INTO v_tickets FROM public.tickets t WHERE t.booking_id = v_booking.id;
  SELECT * INTO v_payment FROM public.payments WHERE id = v_payment.id;
  SELECT * INTO v_booking FROM public.bookings WHERE id = v_booking.id;
  RETURN jsonb_build_object('booking', to_jsonb(v_booking), 'payment', to_jsonb(v_payment), 'tickets', v_tickets);
END $$;
REVOKE ALL ON FUNCTION public.finalize_payment(uuid, boolean, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.finalize_payment(uuid, boolean, text, text) TO service_role;

CREATE OR REPLACE FUNCTION public.admin_confirm_bank_payment(p_payment_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_method text;
BEGIN
  IF NOT public.current_user_is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  SELECT payment_method INTO v_method FROM public.payments WHERE id = p_payment_id;
  IF v_method IS DISTINCT FROM 'bank' THEN RAISE EXCEPTION 'Only bank payments can be confirmed manually'; END IF;
  RETURN public.finalize_payment(p_payment_id, true, 'bank-confirmed-' || to_char(now(),'YYYYMMDDHH24MISS'), 'CONFIRMED_BY_ADMIN');
END $$;
GRANT EXECUTE ON FUNCTION public.admin_confirm_bank_payment(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.company_clear_earnings(p_before timestamptz DEFAULT now()) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_company uuid; n integer;
BEGIN
  SELECT id INTO v_company FROM public.bus_companies WHERE owner_id = auth.uid();
  IF v_company IS NULL THEN RAISE EXCEPTION 'No company for this account'; END IF;
  UPDATE public.payments SET company_hidden = true
   WHERE company_id = v_company AND status = 'successful' AND created_at < p_before AND coalesce(company_hidden,false) = false;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;
GRANT EXECUTE ON FUNCTION public.company_clear_earnings(timestamptz) TO authenticated;

-- ---------------------------------------------------------------------------
-- 8. Notifications API
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.send_notification(
  p_audience text, p_title text, p_message text, p_user_id uuid DEFAULT NULL, p_company_id uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid; v_my_company uuid; v_is_admin boolean := public.current_user_is_admin();
BEGIN
  IF coalesce(trim(p_title),'') = '' OR coalesce(trim(p_message),'') = '' THEN RAISE EXCEPTION 'Title and message are required'; END IF;
  SELECT id INTO v_my_company FROM public.bus_companies WHERE owner_id = auth.uid();
  IF v_is_admin THEN
    IF p_audience = 'customer_broadcast' OR p_audience = 'company_broadcast' THEN
      INSERT INTO public.notifications (audience_type, kind, title, message, sender_role)
      VALUES (p_audience, 'message', p_title, p_message, 'admin') RETURNING id INTO v_id;
    ELSIF p_audience = 'company' THEN
      IF p_company_id IS NULL THEN RAISE EXCEPTION 'Choose a company'; END IF;
      INSERT INTO public.notifications (audience_type, company_id, kind, title, message, sender_role)
      VALUES ('company', p_company_id, 'message', p_title, p_message, 'admin') RETURNING id INTO v_id;
    ELSIF p_audience = 'customer' THEN
      IF p_user_id IS NULL THEN RAISE EXCEPTION 'Choose a customer'; END IF;
      INSERT INTO public.notifications (audience_type, user_id, kind, title, message, sender_role)
      VALUES ('customer', p_user_id, 'message', p_title, p_message, 'admin') RETURNING id INTO v_id;
    ELSE RAISE EXCEPTION 'Unsupported audience'; END IF;
  ELSIF v_my_company IS NOT NULL THEN
    IF p_audience = 'customer_broadcast' THEN
      INSERT INTO public.notifications (audience_type, sender_company_id, kind, title, message, sender_role)
      VALUES ('customer_broadcast', v_my_company, 'message', p_title, p_message, 'company') RETURNING id INTO v_id;
    ELSIF p_audience = 'customer' THEN
      IF NOT EXISTS (SELECT 1 FROM public.bookings b WHERE b.company_id = v_my_company AND b.customer_id = p_user_id) THEN
        RAISE EXCEPTION 'You can only message customers who booked with you';
      END IF;
      INSERT INTO public.notifications (audience_type, user_id, sender_company_id, kind, title, message, sender_role)
      VALUES ('customer', p_user_id, v_my_company, 'message', p_title, p_message, 'company') RETURNING id INTO v_id;
    ELSE RAISE EXCEPTION 'Unsupported audience'; END IF;
  ELSE
    RAISE EXCEPTION 'Not allowed';
  END IF;
  RETURN v_id;
END $$;
GRANT EXECUTE ON FUNCTION public.send_notification(text, text, text, uuid, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.company_customers()
RETURNS TABLE (user_id uuid, full_name text, phone text, bookings integer, last_booking_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT b.customer_id, max(u.full_name), max(u.phone), count(*)::integer, max(b.created_at)
  FROM public.bookings b JOIN public.users u ON u.id = b.customer_id
  WHERE b.company_id = (SELECT id FROM public.bus_companies WHERE owner_id = auth.uid())
  GROUP BY b.customer_id ORDER BY max(b.created_at) DESC;
$$;
GRANT EXECUTE ON FUNCTION public.company_customers() TO authenticated;

-- INVOKER on purpose: row level security decides what the caller may read.
CREATE OR REPLACE FUNCTION public.my_notifications(p_limit integer DEFAULT 100) RETURNS SETOF jsonb
LANGUAGE sql STABLE AS $$
  SELECT to_jsonb(n) || jsonb_build_object('read',
           coalesce(n.is_read, false) OR EXISTS (SELECT 1 FROM public.notification_reads r
                                                 WHERE r.notification_id = n.id AND r.reader_id = auth.uid()))
  FROM public.notifications n
  ORDER BY n.created_at DESC LIMIT greatest(p_limit, 1);
$$;
GRANT EXECUTE ON FUNCTION public.my_notifications(integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.mark_notification_read(p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL THEN RETURN; END IF;
  -- only for notifications the caller can read
  IF NOT EXISTS (SELECT 1 FROM public.my_notifications(1000) m WHERE (m->>'id')::uuid = p_id) THEN RETURN; END IF;
  UPDATE public.notifications SET is_read = true
   WHERE id = p_id AND ((audience_type = 'customer' AND user_id = auth.uid())
                        OR (audience_type = 'company' AND public.current_user_owns_company(company_id)));
  INSERT INTO public.notification_reads (notification_id, reader_id) VALUES (p_id, auth.uid()) ON CONFLICT DO NOTHING;
END $$;
GRANT EXECUTE ON FUNCTION public.mark_notification_read(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.dispatch_departure_alerts() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r record; n integer := 0; c integer;
BEGIN
  FOR r IN
    SELECT b.id AS booking_id, b.customer_id, s.departure_datetime AS dep, bc.company_name, coalesce(b.destination_city,'') AS dest,
           b.seat_numbers
    FROM public.bookings b JOIN public.schedules s ON s.id = b.schedule_id
    LEFT JOIN public.bus_companies bc ON bc.id = b.company_id
    WHERE b.status = 'confirmed' AND b.customer_id IS NOT NULL
      AND s.departure_datetime - interval '30 minutes' <= now() AND s.departure_datetime + interval '30 minutes' > now()
  LOOP
    IF now() < r.dep THEN
      INSERT INTO public.notifications (audience_type, user_id, kind, booking_id, title, message, sender_role, dedupe_key)
      VALUES ('customer', r.customer_id, 'departure_30', r.booking_id, 'Your bus leaves in 30 minutes',
              coalesce(r.company_name,'Your bus') || ' to ' || r.dest || ' departs at ' || to_char(r.dep AT TIME ZONE 'Africa/Kampala','HH24:MI') ||
              '. Please be at the terminal now.', 'system', r.booking_id || ':departure_30')
      ON CONFLICT (dedupe_key) DO NOTHING;
    ELSE
      INSERT INTO public.notifications (audience_type, user_id, kind, booking_id, title, message, sender_role, dedupe_key)
      VALUES ('customer', r.customer_id, 'departure', r.booking_id, 'It is departure time',
              coalesce(r.company_name,'Your bus') || ' to ' || r.dest || ' is departing now.', 'system', r.booking_id || ':departure')
      ON CONFLICT (dedupe_key) DO NOTHING;
    END IF;
    GET DIAGNOSTICS c = ROW_COUNT; n := n + c;
  END LOOP;
  RETURN n;
END $$;
GRANT EXECUTE ON FUNCTION public.dispatch_departure_alerts() TO authenticated, service_role;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('departure-alerts', '* * * * *', 'select public.dispatch_departure_alerts()');
  END IF;
EXCEPTION WHEN OTHERS THEN NULL; END $$;

-- ---------------------------------------------------------------------------
-- 9. New company registration: notify admin + record the registration fee payment
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_auth_user() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  m jsonb := coalesce(NEW.raw_user_meta_data, '{}'::jsonb);
  v_company uuid; v_fee integer;
BEGIN
  IF m->>'role' = 'company' THEN
    BEGIN
      INSERT INTO public.bus_companies (
        owner_id, company_name, trading_name, registration_number, description, phone, email, address,
        operating_location, rep_name, rep_phone, rep_email, merchant_mtn_code, merchant_airtel_code, status, approval_status
      ) VALUES (
        NEW.id, coalesce(m->>'company_name', split_part(NEW.email,'@',1)), coalesce(m->>'trading_name', m->>'company_name'),
        m->>'registration_number', m->>'description', m->>'phone', NEW.email, m->>'address',
        m->>'operating_location', m->>'rep_name', m->>'rep_phone', m->>'rep_email',
        m->>'merchant_mtn_code', m->>'merchant_airtel_code', 'pending', 'pending')
      RETURNING id INTO v_company;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'handle_new_auth_user: full company insert failed (%), retrying minimal', SQLERRM;
      INSERT INTO public.bus_companies (owner_id, company_name, email, status, approval_status)
      VALUES (NEW.id, coalesce(m->>'company_name', split_part(NEW.email,'@',1)), NEW.email, 'pending', 'pending')
      RETURNING id INTO v_company;
    END;
    BEGIN
      v_fee := coalesce((SELECT registration_fee_amount FROM public.admin_settings LIMIT 1), 0);
      IF v_fee > 0 OR coalesce(m->>'registration_reference','') <> '' THEN
        INSERT INTO public.registration_payments (company_id, amount, method, reference, status)
        VALUES (v_company, v_fee, nullif(m->>'registration_method',''), nullif(m->>'registration_reference',''), 'submitted');
      END IF;
      INSERT INTO public.notifications (audience_type, company_id, kind, title, message, sender_role, dedupe_key)
      VALUES ('admin', v_company, 'registration', 'New company registered',
              coalesce(m->>'company_name','A company') || ' has registered and is waiting for approval.', 'system', v_company || ':registration')
      ON CONFLICT (dedupe_key) DO NOTHING;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'handle_new_auth_user: registration extras failed (%)', SQLERRM;
    END;
  ELSE
    BEGIN
      UPDATE public.users SET email = NULL WHERE lower(email) = lower(NEW.email) AND id <> NEW.id;
      INSERT INTO public.users (id, full_name, phone, email, role, status)
      VALUES (NEW.id, m->>'full_name', m->>'phone', NEW.email, 'customer', 'active') ON CONFLICT (id) DO NOTHING;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'handle_new_auth_user: profile insert failed (%), retrying minimal', SQLERRM;
      BEGIN
        INSERT INTO public.users (id, role, status) VALUES (NEW.id, 'customer', 'active') ON CONFLICT (id) DO NOTHING;
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'handle_new_auth_user: minimal profile insert failed (%)', SQLERRM;
      END;
    END;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS on_auth_user_created_daily_travel ON auth.users;
CREATE TRIGGER on_auth_user_created_daily_travel AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_auth_user();

-- ---------------------------------------------------------------------------
-- 10. Hard delete a company (service role only; used by the delete-account Edge Function)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.purge_company(p_company_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- history is kept without the company link (bookings.* foreign keys are ON DELETE SET NULL)
  UPDATE public.registration_payments SET company_id = NULL WHERE company_id = p_company_id;
  UPDATE public.financial_ledger SET company_id = NULL WHERE company_id = p_company_id;
  DELETE FROM public.notifications WHERE company_id = p_company_id OR sender_company_id = p_company_id;
  DELETE FROM public.schedule_stops WHERE company_id = p_company_id;
  DELETE FROM public.schedule_seats WHERE schedule_id IN (SELECT id FROM public.schedules WHERE company_id = p_company_id);
  DELETE FROM public.schedules WHERE company_id = p_company_id;
  DELETE FROM public.routes WHERE company_id = p_company_id;
  DELETE FROM public.buses WHERE company_id = p_company_id;
  DELETE FROM public.branches WHERE company_id = p_company_id;
  DELETE FROM public.company_documents WHERE company_id = p_company_id;
  DELETE FROM public.bus_companies WHERE id = p_company_id;
END $$;
REVOKE ALL ON FUNCTION public.purge_company(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.purge_company(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 11. Storage buckets: profile pictures and company images (PNG/JPG, 2 MB)
-- ---------------------------------------------------------------------------
DO $$
DECLARE b text;
BEGIN
  IF to_regclass('storage.buckets') IS NULL THEN RETURN; END IF;
  FOREACH b IN ARRAY ARRAY['avatars','company-media'] LOOP
    INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    VALUES (b, b, true, 2097152, ARRAY['image/png','image/jpeg'])
    ON CONFLICT (id) DO UPDATE SET public = true, file_size_limit = 2097152, allowed_mime_types = ARRAY['image/png','image/jpeg'];
    EXECUTE format('DROP POLICY IF EXISTS %I ON storage.objects', b || '_read');
    EXECUTE format('DROP POLICY IF EXISTS %I ON storage.objects', b || '_insert_own');
    EXECUTE format('DROP POLICY IF EXISTS %I ON storage.objects', b || '_update_own');
    EXECUTE format('DROP POLICY IF EXISTS %I ON storage.objects', b || '_delete_own');
    EXECUTE format('CREATE POLICY %I ON storage.objects FOR SELECT USING (bucket_id = %L)', b || '_read', b);
    EXECUTE format('CREATE POLICY %I ON storage.objects FOR INSERT TO authenticated WITH CHECK (bucket_id = %L AND (storage.foldername(name))[1] = auth.uid()::text)', b || '_insert_own', b);
    EXECUTE format('CREATE POLICY %I ON storage.objects FOR UPDATE TO authenticated USING (bucket_id = %L AND (storage.foldername(name))[1] = auth.uid()::text)', b || '_update_own', b);
    EXECUTE format('CREATE POLICY %I ON storage.objects FOR DELETE TO authenticated USING (bucket_id = %L AND (storage.foldername(name))[1] = auth.uid()::text)', b || '_delete_own', b);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 12. Realtime
-- ---------------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['notifications','schedule_stops','branches','registration_payments','schedules','schedule_seats',
                           'bus_companies','payments','bookings','admin_settings'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename=t) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
    END IF;
    EXECUTE format('ALTER TABLE public.%I REPLICA IDENTITY FULL', t);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 13. Profile pictures
-- ---------------------------------------------------------------------------
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS avatar_url text;

-- ---------------------------------------------------------------------------
-- 14. Older live tables may have extra NOT NULL columns (e.g. routes.base_fare) that the apps do not fill.
-- ---------------------------------------------------------------------------
ALTER TABLE public.routes ADD COLUMN IF NOT EXISTS base_fare integer;
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT table_name, column_name FROM information_schema.columns
     WHERE table_schema = 'public' AND is_nullable = 'NO' AND column_default IS NULL
       AND ((table_name = 'routes'   AND column_name NOT IN ('id', 'company_id'))
         OR (table_name = 'branches' AND column_name NOT IN ('id', 'company_id', 'name'))
         OR (table_name = 'buses'    AND column_name NOT IN ('id', 'company_id', 'registration_number')))
  LOOP
    EXECUTE format('ALTER TABLE public.%I ALTER COLUMN %I DROP NOT NULL', r.table_name, r.column_name);
  END LOOP;
END $$;
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS date_of_birth date,
  ADD COLUMN IF NOT EXISTS gender text,
  ADD COLUMN IF NOT EXISTS address text,
  ADD COLUMN IF NOT EXISTS city text,
  ADD COLUMN IF NOT EXISTS nationality text,
  ADD COLUMN IF NOT EXISTS id_number text,
  ADD COLUMN IF NOT EXISTS emergency_contact_name text,
  ADD COLUMN IF NOT EXISTS emergency_contact_phone text;

-- ---------------------------------------------------------------------------
-- 15. Support: company contacts/FAQs shown to customers, and customer -> company support requests
-- ---------------------------------------------------------------------------
ALTER TABLE public.bus_companies
  ADD COLUMN IF NOT EXISTS support_whatsapp text,
  ADD COLUMN IF NOT EXISTS support_hours text,
  ADD COLUMN IF NOT EXISTS support_faqs jsonb DEFAULT '[]'::jsonb;

CREATE TABLE IF NOT EXISTS public.support_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  company_id uuid REFERENCES public.bus_companies(id) ON DELETE CASCADE,
  customer_name text,
  subject text NOT NULL,
  message text NOT NULL,
  status text NOT NULL DEFAULT 'open',
  reply text,
  replied_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS support_requests_company_idx ON public.support_requests (company_id, created_at DESC);
CREATE INDEX IF NOT EXISTS support_requests_user_idx ON public.support_requests (user_id, created_at DESC);
ALTER TABLE public.support_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS support_requests_customer_insert ON public.support_requests;
DROP POLICY IF EXISTS support_requests_read ON public.support_requests;
DROP POLICY IF EXISTS support_requests_company_update ON public.support_requests;
CREATE POLICY support_requests_customer_insert ON public.support_requests FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid() AND company_id IS NOT NULL AND status = 'open' AND reply IS NULL);
CREATE POLICY support_requests_read ON public.support_requests FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.current_user_owns_company(company_id) OR public.current_user_is_admin());
CREATE POLICY support_requests_company_update ON public.support_requests FOR UPDATE TO authenticated
  USING (public.current_user_owns_company(company_id) OR public.current_user_is_admin())
  WITH CHECK (public.current_user_owns_company(company_id) OR public.current_user_is_admin());
GRANT SELECT, INSERT, UPDATE ON public.support_requests TO authenticated;

-- Tell the company about a new request, and the customer about a reply.
CREATE OR REPLACE FUNCTION public.support_request_notify() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.notifications (audience_type, company_id, kind, title, message, sender_role, dedupe_key)
    VALUES ('company', NEW.company_id, 'support', 'New support request',
            coalesce(NEW.customer_name, 'A customer') || ': ' || NEW.subject, 'system', NEW.id || ':new')
    ON CONFLICT (dedupe_key) DO NOTHING;
  ELSIF TG_OP = 'UPDATE' AND NEW.reply IS NOT NULL AND NEW.reply IS DISTINCT FROM OLD.reply THEN
    INSERT INTO public.notifications (audience_type, user_id, kind, title, message, sender_role, dedupe_key)
    VALUES ('customer', NEW.user_id, 'support', 'Reply to your support request',
            NEW.subject || ' - ' || left(NEW.reply, 200), 'company', NEW.id || ':reply:' || extract(epoch FROM now())::bigint)
    ON CONFLICT (dedupe_key) DO NOTHING;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS support_request_notify_trg ON public.support_requests;
CREATE TRIGGER support_request_notify_trg AFTER INSERT OR UPDATE ON public.support_requests
  FOR EACH ROW EXECUTE FUNCTION public.support_request_notify();

-- Public contact details a customer may see for a company (only approved, active ones).
CREATE OR REPLACE FUNCTION public.get_company_support(p_company_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT jsonb_build_object('company_name', c.company_name, 'phone', coalesce(c.support_phone, c.phone),
         'email', coalesce(c.support_email, c.email), 'whatsapp', c.support_whatsapp, 'hours', c.support_hours,
         'faqs', coalesce(c.support_faqs, '[]'::jsonb))
    FROM public.bus_companies c WHERE c.id = p_company_id AND public.company_is_public(c.id);
$$;
GRANT EXECUTE ON FUNCTION public.get_company_support(uuid) TO anon, authenticated;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime')
     AND NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='support_requests') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.support_requests;
  END IF;
END $$;

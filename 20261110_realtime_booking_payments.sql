-- Daily Travel production booking/payment foundation.
-- This migration does not seed credentials and does not open anonymous access.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_rel pr
    JOIN pg_class c ON c.oid = pr.prrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_publication p ON p.oid = pr.prpubid
    WHERE p.pubname = 'supabase_realtime'
      AND n.nspname = 'public'
      AND c.relname = 'bookings'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.bookings;
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_rel pr
    JOIN pg_class c ON c.oid = pr.prrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_publication p ON p.oid = pr.prpubid
    WHERE p.pubname = 'supabase_realtime'
      AND n.nspname = 'public'
      AND c.relname = 'payments'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.payments;
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_rel pr
    JOIN pg_class c ON c.oid = pr.prrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_publication p ON p.oid = pr.prpubid
    WHERE p.pubname = 'supabase_realtime'
      AND n.nspname = 'public'
      AND c.relname = 'tickets'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.tickets;
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_rel pr
    JOIN pg_class c ON c.oid = pr.prrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_publication p ON p.oid = pr.prpubid
    WHERE p.pubname = 'supabase_realtime'
      AND n.nspname = 'public'
      AND c.relname = 'schedule_seats'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.schedule_seats;
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_rel pr
    JOIN pg_class c ON c.oid = pr.prrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_publication p ON p.oid = pr.prpubid
    WHERE p.pubname = 'supabase_realtime'
      AND n.nspname = 'public'
      AND c.relname = 'notifications'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications;
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_rel pr
    JOIN pg_class c ON c.oid = pr.prrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_publication p ON p.oid = pr.prpubid
    WHERE p.pubname = 'supabase_realtime'
      AND n.nspname = 'public'
      AND c.relname = 'bus_companies'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.bus_companies;
  END IF;
END $$;

ALTER TABLE public.bookings REPLICA IDENTITY FULL;
ALTER TABLE public.payments REPLICA IDENTITY FULL;
ALTER TABLE public.tickets REPLICA IDENTITY FULL;
ALTER TABLE public.schedule_seats REPLICA IDENTITY FULL;
ALTER TABLE public.notifications REPLICA IDENTITY FULL;
ALTER TABLE public.bus_companies REPLICA IDENTITY FULL;

CREATE OR REPLACE FUNCTION public.reserve_booking(
  p_company_id uuid,
  p_schedule_id uuid,
  p_route_id uuid,
  p_customer_id uuid,
  p_seat_numbers jsonb,
  p_passenger_count integer,
  p_base_fare integer,
  p_admin_charge integer,
  p_flutterwave_charge integer,
  p_total_amount integer,
  p_currency text DEFAULT 'UGX',
  p_payment_method text DEFAULT 'mtn_momo',
  p_passenger_details jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_schedule public.schedules%ROWTYPE;
  v_booking public.bookings%ROWTYPE;
  v_payment public.payments%ROWTYPE;
  v_seat_count integer;
  v_distinct_seat_count integer;
BEGIN
  IF auth.uid() IS NULL OR auth.uid() <> p_customer_id THEN
    RAISE EXCEPTION 'You must be signed in as the booking customer';
  END IF;
  IF jsonb_typeof(p_seat_numbers) <> 'array' OR jsonb_array_length(p_seat_numbers) = 0 THEN
    RAISE EXCEPTION 'At least one seat is required';
  END IF;
  SELECT count(*) INTO v_distinct_seat_count
  FROM (SELECT DISTINCT value FROM jsonb_array_elements_text(p_seat_numbers)) seats;
  IF v_distinct_seat_count <> jsonb_array_length(p_seat_numbers) THEN
    RAISE EXCEPTION 'Duplicate seats are not allowed';
  END IF;
  IF p_total_amount < 0 OR p_base_fare < 0 OR p_admin_charge < 0 OR p_flutterwave_charge < 0 THEN
    RAISE EXCEPTION 'Amounts cannot be negative';
  END IF;

  SELECT * INTO v_schedule
  FROM public.schedules
  WHERE id = p_schedule_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Schedule not found';
  END IF;
  IF v_schedule.company_id <> p_company_id THEN
    RAISE EXCEPTION 'Company does not own this schedule';
  END IF;

  SELECT count(*) INTO v_seat_count
  FROM public.schedule_seats
  WHERE schedule_id = p_schedule_id
    AND seat_number IN (SELECT value FROM jsonb_array_elements_text(p_seat_numbers));
  IF v_seat_count <> jsonb_array_length(p_seat_numbers) THEN
    RAISE EXCEPTION 'One or more seats do not exist';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM public.schedule_seats
    WHERE schedule_id = p_schedule_id
      AND seat_number IN (SELECT value FROM jsonb_array_elements_text(p_seat_numbers))
      AND status <> 'available'
    FOR UPDATE
  ) THEN
    RAISE EXCEPTION 'One or more seats are no longer available';
  END IF;

  INSERT INTO public.bookings (
    customer_id, company_id, schedule_id, route_id,
    passenger_count, seat_numbers, passenger_details,
    base_fare, admin_charge, flutterwave_charge, total_amount,
    currency, status, payment_status
  ) VALUES (
    p_customer_id, p_company_id, p_schedule_id, p_route_id,
    coalesce(p_passenger_count, jsonb_array_length(p_seat_numbers)),
    p_seat_numbers, coalesce(p_passenger_details, '[]'::jsonb),
    p_base_fare, p_admin_charge, p_flutterwave_charge, p_total_amount,
    coalesce(p_currency, 'UGX'), 'pending', 'pending'
  ) RETURNING * INTO v_booking;

  INSERT INTO public.payments (
    booking_id, company_id, customer_id, amount,
    base_amount, admin_amount, flutterwave_amount,
    currency, payment_method, status, settlement_status
  ) VALUES (
    v_booking.id, p_company_id, p_customer_id, p_total_amount,
    p_base_fare, p_admin_charge, p_flutterwave_charge,
    coalesce(p_currency, 'UGX'), p_payment_method, 'pending', 'pending'
  ) RETURNING * INTO v_payment;

  UPDATE public.schedule_seats
  SET status = 'held', booked_by_booking_id = v_booking.id
  WHERE schedule_id = p_schedule_id
    AND seat_number IN (SELECT value FROM jsonb_array_elements_text(p_seat_numbers));

  UPDATE public.schedules
  SET available_seats = greatest(0, coalesce(available_seats, 0) - v_seat_count)
  WHERE id = p_schedule_id;

  RETURN jsonb_build_object(
    'booking', to_jsonb(v_booking),
    'payment', to_jsonb(v_payment)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.finalize_payment(
  p_payment_id uuid,
  p_success boolean,
  p_provider_reference text DEFAULT NULL,
  p_provider_status text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_payment public.payments%ROWTYPE;
  v_booking public.bookings%ROWTYPE;
  v_ticket_codes jsonb := '[]'::jsonb;
  v_seat_count integer;
BEGIN
  SELECT * INTO v_payment
  FROM public.payments
  WHERE id = p_payment_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Payment not found';
  END IF;
  SELECT * INTO v_booking
  FROM public.bookings
  WHERE id = v_payment.booking_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Booking not found';
  END IF;

  IF p_success THEN
    UPDATE public.payments
    SET status = 'successful',
        provider_status = coalesce(p_provider_status, 'SUCCESSFUL'),
        provider_reference = coalesce(p_provider_reference, provider_reference),
        settlement_status = coalesce(settlement_status, 'pending')
    WHERE id = v_payment.id;

    UPDATE public.bookings
    SET status = 'confirmed', payment_status = 'successful', updated_at = now()
    WHERE id = v_booking.id;

    UPDATE public.schedule_seats
    SET status = 'booked'
    WHERE booked_by_booking_id = v_booking.id;

    INSERT INTO public.tickets (booking_id, passenger_name, seat_number, status)
    SELECT
      v_booking.id,
      nullif(v_booking.passenger_details -> 0 ->> 'name', ''),
      seat_number,
      'valid'
    FROM jsonb_array_elements_text(v_booking.seat_numbers) AS seat_number
    WHERE NOT EXISTS (
      SELECT 1 FROM public.tickets t
      WHERE t.booking_id = v_booking.id
        AND t.seat_number = seat_number
    );
  ELSE
    UPDATE public.payments
    SET status = 'failed',
        provider_status = coalesce(p_provider_status, 'FAILED'),
        provider_reference = coalesce(p_provider_reference, provider_reference)
    WHERE id = v_payment.id;

    UPDATE public.bookings
    SET status = 'cancelled', payment_status = 'failed', updated_at = now()
    WHERE id = v_booking.id;

    SELECT count(*) INTO v_seat_count
    FROM public.schedule_seats
    WHERE booked_by_booking_id = v_booking.id;
    UPDATE public.schedule_seats
    SET status = 'available', booked_by_booking_id = NULL
    WHERE booked_by_booking_id = v_booking.id;
    UPDATE public.schedules
    SET available_seats = coalesce(available_seats, 0) + v_seat_count
    WHERE id = v_booking.schedule_id;
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb)
  INTO v_ticket_codes
  FROM public.tickets t
  WHERE t.booking_id = v_booking.id;

  SELECT * INTO v_payment FROM public.payments WHERE id = v_payment.id;
  SELECT * INTO v_booking FROM public.bookings WHERE id = v_booking.id;
  RETURN jsonb_build_object(
    'booking', to_jsonb(v_booking),
    'payment', to_jsonb(v_payment),
    'tickets', v_ticket_codes
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.reserve_booking(uuid, uuid, uuid, uuid, jsonb, integer, integer, integer, integer, integer, text, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.finalize_payment(uuid, boolean, text, text) TO service_role;

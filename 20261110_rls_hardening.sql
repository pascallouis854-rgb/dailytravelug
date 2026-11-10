-- Least-privilege RLS for Daily Travel.
-- Public catalog/support reads remain available; private and financial data is identity-scoped.

CREATE OR REPLACE FUNCTION public.current_user_is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.users
    WHERE id = auth.uid()
      AND role = 'admin'
      AND status = 'active'
  );
$$;

CREATE OR REPLACE FUNCTION public.current_user_owns_company(p_company_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.bus_companies
    WHERE id = p_company_id
      AND owner_id = auth.uid()
  );
$$;

DO $$
DECLARE
  table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'admin_settings', 'audit_logs', 'bookings', 'branches', 'bus_companies',
    'buses', 'company_documents', 'financial_ledger', 'notifications',
    'payments', 'registration_payments', 'routes', 'schedule_seats',
    'schedules', 'support_settings', 'tickets', 'users'
  ] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'Allow all for anon', table_name);
  END LOOP;
END $$;

-- Users
CREATE POLICY users_select_self_or_admin ON public.users
  FOR SELECT TO authenticated
  USING (id = auth.uid() OR public.current_user_is_admin());
CREATE POLICY users_insert_self_or_admin ON public.users
  FOR INSERT TO authenticated
  WITH CHECK (id = auth.uid() OR public.current_user_is_admin());
CREATE POLICY users_update_self_or_admin ON public.users
  FOR UPDATE TO authenticated
  USING (id = auth.uid() OR public.current_user_is_admin())
  WITH CHECK (id = auth.uid() OR public.current_user_is_admin());

-- Companies: approved companies are public catalog data; owner/admin can manage private fields.
CREATE POLICY companies_public_read ON public.bus_companies
  FOR SELECT TO anon, authenticated
  USING (approval_status = 'approved' OR owner_id = auth.uid() OR public.current_user_is_admin());
CREATE POLICY companies_owner_insert ON public.bus_companies
  FOR INSERT TO authenticated
  WITH CHECK (owner_id = auth.uid() OR public.current_user_is_admin());
CREATE POLICY companies_owner_update ON public.bus_companies
  FOR UPDATE TO authenticated
  USING (owner_id = auth.uid() OR public.current_user_is_admin())
  WITH CHECK (owner_id = auth.uid() OR public.current_user_is_admin());
CREATE POLICY companies_admin_delete ON public.bus_companies
  FOR DELETE TO authenticated
  USING (public.current_user_is_admin());

-- Public catalog reads; writes are company/admin controlled.
CREATE POLICY routes_public_read ON public.routes
  FOR SELECT TO anon, authenticated
  USING (status = 'active' OR public.current_user_owns_company(company_id) OR public.current_user_is_admin());
CREATE POLICY routes_company_write ON public.routes
  FOR ALL TO authenticated
  USING (public.current_user_owns_company(company_id) OR public.current_user_is_admin())
  WITH CHECK (public.current_user_owns_company(company_id) OR public.current_user_is_admin());

CREATE POLICY schedules_public_read ON public.schedules
  FOR SELECT TO anon, authenticated
  USING (status = 'scheduled' OR public.current_user_owns_company(company_id) OR public.current_user_is_admin());
CREATE POLICY schedules_company_write ON public.schedules
  FOR ALL TO authenticated
  USING (public.current_user_owns_company(company_id) OR public.current_user_is_admin())
  WITH CHECK (public.current_user_owns_company(company_id) OR public.current_user_is_admin());

CREATE POLICY seats_public_read ON public.schedule_seats
  FOR SELECT TO anon, authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.schedules s
      WHERE s.id = schedule_seats.schedule_id
        AND (s.status = 'scheduled' OR public.current_user_owns_company(s.company_id) OR public.current_user_is_admin())
    )
  );
CREATE POLICY seats_company_write ON public.schedule_seats
  FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.schedules s
      WHERE s.id = schedule_seats.schedule_id
        AND (public.current_user_owns_company(s.company_id) OR public.current_user_is_admin())
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.schedules s
      WHERE s.id = schedule_seats.schedule_id
        AND (public.current_user_owns_company(s.company_id) OR public.current_user_is_admin())
    )
  );

-- Private bookings/payments/tickets.
CREATE POLICY bookings_select_owner_company_admin ON public.bookings
  FOR SELECT TO authenticated
  USING (customer_id = auth.uid() OR public.current_user_owns_company(company_id) OR public.current_user_is_admin());
CREATE POLICY bookings_insert_owner_or_admin ON public.bookings
  FOR INSERT TO authenticated
  WITH CHECK (customer_id = auth.uid() OR public.current_user_is_admin());
CREATE POLICY bookings_update_owner_company_admin ON public.bookings
  FOR UPDATE TO authenticated
  USING (customer_id = auth.uid() OR public.current_user_owns_company(company_id) OR public.current_user_is_admin())
  WITH CHECK (customer_id = auth.uid() OR public.current_user_owns_company(company_id) OR public.current_user_is_admin());

CREATE POLICY payments_select_owner_company_admin ON public.payments
  FOR SELECT TO authenticated
  USING (customer_id = auth.uid() OR public.current_user_owns_company(company_id) OR public.current_user_is_admin());
CREATE POLICY payments_insert_owner_or_admin ON public.payments
  FOR INSERT TO authenticated
  WITH CHECK (customer_id = auth.uid() OR public.current_user_is_admin());

CREATE POLICY tickets_select_owner_company_admin ON public.tickets
  FOR SELECT TO authenticated
  USING (
    public.current_user_is_admin()
    OR EXISTS (
      SELECT 1 FROM public.bookings b
      WHERE b.id = tickets.booking_id
        AND (b.customer_id = auth.uid() OR public.current_user_owns_company(b.company_id))
    )
  );

-- Notifications and support.
CREATE POLICY notifications_select_recipient ON public.notifications
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.current_user_is_admin() OR public.current_user_owns_company(company_id));
CREATE POLICY notifications_update_recipient ON public.notifications
  FOR UPDATE TO authenticated
  USING (user_id = auth.uid() OR public.current_user_is_admin())
  WITH CHECK (user_id = auth.uid() OR public.current_user_is_admin());
CREATE POLICY notifications_admin_insert ON public.notifications
  FOR INSERT TO authenticated
  WITH CHECK (public.current_user_is_admin());

CREATE POLICY support_public_read ON public.support_settings
  FOR SELECT TO anon, authenticated
  USING (true);
CREATE POLICY support_admin_write ON public.support_settings
  FOR ALL TO authenticated
  USING (public.current_user_is_admin())
  WITH CHECK (public.current_user_is_admin());

-- Company operations and finance.
CREATE POLICY branches_company_admin ON public.branches
  FOR ALL TO authenticated
  USING (public.current_user_owns_company(company_id) OR public.current_user_is_admin())
  WITH CHECK (public.current_user_owns_company(company_id) OR public.current_user_is_admin());
CREATE POLICY buses_company_admin ON public.buses
  FOR ALL TO authenticated
  USING (public.current_user_owns_company(company_id) OR public.current_user_is_admin())
  WITH CHECK (public.current_user_owns_company(company_id) OR public.current_user_is_admin());
CREATE POLICY documents_company_admin ON public.company_documents
  FOR ALL TO authenticated
  USING (public.current_user_owns_company(company_id) OR public.current_user_is_admin())
  WITH CHECK (public.current_user_owns_company(company_id) OR public.current_user_is_admin());
CREATE POLICY registration_payments_company_admin ON public.registration_payments
  FOR SELECT TO authenticated
  USING (public.current_user_owns_company(company_id) OR public.current_user_is_admin());
CREATE POLICY ledger_company_admin ON public.financial_ledger
  FOR SELECT TO authenticated
  USING (public.current_user_owns_company(company_id) OR public.current_user_is_admin());
CREATE POLICY admin_settings_admin_only ON public.admin_settings
  FOR ALL TO authenticated
  USING (public.current_user_is_admin())
  WITH CHECK (public.current_user_is_admin());
CREATE POLICY audit_logs_admin_only ON public.audit_logs
  FOR SELECT TO authenticated
  USING (public.current_user_is_admin());
CREATE POLICY audit_logs_admin_insert ON public.audit_logs
  FOR INSERT TO authenticated
  WITH CHECK (public.current_user_is_admin());

GRANT EXECUTE ON FUNCTION public.current_user_is_admin() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.current_user_owns_company(uuid) TO anon, authenticated;

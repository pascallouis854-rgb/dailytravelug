
-- Daily Travel Uganda - TOTAL ONLINE FINAL SCHEMA
-- Admin credentials are intentionally not included. Create the admin in Supabase Auth.
-- Payments: MTN MoMo + Airtel Money ONLY, Real-time disbursement

-- Enable extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- USERS (customers, admins)
CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  full_name TEXT,
  phone TEXT,
  email TEXT UNIQUE,
  password_hash TEXT,
  role TEXT CHECK (role IN ('customer','admin')),
  status TEXT DEFAULT 'active',
  profile_picture TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- BUS COMPANIES with MTN/Airtel merchant codes
CREATE TABLE IF NOT EXISTS bus_companies (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  company_name TEXT NOT NULL,
  trading_name TEXT,
  registration_number TEXT,
  description TEXT,
  phone TEXT,
  email TEXT,
  address TEXT,
  location TEXT,
  representative_name TEXT,
  representative_phone TEXT,
  representative_email TEXT,
  logo_url TEXT,
  photo_urls TEXT[] DEFAULT '{}',
  mtn_momo_code TEXT, -- Where base fare goes if customer pays via MTN
  airtel_money_code TEXT, -- Where base fare goes if via Airtel
  password_hash TEXT,
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending','approved','suspended','deleted')),
  approval_status TEXT DEFAULT 'pending' CHECK (approval_status IN ('pending','approved','suspended','rejected')),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- BRANCHES
CREATE TABLE IF NOT EXISTS branches (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  company_id UUID REFERENCES bus_companies(id) ON DELETE CASCADE,
  branch_name TEXT,
  location TEXT,
  manager_phone TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- BUSES
CREATE TABLE IF NOT EXISTS buses (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  company_id UUID REFERENCES bus_companies(id) ON DELETE CASCADE,
  registration_number TEXT,
  bus_type TEXT,
  capacity INT,
  layout TEXT CHECK (layout IN ('2-2','2-3')),
  staff_seats TEXT[] DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ROUTES
CREATE TABLE IF NOT EXISTS routes (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  company_id UUID REFERENCES bus_companies(id) ON DELETE CASCADE,
  branch_id UUID REFERENCES branches(id) ON DELETE SET NULL,
  origin_terminal TEXT,
  destination_terminal TEXT,
  distance_km INT,
  base_price INT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- SCHEDULES
CREATE TABLE IF NOT EXISTS schedules (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  company_id UUID REFERENCES bus_companies(id) ON DELETE CASCADE,
  bus_id UUID REFERENCES buses(id) ON DELETE SET NULL,
  route_id UUID REFERENCES routes(id) ON DELETE SET NULL,
  departure_datetime TIMESTAMPTZ,
  arrival_datetime TIMESTAMPTZ,
  base_fare INT,
  status TEXT DEFAULT 'active',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- SCHEDULE SEATS (blocking, booking)
CREATE TABLE IF NOT EXISTS schedule_seats (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  schedule_id UUID REFERENCES schedules(id) ON DELETE CASCADE,
  seat_number TEXT,
  status TEXT DEFAULT 'available' CHECK (status IN ('available','booked','blocked','staff')),
  booked_by_booking_id UUID,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(schedule_id, seat_number)
);

-- BOOKINGS
CREATE TABLE IF NOT EXISTS bookings (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  customer_id UUID REFERENCES users(id) ON DELETE SET NULL,
  company_id UUID REFERENCES bus_companies(id) ON DELETE SET NULL,
  schedule_id UUID REFERENCES schedules(id) ON DELETE SET NULL,
  seat_numbers TEXT[],
  base_fare INT,
  admin_charge INT,
  total_amount INT,
  status TEXT DEFAULT 'confirmed',
  payment_status TEXT DEFAULT 'successful',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- PAYMENTS with MTN/Airtel real-time disbursement only
CREATE TABLE IF NOT EXISTS payments (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  booking_id UUID REFERENCES bookings(id) ON DELETE CASCADE,
  company_id UUID REFERENCES bus_companies(id) ON DELETE SET NULL,
  customer_id UUID REFERENCES users(id) ON DELETE SET NULL,
  amount INT,
  base_amount INT, -- to company
  admin_amount INT, -- 2% to admin
  payment_method TEXT CHECK (payment_method IN ('mtn_momo','airtel_money')),
  company_merchant_code_used TEXT, -- company's MTN or Airtel code used
  admin_merchant_code_used TEXT, -- admin's MTN or Airtel code used
  disbursement_status TEXT DEFAULT 'disbursed' CHECK (disbursement_status IN ('disbursed','pending','failed')),
  disbursed_at TIMESTAMPTZ DEFAULT NOW(),
  status TEXT DEFAULT 'successful',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- TICKETS
CREATE TABLE IF NOT EXISTS tickets (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  booking_id UUID REFERENCES bookings(id) ON DELETE CASCADE,
  ticket_code TEXT UNIQUE,
  passenger_name TEXT,
  seat_number TEXT,
  status TEXT DEFAULT 'valid',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- NOTIFICATIONS
CREATE TABLE IF NOT EXISTS notifications (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  recipient_id UUID,
  recipient_type TEXT CHECK (recipient_type IN ('customer','company','admin')),
  audience_type TEXT DEFAULT 'all',
  title TEXT,
  message TEXT,
  is_read BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ADMIN SETTINGS with MTN/Airtel codes only
CREATE TABLE IF NOT EXISTS admin_settings (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  admin_commission_percent INT DEFAULT 2,
  registration_fee INT DEFAULT 0,
  admin_mtn_code TEXT, -- where 2% goes if customer pays via MTN
  admin_airtel_code TEXT, -- where 2% goes if via Airtel
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- SUPPORT SETTINGS
CREATE TABLE IF NOT EXISTS support_settings (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  support_type TEXT CHECK (support_type IN ('customer','company')),
  phone TEXT,
  email TEXT,
  whatsapp TEXT,
  faqs TEXT,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- AUDIT LOGS
CREATE TABLE IF NOT EXISTS audit_logs (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  action TEXT,
  entity_type TEXT,
  entity_id TEXT,
  actor_role TEXT,
  details TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Enable RLS and allow anon for now (tighten later with Auth)
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE bus_companies ENABLE ROW LEVEL SECURITY;
ALTER TABLE branches ENABLE ROW LEVEL SECURITY;
ALTER TABLE buses ENABLE ROW LEVEL SECURITY;
ALTER TABLE routes ENABLE ROW LEVEL SECURITY;
ALTER TABLE schedules ENABLE ROW LEVEL SECURITY;
ALTER TABLE schedule_seats ENABLE ROW LEVEL SECURITY;
ALTER TABLE bookings ENABLE ROW LEVEL SECURITY;
ALTER TABLE payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE tickets ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE support_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "allow_all" ON users;
CREATE POLICY "allow_all" ON users FOR ALL USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "allow_all" ON bus_companies;
CREATE POLICY "allow_all" ON bus_companies FOR ALL USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "allow_all" ON branches;
CREATE POLICY "allow_all" ON branches FOR ALL USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "allow_all" ON buses;
CREATE POLICY "allow_all" ON buses FOR ALL USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "allow_all" ON routes;
CREATE POLICY "allow_all" ON routes FOR ALL USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "allow_all" ON schedules;
CREATE POLICY "allow_all" ON schedules FOR ALL USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "allow_all" ON schedule_seats;
CREATE POLICY "allow_all" ON schedule_seats FOR ALL USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "allow_all" ON bookings;
CREATE POLICY "allow_all" ON bookings FOR ALL USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "allow_all" ON payments;
CREATE POLICY "allow_all" ON payments FOR ALL USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "allow_all" ON tickets;
CREATE POLICY "allow_all" ON tickets FOR ALL USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "allow_all" ON notifications;
CREATE POLICY "allow_all" ON notifications FOR ALL USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "allow_all" ON admin_settings;
CREATE POLICY "allow_all" ON admin_settings FOR ALL USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "allow_all" ON support_settings;
CREATE POLICY "allow_all" ON support_settings FOR ALL USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "allow_all" ON audit_logs;
CREATE POLICY "allow_all" ON audit_logs FOR ALL USING (true) WITH CHECK (true);

-- Enable realtime
ALTER PUBLICATION supabase_realtime ADD TABLE bus_companies;
ALTER PUBLICATION supabase_realtime ADD TABLE bookings;
ALTER PUBLICATION supabase_realtime ADD TABLE schedules;
ALTER PUBLICATION supabase_realtime ADD TABLE payments;

-- No admin seed is included. Create/invite an admin through Supabase Auth.
-- The old plaintext admin seed was intentionally removed.

-- Seed admin settings with MTN/Airtel placeholders
INSERT INTO admin_settings (admin_commission_percent, admin_mtn_code, admin_airtel_code)
VALUES (2, '0770000000', '0750000000')
ON CONFLICT DO NOTHING;

-- Seed support
INSERT INTO support_settings (support_type, phone, email) VALUES ('customer','+256700000000','support@daily.travel') ON CONFLICT DO NOTHING;
INSERT INTO support_settings (support_type, phone, email) VALUES ('company','+256700000001','companies@daily.travel') ON CONFLICT DO NOTHING;

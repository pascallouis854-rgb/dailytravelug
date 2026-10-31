
-- Daily Travel - Supabase Schema - Online Sync Version
-- Run this in Supabase SQL Editor

-- Enable UUID extension
create extension if not exists "uuid-ossp";

-- 1. Platform Settings (single row)
create table if not exists platform_settings (
  id int primary key check (id=1),
  registration_fee integer not null default 50000,
  commission_percent numeric not null default 5,
  admin_mtn_code text,
  admin_airtel_code text,
  admin_bank_name text,
  admin_bank_account text,
  admin_bank_bank text,
  mtn_fee_percent numeric default 1.5,
  airtel_fee_percent numeric default 1.5,
  support_phone text default '+256 700 000000',
  support_manager text default '+256 700 000001',
  support_email text default 'support@dailytravel.ug',
  updated_at timestamp default now()
);
insert into platform_settings (id, registration_fee) values (1,50000) on conflict (id) do nothing;

-- 2. Companies (Bus Companies)
create table if not exists companies (
  id uuid primary key default uuid_generate_v4(),
  name text not null,
  email text unique not null,
  phone text,
  password text not null,
  logo text,
  status text not null default 'pending', -- pending, approved, rejected, suspended
  mtn_code text,
  airtel_code text,
  bank_name text,
  bank_account text,
  bank_bank text,
  registration_paid boolean default false,
  registration_txn_id text,
  created_at timestamp default now(),
  approved_at timestamp
);

-- 3. Branches
create table if not exists branches (
  id uuid primary key default uuid_generate_v4(),
  company_id uuid references companies(id) on delete cascade,
  location text,
  manager_contact text,
  created_at timestamp default now()
);

-- 4. Buses
create table if not exists buses (
  id uuid primary key default uuid_generate_v4(),
  company_id uuid references companies(id) on delete cascade,
  branch_id uuid references branches(id) on delete set null,
  name text,
  plate text,
  capacity int,
  staff_seats int[] default '{}',
  created_at timestamp default now()
);

-- 5. Routes
create table if not exists routes (
  id uuid primary key default uuid_generate_v4(),
  company_id uuid references companies(id) on delete cascade,
  branch_id uuid references branches(id) on delete set null,
  origin text,
  destination text,
  base_price int,
  created_at timestamp default now()
);

-- 6. Schedules (Trips)
create table if not exists schedules (
  id uuid primary key default uuid_generate_v4(),
  route_id uuid references routes(id) on delete cascade,
  bus_id uuid references buses(id) on delete cascade,
  departure bigint, -- timestamp ms
  created_at timestamp default now()
);

-- 7. Users (Customers + Admin)
create table if not exists users (
  id uuid primary key default uuid_generate_v4(),
  role text not null, -- customer, admin
  email text unique,
  phone text,
  password text,
  name text,
  avatar text,
  created_at timestamp default now()
);
-- Seed admin user
insert into users (id, role, email, password, name) values ('00000000-0000-0000-0000-000000000001','admin','admin@dailytravel.ug','admin123','Admin') on conflict (email) do nothing;

-- 8. Seat Blocks (Company marks seats sold offline)
create table if not exists seat_blocks (
  id uuid primary key default uuid_generate_v4(),
  schedule_id uuid references schedules(id) on delete cascade,
  seat_number int not null,
  blocked_by_company_id uuid references companies(id) on delete cascade,
  reason text default 'offline_sale',
  created_at timestamp default now(),
  unique(schedule_id, seat_number)
);

-- 9. Bookings
create table if not exists bookings (
  id uuid primary key default uuid_generate_v4(),
  customer_id uuid references users(id) on delete set null,
  schedule_id uuid references schedules(id) on delete cascade,
  seat_number int not null,
  customer_name text,
  customer_phone text,
  final_price int not null, -- what customer sees/pays
  base_price int not null,
  admin_commission int not null,
  provider_fee int not null,
  company_amount int not null,
  status text default 'confirmed',
  created_at timestamp default now(),
  unique(schedule_id, seat_number)
);

-- 10. Transactions (All money movements)
create table if not exists transactions (
  id uuid primary key default uuid_generate_v4(),
  type text not null, -- registration_fee, ticket_sale
  from_type text, -- customer, company
  from_id uuid,
  to_company_id uuid references companies(id),
  booking_id uuid references bookings(id),
  amount_total int,
  amount_company int,
  amount_admin int,
  amount_provider_fee int,
  provider text, -- mtn, airtel
  status text default 'completed', -- pending, completed, failed
  mtn_txn_id text,
  airtel_txn_id text,
  created_at timestamp default now()
);

-- 11. Notifications
create table if not exists notifications (
  id uuid primary key default uuid_generate_v4(),
  to_user_id uuid references users(id) on delete cascade,
  to_company_id uuid references companies(id) on delete cascade,
  to_role text, -- customer, company
  title text,
  body text,
  read boolean default false,
  from_company_id uuid references companies(id),
  created_at timestamp default now()
);

create table if not exists notifications_admin (
  id uuid primary key default uuid_generate_v4(),
  company_id uuid references companies(id) on delete cascade,
  title text,
  body text,
  read boolean default false,
  created_at timestamp default now()
);

-- 12. Earnings (for dashboard, mirrors transactions)
create table if not exists earnings_admin (
  id uuid primary key default uuid_generate_v4(),
  amount int,
  commission_percent numeric,
  booking_id uuid references bookings(id),
  company_id uuid references companies(id),
  date timestamp default now()
);

create table if not exists earnings_company (
  id uuid primary key default uuid_generate_v4(),
  company_id uuid references companies(id) on delete cascade,
  amount int,
  booking_id uuid references bookings(id),
  date timestamp default now()
);

-- Enable Realtime
alter publication supabase_realtime add table companies, schedules, bookings, seat_blocks, routes, buses, notifications, notifications_admin;

-- RLS (open for anon for this MVP, lock down later with auth)
alter table platform_settings enable row level security;
alter table companies enable row level security;
alter table branches enable row level security;
alter table buses enable row level security;
alter table routes enable row level security;
alter table schedules enable row level security;
alter table users enable row level security;
alter table seat_blocks enable row level security;
alter table bookings enable row level security;
alter table transactions enable row level security;
alter table notifications enable row level security;
alter table notifications_admin enable row level security;
alter table earnings_admin enable row level security;
alter table earnings_company enable row level security;

create policy "open" on platform_settings for all using (true) with check (true);
create policy "open" on companies for all using (true) with check (true);
create policy "open" on branches for all using (true) with check (true);
create policy "open" on buses for all using (true) with check (true);
create policy "open" on routes for all using (true) with check (true);
create policy "open" on schedules for all using (true) with check (true);
create policy "open" on users for all using (true) with check (true);
create policy "open" on seat_blocks for all using (true) with check (true);
create policy "open" on bookings for all using (true) with check (true);
create policy "open" on transactions for all using (true) with check (true);
create policy "open" on notifications for all using (true) with check (true);
create policy "open" on notifications_admin for all using (true) with check (true);
create policy "open" on earnings_admin for all using (true) with check (true);
create policy "open" on earnings_company for all using (true) with check (true);

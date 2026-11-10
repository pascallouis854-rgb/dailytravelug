-- Daily Travel Uganda: read-only verification for the existing Supabase project
-- Run this in Supabase SQL Editor before applying any migration.
-- This script performs no INSERT, UPDATE, DELETE, CREATE, ALTER, or DROP.

SELECT current_database() AS database_name,
       current_setting('server_version') AS postgres_version,
       current_schema() AS schema_name;

SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
ORDER BY table_name;

SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
ORDER BY table_name, ordinal_position;

SELECT tablename, policyname, cmd, permissive
FROM pg_policies
WHERE schemaname = 'public'
ORDER BY tablename, policyname;

SELECT 'users' AS table_name, COUNT(*)::bigint AS row_count FROM public.users
UNION ALL SELECT 'bus_companies', COUNT(*)::bigint FROM public.bus_companies
UNION ALL SELECT 'bookings', COUNT(*)::bigint FROM public.bookings
UNION ALL SELECT 'payments', COUNT(*)::bigint FROM public.payments
UNION ALL SELECT 'schedules', COUNT(*)::bigint FROM public.schedules
UNION ALL SELECT 'tickets', COUNT(*)::bigint FROM public.tickets
ORDER BY table_name;

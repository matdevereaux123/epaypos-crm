-- =============================================================================
-- EPAY POS / Envision ATM Control Center — who created this lead
-- ---------------------------------------------------------------------------
-- None of the four lead-like tables tracked who added the row, only when
-- (created_at). Every client-side insert path across Leads, Cold Leads,
-- ISO Leads, and Lending Leads now stamps created_by with the logged-in
-- internal user's id — see app/index.html for the full list of insert call
-- sites that were updated alongside this migration.
--
-- The one path that legitimately has no internal user behind it is the
-- public referral landing page (public_submit_referral_lead(), a
-- SECURITY DEFINER function running as anon — database/12_public_referral.sql).
-- Those leads keep created_by null; the app shows a distinct label for that
-- case rather than a blank "unknown creator", since it's expected, not
-- missing data.
--
-- No RLS changes needed — created_by is a descriptive column, not a new
-- access boundary. Who can insert/see these rows at all is already governed
-- by each table's existing policies.
-- =============================================================================

alter table leads add column if not exists created_by uuid references users(id) on delete set null;
alter table cold_leads add column if not exists created_by uuid references users(id) on delete set null;
alter table iso_leads add column if not exists created_by uuid references users(id) on delete set null;
alter table lending_leads add column if not exists created_by uuid references users(id) on delete set null;

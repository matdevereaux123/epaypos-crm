-- =============================================================================
-- EPAY POS / Envision ATM Control Center — leads schema alignment fixes
-- ---------------------------------------------------------------------------
-- Found while converting the Leads collection to real Supabase calls
-- (Phase 4): comparing app/index.html's emptyAccountFields() field-by-field
-- against 01_schema.sql's `leads` table turned up a few real mismatches.
-- Column names were renamed to match the app (rather than renaming the
-- field throughout the app's JS) since that's the much smaller, safer diff.
-- =============================================================================

alter table leads rename column pending_cadence to pending_cadence_days;
alter table leads rename column application_link_type to application_link_choice;

alter table leads
  add column if not exists application_link_custom text,
  add column if not exists followup1_done boolean not null default false,
  add column if not exists followup2_done boolean not null default false,
  add column if not exists welcome_email_sent boolean not null default false,
  add column if not exists welcome_email_sent_at date;

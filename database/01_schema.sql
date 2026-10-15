-- =============================================================================
-- EPAY POS / Envision ATM Control Center — Supabase schema
-- ---------------------------------------------------------------------------
-- How to use this file:
--   1. Open your Supabase project → SQL Editor → New query.
--   2. Paste this whole file in and run it. It creates every table needed
--      to replace the localStorage version of the CRM.
--   3. Read the comments as you go — a few decisions are called out
--      explicitly where there wasn't one obviously "correct" answer.
--
-- Design approach:
--   - Every table has a real primary key and real foreign keys where one
--     record clearly belongs to another (a note belongs to a lead, a user
--     reports to another user, etc.) — this is what makes Row-Level
--     Security possible later.
--   - Fields that are naturally a flexible list or nested object in the
--     app (banking info, uploaded documents, selected equipment, selected
--     integrations) are stored as JSONB columns rather than broken into
--     their own tables. This matches how the app already treats them and
--     keeps the schema from exploding into 30+ tables for something that
--     doesn't need to be queried piece-by-piece. If you later want to run
--     reports that slice into these (e.g. "total QuickBooks subscriptions
--     across all accounts"), that's the point where a column like
--     integrations_selected would graduate into its own table — not
--     needed on day one.
--   - Sensitive fields (SSN, bank account/routing numbers) are flagged
--     with a comment. Supabase can encrypt these at the column level using
--     the pgcrypto extension — enable it and wrap those columns before any
--     real merchant data goes in. This file creates the columns as plain
--     text so you can see the full shape first; encrypting them is a
--     follow-up step, not something to skip.
-- =============================================================================

-- Needed for gen_random_uuid() used below
create extension if not exists pgcrypto;

-- =============================================================================
-- ROLES — built-in (admin, in_house_sales, iso, agent, referral_partner,
-- epay_reseller) plus any custom ones created from Settings → Roles &
-- Permissions. Key is the slug used everywhere else (users.role).
-- =============================================================================
create table roles (
  key            text primary key,
  label          text not null,
  portal_scope   text not null check (portal_scope in ('internal', 'own')),
  description    text,
  perms          jsonb not null default '{}'::jsonb,
  -- perms shape: { manageUsers, manageSettings, viewAllPartners, editPartners,
  --                viewBanking, editBanking (true|false|"own"),
  --                manageAutomation, fullDashboard }
  is_custom      boolean not null default false,
  created_at     timestamptz not null default now()
);

-- =============================================================================
-- PARTNERS — Referral Partners, Agents, and EPAY Resellers all live here,
-- distinguished by type/reseller_type. brand controls which brand tab(s)
-- a partner shows under.
-- =============================================================================
create table partners (
  id                  uuid primary key default gen_random_uuid(),
  name                text not null,
  contact             text,
  email               text,
  phone               text,
  type                text not null check (type in ('referral_partner', 'agent')),
  reseller_type       text check (reseller_type in ('authorized_reseller', 'basic_payments')),
  city                text,
  state               text,
  address             text,
  zip                 text,
  website             text,
  lat                 double precision,
  lng                 double precision,
  link_slug           text unique not null,
  brand               text not null check (brand in ('epay', 'atm', 'both')),
  leads_submitted     integer not null default 0,
  deals_closed        integer not null default 0,
  last_deal_date      date,
  status              text not null default 'active',
  link_clicks         integer not null default 0,
  next_follow_up      date,
  auto_followup_days  integer,
  -- SENSITIVE — encrypt before real data goes in.
  banking             jsonb default '{"bank_name":"","account_holder":"","account_type":"checking","routing_number":"","account_number":""}'::jsonb,
  general_notes       text,
  parent_partner_id   uuid references partners(id) on delete set null,
  created_at          timestamptz not null default now()
);
create index on partners (brand);
create index on partners (parent_partner_id);

-- =============================================================================
-- USERS — internal team members AND external portal logins (referral
-- partners/agents/resellers who got an invite) both live here. auth_id
-- links to Supabase Auth once real login is wired up.
-- =============================================================================
create table users (
  id                uuid primary key default gen_random_uuid(),
  auth_id           uuid references auth.users(id) on delete set null,
  name              text not null,
  email             text unique not null,
  brands            text[] not null default '{}',  -- e.g. {epay} or {epay,atm}
  role              text not null references roles(key),
  manager_id        uuid references users(id) on delete set null,
  linked_partner_id uuid references partners(id) on delete set null,
  invite_sent       boolean not null default false,
  invite_sent_at    date,
  created_at        timestamptz not null default now()
);
create index on users (manager_id);
create index on users (role);

-- =============================================================================
-- LEADS — the big one. Covers both Leads and Accounts (converted_to_account
-- distinguishes them) for BOTH brands (the brand column decides which
-- pipeline/stage set applies — EPAY's 11-stage pipeline or ATM's 7-stage one).
-- =============================================================================
create table leads (
  id                        uuid primary key default gen_random_uuid(),
  brand                     text not null check (brand in ('epay', 'atm')),
  business_name             text not null,
  contact_name              text,
  phone                     text,
  email                     text,
  est_volume                text,
  stage                     text not null,
  created_at                date not null default current_date,
  stage_entered_at          date not null default current_date,
  converted_to_account      boolean not null default false,
  converted_at              date,

  -- Business/personal details (EPAY boarding + shared where relevant)
  owner_first_name          text,
  owner_last_name           text,
  dob                       date,          -- SENSITIVE
  ssn                       text,          -- SENSITIVE — encrypt
  drivers_license           text,          -- SENSITIVE
  drivers_license_state     text,
  legal_business_name       text,
  dba_name                  text,
  business_address          text,
  business_email            text,
  business_phone            text,
  business_start_date       date,
  business_type_services    text,
  business_tax_id           text,          -- SENSITIVE
  highest_sale_amount       text,
  average_sale_amount       text,
  monthly_sales_average     text,
  personal_address          text,
  banking                   jsonb default '{"bank_name":"","account_type":"checking","routing_number":"","account_number":""}'::jsonb, -- SENSITIVE — encrypt
  documents                 jsonb not null default '[]'::jsonb,

  -- EPAY pipeline fields
  lead_source               text,
  system_choice             text,          -- 'epay' | 'clover'
  pos_plan                  text,
  processing_pricing        text,
  clover_device             text,
  equipment_selected        jsonb not null default '[]'::jsonb,  -- [{name, qty}]
  equipment_free            boolean not null default false,
  integrations_selected     jsonb not null default '[]'::jsonb,  -- [{key, name, price, tierKey?, added_at}]
  integrations_note         text,
  epay_apps_selected        jsonb not null default '[]'::jsonb,  -- [{key, name, price}]
  followup1_date            date,
  followup1_idea            text,
  followup2_date            date,
  followup2_idea            text,
  pending_cadence           text,
  pending_next_reminder     date,
  equipment_pricing_confirmed      boolean not null default false,
  equipment_pricing_confirmed_at   date,
  application_link_type     text,
  application_email_sent    boolean not null default false,
  application_email_sent_at date,
  app_id                    text,
  in_person_install         boolean not null default false,
  tracking_number           text,
  tracking_email_sent       boolean not null default false,
  tracking_email_sent_at    date,
  shipments                 jsonb not null default '[]'::jsonb,  -- [{id, tracking_number, carrier, added_at, added_time, emailed, emailed_at}]

  -- Envision ATM pipeline fields
  tid                       text,
  installation_date         date,
  commission_type           text default 'percentage',  -- 'percentage' | 'dollar'
  commission_value          text,

  -- Shared across both brands
  linked_partner_id         uuid references partners(id) on delete set null,
  assigned_to               uuid references users(id) on delete set null,
  general_follow_up_date    date,
  general_follow_up_note    text
);
create index on leads (brand, stage);
create index on leads (converted_to_account);
create index on leads (assigned_to);
create index on leads (linked_partner_id);

-- =============================================================================
-- COLD_LEADS — pre-pipeline prospects. promoted=true means it's been
-- converted into a `leads` row and should no longer show in the Cold
-- Leads tab (mirrors the app's own promoted flag).
-- =============================================================================
create table cold_leads (
  id                uuid primary key default gen_random_uuid(),
  brand             text not null check (brand in ('epay', 'atm')),
  business_name     text not null,
  contact_name      text,
  phone             text,
  email             text,
  source            text,
  source_category   text,
  temperature       text not null default 'cold',  -- cold | warm | hot
  notes             text,
  created_at        date not null default current_date,
  promoted          boolean not null default false,
  owner_name        text,
  owner_title       text,
  cell_phone        text,
  address           text,
  website           text,
  linkedin_url      text,
  facebook_url      text,
  instagram_url     text,
  follow_up_date    date,
  follow_up_method  text default 'none',
  follow_up_note    text
);
create index on cold_leads (brand, promoted);

-- =============================================================================
-- LENDING_LEADS — fully separate pipeline (business lending/MCA leads),
-- own basic stage set.
-- =============================================================================
create table lending_leads (
  id                uuid primary key default gen_random_uuid(),
  business_name     text not null,
  contact_name      text,
  phone             text,
  email             text,
  loan_amount       text,
  source            text,
  stage             text not null default 'new_lead',
  created_at        date not null default current_date,
  stage_entered_at  date not null default current_date
);

-- =============================================================================
-- NOTES — a decision point: the app currently lets one note table serve
-- BOTH leads and lending_leads by just storing the id as text (lead ids and
-- lending-lead ids never collide because of their prefixes). In Postgres,
-- a real foreign key can only point at one table. Two clean options:
--   (a) Keep it simple — drop the FK constraint, store lead_id as plain
--       uuid/text, and enforce "does this id exist in leads OR
--       lending_leads" in application code instead of the database.
--   (b) Split into lead_notes and lending_lead_notes, each with a real FK.
-- This schema takes option (b) since it's the cleaner long-term choice
-- and the extra table costs almost nothing.
-- =============================================================================
create table partner_notes (
  id           uuid primary key default gen_random_uuid(),
  partner_id   uuid not null references partners(id) on delete cascade,
  text         text not null,
  created_by   text not null,
  created_at   date not null default current_date
);

create table lead_notes (
  id           uuid primary key default gen_random_uuid(),
  lead_id      uuid not null references leads(id) on delete cascade,
  text         text not null,
  created_by   text not null,
  created_at   date not null default current_date
);
create table lead_call_notes (
  id           uuid primary key default gen_random_uuid(),
  lead_id      uuid not null references leads(id) on delete cascade,
  text         text not null,
  created_by   text not null,
  created_at   date not null default current_date
);

create table lending_lead_notes (
  id               uuid primary key default gen_random_uuid(),
  lending_lead_id  uuid not null references lending_leads(id) on delete cascade,
  text             text not null,
  created_by       text not null,
  created_at       date not null default current_date
);
create table lending_lead_call_notes (
  id               uuid primary key default gen_random_uuid(),
  lending_lead_id  uuid not null references lending_leads(id) on delete cascade,
  text             text not null,
  created_by       text not null,
  created_at       date not null default current_date
);

-- =============================================================================
-- APPLICATIONS — Wix "Free Processing" / "Sign Up" form submissions,
-- reviewed and linked to an account.
-- =============================================================================
create table applications (
  id                  uuid primary key default gen_random_uuid(),
  business_name       text,
  contact_name        text,
  email               text,
  phone               text,
  submitted_at        date not null default current_date,
  source              text,               -- 'wix' | 'manual'
  linked_account_id   uuid references leads(id) on delete set null,
  raw_payload         jsonb               -- whatever Wix actually sends — keep it all
);

-- =============================================================================
-- CALENDAR
-- =============================================================================
create table connected_calendars (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  email        text,
  connected    boolean not null default true
);

create table calendar_events (
  id                    uuid primary key default gen_random_uuid(),
  title                 text not null,
  date                  date not null,
  time                  text,
  duration              text,
  type                  text,   -- phone | zoom_meeting | zoom_demo | in_person
  calendar_id           uuid references connected_calendars(id) on delete set null,
  linked_cold_lead_id   uuid references cold_leads(id) on delete set null,
  linked_lead_id        uuid references leads(id) on delete set null,
  zoom_link             text,
  notes                 text
);
create index on calendar_events (date);

-- =============================================================================
-- INSTANTLY CONTACTS — cold email outreach synced in from Instantly.
-- =============================================================================
create table instantly_contacts (
  id                    uuid primary key default gen_random_uuid(),
  business_name         text,
  contact_name          text,
  email                 text,
  campaign_name         text,
  status                text,
  last_event_at         date,
  reply_snippet         text,
  linked_cold_lead_id   uuid references cold_leads(id) on delete set null
);

-- =============================================================================
-- INTEGRATIONS — connection status + config for each third-party service
-- (Instantly, Wix, AI Lead Scraper backend, Google Calendar, Outbound Email).
-- values holds provider-specific fields (API keys etc.) — these should be
-- stored via Supabase Vault or an encrypted column, not plain text, once
-- this goes live.
-- =============================================================================
create table integrations (
  key         text primary key,   -- 'instantly' | 'wix' | 'ai_scraper' | 'google_calendar' | 'outbound_email'
  connected   boolean not null default false,
  values      jsonb not null default '{}'::jsonb   -- SENSITIVE — API keys live here
);

-- =============================================================================
-- Seed the six built-in roles so the app has something to reference
-- immediately. Custom roles get inserted the same way from the app itself.
-- =============================================================================
insert into roles (key, label, portal_scope, description, perms) values
  ('admin', 'Admin', 'internal',
   'Full control — every tab, every record, both brands, banking info, user management, and settings.',
   '{"manageUsers":true,"manageSettings":true,"viewAllPartners":true,"editPartners":true,"viewBanking":true,"editBanking":true,"manageAutomation":true,"fullDashboard":true}'),
  ('in_house_sales', 'In House Sales', 'internal',
   'Internal reps — full working access to partners, pipeline, and follow-ups. Can view but not edit payout banking info.',
   '{"manageUsers":false,"manageSettings":false,"viewAllPartners":true,"editPartners":true,"viewBanking":true,"editBanking":false,"manageAutomation":true,"fullDashboard":true}'),
  ('iso', 'ISO', 'own',
   'Independent Sales Organization portal login — sees only their own submitted deals, referral link, and stats.',
   '{"manageUsers":false,"manageSettings":false,"viewAllPartners":false,"editPartners":false,"viewBanking":false,"editBanking":"own","manageAutomation":false,"fullDashboard":false}'),
  ('agent', 'Agent', 'own',
   '1099 sales agent portal login — their own leads, deals, and referral link only.',
   '{"manageUsers":false,"manageSettings":false,"viewAllPartners":false,"editPartners":false,"viewBanking":false,"editBanking":"own","manageAutomation":false,"fullDashboard":false}'),
  ('referral_partner', 'Referral Partner', 'own',
   'The most limited external login — their own referral link, lead count, and payout banking only.',
   '{"manageUsers":false,"manageSettings":false,"viewAllPartners":false,"editPartners":false,"viewBanking":false,"editBanking":"own","manageAutomation":false,"fullDashboard":false}'),
  ('epay_reseller', 'EPAY Reseller', 'own',
   'Authorized EPAY POS reseller-tier agent — same restricted self-view as Agent.',
   '{"manageUsers":false,"manageSettings":false,"viewAllPartners":false,"editPartners":false,"viewBanking":false,"editBanking":"own","manageAutomation":false,"fullDashboard":false}');

-- =============================================================================
-- NEXT STEPS after running this file:
--   1. Confirm every table above appears in Supabase's Table Editor.
--   2. Enable Row-Level Security on every table (Supabase: off by default) —
--      nothing is actually locked down until you do this, even though the
--      tables now exist.
--   3. Write the RLS policies matching roles.perms — this is Phase 3 in
--      the walkthrough, and is its own significant piece of work.
--   4. Only after RLS is in place should real merchant data go anywhere
--      near this database.
-- =============================================================================

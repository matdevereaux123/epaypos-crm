-- =============================================================================
-- EPAY POS / Envision ATM Control Center — Recruiting (leads for our own sales side)
-- ---------------------------------------------------------------------------
-- Run after 71_uploaded_agreement_documents.sql.
--
-- A lead here is a PERSON we might bring on — not a merchant. Picking a
-- category (Internal Sales, Agent, ISO, Referral Partner) and pressing
-- Convert creates the real record in the right place (a CRM login for
-- Internal Sales; a partner + portal login for the other three) and stamps
-- the recruit as converted so it cannot be converted twice.
--
-- Admin only (manageUsers): converting to Internal Sales creates a CRM
-- login, which users_write already restricts to manageUsers.
-- =============================================================================

create table if not exists recruit_leads (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  company         text,
  email           text,
  phone           text,
  city            text,
  state           text,
  notes           text,
  category        text check (category in ('internal_sales','agent','iso','referral_partner')),
  converted       boolean not null default false,
  converted_kind  text,
  converted_ref   uuid,
  converted_at    timestamptz,
  created_by      uuid references users(id) on delete set null,
  created_at      timestamptz not null default now()
);
create index if not exists recruit_leads_converted_idx on recruit_leads (converted);

alter table recruit_leads enable row level security;

drop policy if exists "recruit_leads_all" on recruit_leads;
create policy "recruit_leads_all" on recruit_leads
  for all to authenticated
  using (current_app_has_perm('manageUsers'))
  with check (current_app_has_perm('manageUsers'));

-- =============================================================================
-- AFTER RUNNING THIS
--   Sidebar -> Partners -> Recruiting -> + Add Recruit. Pick a category and
--   Convert; confirm they appear under Internal Sales / Agents-ISOs /
--   Referral Partners accordingly.
-- =============================================================================

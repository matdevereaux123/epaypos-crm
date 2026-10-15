-- =============================================================================
-- Recruiting: assign a recruit to someone
-- ---------------------------------------------------------------------------
-- Run after 72_recruit_leads.sql. Safe to re-run.
--
-- assigned_to is a label for whoever is working the recruit — an internal
-- sales person, agent, ISO or referral partner (any CRM login). It does NOT
-- widen who can see recruits: recruit_leads stays manageUsers-only (72).
-- =============================================================================
alter table recruit_leads
  add column if not exists assigned_to uuid references users(id) on delete set null;
create index if not exists recruit_leads_assigned_idx on recruit_leads (assigned_to);

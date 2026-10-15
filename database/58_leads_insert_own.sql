-- =============================================================================
-- EPAY POS / Envision ATM Control Center — let portal logins add their own leads
-- ---------------------------------------------------------------------------
-- A portal-scoped login (Agent, Referral Partner, ISO, EPAY Reseller) using
-- the CRM's own "Add Lead" button was getting "new row violates row-level
-- security policy for table leads" — the existing leads INSERT policy only
-- ever allowed internal (fullDashboard) staff to insert.
--
-- Written as an ADDITIONAL policy rather than replacing the existing one on
-- purpose: this file couldn't be read at the time this was written (a stuck
-- iCloud file-provider issue on this machine, not a stuck process a kill
-- fixes), so the exact current policy text is unverified. Postgres combines
-- multiple permissive policies for the same command with OR, so adding a
-- second one here only ever widens access — it cannot accidentally remove
-- or narrow whatever the existing staff-insert policy already allows.
--
-- Scope: a portal user may insert a lead if the new row is theirs by any of
-- the usual ownership markers already on `leads` — assigned to them, created
-- by them, or tied to their own linked partner record. They still cannot
-- insert a row scoped to someone else.
-- =============================================================================

drop policy if exists "leads_insert_own" on leads;

create policy "leads_insert_own" on leads
  for insert to authenticated
  with check (
    coalesce(current_app_has_perm('fullDashboard'), false)
    or assigned_to = current_app_user_id()
    or created_by = current_app_user_id()
    or linked_partner_id = current_app_linked_partner_id()
  );

-- =============================================================================
-- AFTER RUNNING THIS
--   Log in as Mitch (or any portal-scoped role) and try "Add Lead" again.
--   Once file access is back, it's worth reading the real leads_insert
--   policy to confirm this wasn't papering over something more specific —
--   flagging that as a follow-up, not blocking this fix on it.
-- =============================================================================

-- =============================================================================
-- EPAY POS / Envision ATM Control Center — Row-Level Security
-- ---------------------------------------------------------------------------
-- Phase 3 of the migration checklist. Until this runs, every table is wide
-- open to anyone holding the anon key — RLS is off by default in Postgres/
-- Supabase even though the tables already exist.
--
-- How this works, in plain terms:
--   - Six helper functions below read the CALLING USER's role and perms
--     from `roles.perms` at query time (via their auth_id -> users.role ->
--     roles.perms), rather than having role names hardcoded into policies.
--     That's what makes this work automatically for custom roles created
--     from Settings — a new role just needs the right perms JSON, no new
--     SQL policy required.
--   - Two access patterns repeat throughout:
--       (a) "internal full access" — gated on the fullDashboard perm
--           (true for admin and in_house_sales, false for every portal role)
--       (b) "own record only" — portal logins (iso/agent/referral_partner/
--           epay_reseller) only ever see data tied to THEIR OWN partner
--           record or their own assigned leads, matched via
--           users.linked_partner_id / leads.assigned_to.
--   - Child tables (notes, etc.) inherit access from whatever parent row
--     they belong to, via an EXISTS subquery — if you can see the lead,
--     you can see notes on it.
--
-- Known gap, flagged for later: this does not add a policy allowing
-- unauthenticated (anon) lead submission via the public referral links
-- (epaypos.net/r/[slug]) mentioned in the README — those pages don't exist
-- yet (Phase 5/6). When they're built, that should go through a dedicated
-- SECURITY DEFINER function (same pattern as set_lead_ssn), not a raw
-- insert policy open to anon — same reasoning as the encryption RPCs.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Helper functions
-- ---------------------------------------------------------------------------
create or replace function current_app_user_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select id from users where auth_id = auth.uid();
$$;

create or replace function current_app_linked_partner_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select linked_partner_id from users where auth_id = auth.uid();
$$;

create or replace function current_app_perms()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select r.perms
  from users u
  join roles r on r.key = u.role
  where u.auth_id = auth.uid();
$$;

create or replace function current_app_has_perm(p_key text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((current_app_perms()->>p_key)::boolean, false);
$$;

grant execute on function current_app_user_id() to authenticated;
grant execute on function current_app_linked_partner_id() to authenticated;
grant execute on function current_app_perms() to authenticated;
grant execute on function current_app_has_perm(text) to authenticated;

-- ---------------------------------------------------------------------------
-- roles — everyone logged in can read (needed to know their own perms);
-- only manageSettings can create/edit/delete (custom roles come from here).
-- ---------------------------------------------------------------------------
alter table roles enable row level security;

create policy "roles_select" on roles
  for select to authenticated
  using (true);

create policy "roles_write" on roles
  for all to authenticated
  using (current_app_has_perm('manageSettings'))
  with check (current_app_has_perm('manageSettings'));

-- ---------------------------------------------------------------------------
-- partners — internal viewAllPartners sees everyone; a portal login sees
-- only the partner record it's linked to. Writes require editPartners
-- (portal logins can't edit their own row directly here — that goes
-- through dedicated RPCs later, same pattern as banking/SSN).
-- ---------------------------------------------------------------------------
alter table partners enable row level security;

create policy "partners_select" on partners
  for select to authenticated
  using (
    current_app_has_perm('viewAllPartners')
    or id = current_app_linked_partner_id()
  );

create policy "partners_write" on partners
  for all to authenticated
  using (current_app_has_perm('editPartners'))
  with check (current_app_has_perm('editPartners'));

-- ---------------------------------------------------------------------------
-- users — manageUsers sees/edits everyone; everyone can see their own row
-- (needed so the app can read its own permissions after login).
-- ---------------------------------------------------------------------------
alter table users enable row level security;

create policy "users_select" on users
  for select to authenticated
  using (
    current_app_has_perm('manageUsers')
    or auth_id = auth.uid()
  );

create policy "users_write" on users
  for all to authenticated
  using (current_app_has_perm('manageUsers'))
  with check (current_app_has_perm('manageUsers'));

-- ---------------------------------------------------------------------------
-- leads — internal fullDashboard sees/edits everything; a portal login
-- sees/edits only leads linked to their partner record or assigned to them.
-- ---------------------------------------------------------------------------
alter table leads enable row level security;

create policy "leads_select" on leads
  for select to authenticated
  using (
    current_app_has_perm('fullDashboard')
    or linked_partner_id = current_app_linked_partner_id()
    or assigned_to = current_app_user_id()
  );

create policy "leads_write" on leads
  for all to authenticated
  using (
    current_app_has_perm('fullDashboard')
    or linked_partner_id = current_app_linked_partner_id()
    or assigned_to = current_app_user_id()
  )
  with check (
    current_app_has_perm('fullDashboard')
    or linked_partner_id = current_app_linked_partner_id()
  );

-- ---------------------------------------------------------------------------
-- cold_leads / lending_leads — internal-only pipelines, no portal access.
-- ---------------------------------------------------------------------------
alter table cold_leads enable row level security;

create policy "cold_leads_all" on cold_leads
  for all to authenticated
  using (current_app_has_perm('fullDashboard'))
  with check (current_app_has_perm('fullDashboard'));

alter table lending_leads enable row level security;

create policy "lending_leads_all" on lending_leads
  for all to authenticated
  using (current_app_has_perm('fullDashboard'))
  with check (current_app_has_perm('fullDashboard'));

-- ---------------------------------------------------------------------------
-- partner_notes — read/add follows partner access; edit/delete internal only.
-- ---------------------------------------------------------------------------
alter table partner_notes enable row level security;

create policy "partner_notes_select" on partner_notes
  for select to authenticated
  using (
    exists (
      select 1 from partners p
      where p.id = partner_notes.partner_id
        and (current_app_has_perm('viewAllPartners') or p.id = current_app_linked_partner_id())
    )
  );

create policy "partner_notes_insert" on partner_notes
  for insert to authenticated
  with check (
    exists (
      select 1 from partners p
      where p.id = partner_notes.partner_id
        and (current_app_has_perm('editPartners') or p.id = current_app_linked_partner_id())
    )
  );

create policy "partner_notes_update" on partner_notes
  for update to authenticated
  using (current_app_has_perm('editPartners'))
  with check (current_app_has_perm('editPartners'));

create policy "partner_notes_delete" on partner_notes
  for delete to authenticated
  using (current_app_has_perm('editPartners'));

-- ---------------------------------------------------------------------------
-- lead_notes / lead_call_notes — read/add follows lead access; edit/delete
-- internal only.
-- ---------------------------------------------------------------------------
alter table lead_notes enable row level security;

create policy "lead_notes_select" on lead_notes
  for select to authenticated
  using (
    exists (
      select 1 from leads l
      where l.id = lead_notes.lead_id
        and (
          current_app_has_perm('fullDashboard')
          or l.linked_partner_id = current_app_linked_partner_id()
          or l.assigned_to = current_app_user_id()
        )
    )
  );

create policy "lead_notes_insert" on lead_notes
  for insert to authenticated
  with check (
    exists (
      select 1 from leads l
      where l.id = lead_notes.lead_id
        and (
          current_app_has_perm('fullDashboard')
          or l.linked_partner_id = current_app_linked_partner_id()
          or l.assigned_to = current_app_user_id()
        )
    )
  );

create policy "lead_notes_update" on lead_notes
  for update to authenticated
  using (current_app_has_perm('fullDashboard'))
  with check (current_app_has_perm('fullDashboard'));

create policy "lead_notes_delete" on lead_notes
  for delete to authenticated
  using (current_app_has_perm('fullDashboard'));

alter table lead_call_notes enable row level security;

create policy "lead_call_notes_select" on lead_call_notes
  for select to authenticated
  using (
    exists (
      select 1 from leads l
      where l.id = lead_call_notes.lead_id
        and (
          current_app_has_perm('fullDashboard')
          or l.linked_partner_id = current_app_linked_partner_id()
          or l.assigned_to = current_app_user_id()
        )
    )
  );

create policy "lead_call_notes_insert" on lead_call_notes
  for insert to authenticated
  with check (
    exists (
      select 1 from leads l
      where l.id = lead_call_notes.lead_id
        and (
          current_app_has_perm('fullDashboard')
          or l.linked_partner_id = current_app_linked_partner_id()
          or l.assigned_to = current_app_user_id()
        )
    )
  );

create policy "lead_call_notes_update" on lead_call_notes
  for update to authenticated
  using (current_app_has_perm('fullDashboard'))
  with check (current_app_has_perm('fullDashboard'));

create policy "lead_call_notes_delete" on lead_call_notes
  for delete to authenticated
  using (current_app_has_perm('fullDashboard'));

-- ---------------------------------------------------------------------------
-- lending_lead_notes / lending_lead_call_notes — internal only, since
-- lending_leads itself has no portal access.
-- ---------------------------------------------------------------------------
alter table lending_lead_notes enable row level security;

create policy "lending_lead_notes_all" on lending_lead_notes
  for all to authenticated
  using (current_app_has_perm('fullDashboard'))
  with check (current_app_has_perm('fullDashboard'));

alter table lending_lead_call_notes enable row level security;

create policy "lending_lead_call_notes_all" on lending_lead_call_notes
  for all to authenticated
  using (current_app_has_perm('fullDashboard'))
  with check (current_app_has_perm('fullDashboard'));

-- ---------------------------------------------------------------------------
-- applications / connected_calendars / calendar_events / instantly_contacts
-- — internal-only, no portal-scoped access to any of these.
-- ---------------------------------------------------------------------------
alter table applications enable row level security;

create policy "applications_all" on applications
  for all to authenticated
  using (current_app_has_perm('fullDashboard'))
  with check (current_app_has_perm('fullDashboard'));

alter table connected_calendars enable row level security;

create policy "connected_calendars_all" on connected_calendars
  for all to authenticated
  using (current_app_has_perm('fullDashboard'))
  with check (current_app_has_perm('fullDashboard'));

alter table calendar_events enable row level security;

create policy "calendar_events_all" on calendar_events
  for all to authenticated
  using (current_app_has_perm('fullDashboard'))
  with check (current_app_has_perm('fullDashboard'));

alter table instantly_contacts enable row level security;

create policy "instantly_contacts_all" on instantly_contacts
  for all to authenticated
  using (current_app_has_perm('fullDashboard'))
  with check (current_app_has_perm('fullDashboard'));

-- ---------------------------------------------------------------------------
-- integrations — the most sensitive table (holds API keys in `values`).
-- Locked to manageSettings only, full stop.
-- ---------------------------------------------------------------------------
alter table integrations enable row level security;

create policy "integrations_all" on integrations
  for all to authenticated
  using (current_app_has_perm('manageSettings'))
  with check (current_app_has_perm('manageSettings'));

-- =============================================================================
-- NEXT STEPS after running this file:
--   1. Confirm every table in Table Editor now shows a "RLS enabled" badge.
--   2. Real testing of these policies happens once Phase 4 connects the app
--      and real users log in with different roles — the SQL Editor runs as
--      the postgres superuser, which bypasses RLS entirely, so you won't
--      see it "do" anything from in here. A clean run with no errors means
--      the policies were created successfully; it doesn't yet prove they
--      behave correctly for each role — that's Phase 4/7 territory.
-- =============================================================================

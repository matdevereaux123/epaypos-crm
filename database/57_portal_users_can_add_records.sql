-- =============================================================================
-- EPAY POS / Envision ATM Control Center — portal users adding records
-- ---------------------------------------------------------------------------
-- Run after 56_portal_users_can_add_leads.sql. Safe to re-run.
--
-- 56 fixed Leads. Rendering the app as each portal role (agent, reseller,
-- ISO, referral partner) found the same failure on four more tabs: an Add
-- button the database was always going to refuse.
--
--   ISO Leads      identical bug to leads — the check required
--                  linked_partner_id = own partner, and a new ISO lead has none
--   Cold Leads     create was staff-only; agents could be assigned one and
--                  edit it, but not add one
--   Contacts       staff-only for everything, including reading
--   Lending Leads  staff-only for everything
--
-- The rule for all of them: a portal user may create records, and sees and
-- manages only the records that are theirs. Staff (fullDashboard) are
-- unaffected and keep seeing everything.
--
-- WHY OWNERSHIP IS SET BY TRIGGER, NOT TRUSTED FROM THE BROWSER
--
-- The policies below key on created_by / assigned_to. If the browser chose
-- those values, a portal user could create a record "owned" by someone else,
-- or quietly hand one to a colleague. So for a portal user the trigger
-- stamps created_by with the real caller regardless of what was sent, and
-- refuses to change it afterwards. Staff, anonymous public forms and the
-- service role have no reason to be second-guessed and are left alone.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- Shared: stamp and lock created_by for portal users
-- ---------------------------------------------------------------------------
create or replace function portal_stamp_created_by()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := current_app_user_id();
begin
  if coalesce(current_app_has_perm('fullDashboard'), false) then return NEW; end if;
  if v_me is null then return NEW; end if;   -- public forms, service role

  if TG_OP = 'INSERT' then
    -- Forced, not defaulted: a portal user cannot create a record in
    -- someone else's name.
    NEW.created_by := v_me;
  elsif NEW.created_by is distinct from OLD.created_by then
    raise exception 'You cannot change who created this record';
  end if;

  return NEW;
end;
$$;


-- =============================================================================
-- ISO LEADS — same shape as leads, so the same fix
--
-- leads_portal_ownership() (56) credits a new lead to the author, assigns it
-- to them, and refuses a credit outside their record and downline. iso_leads
-- has the same linked_partner_id and assigned_to columns, so it is reused
-- rather than copied.
-- =============================================================================
drop trigger if exists iso_leads_portal_ownership on iso_leads;
create trigger iso_leads_portal_ownership
  before insert or update on iso_leads
  for each row execute function leads_portal_ownership();

drop policy if exists "iso_leads_write" on iso_leads;
create policy "iso_leads_write" on iso_leads
  for all to authenticated
  using (
    current_app_has_perm('fullDashboard')
    or linked_partner_id = current_app_linked_partner_id()
    or assigned_to = current_app_user_id()
  )
  with check (
    current_app_has_perm('fullDashboard')
    or linked_partner_id = current_app_linked_partner_id()
    or assigned_to = current_app_user_id()
    or current_partner_has_in_downline(linked_partner_id)
  );


-- =============================================================================
-- COLD LEADS
--
-- Visibility stays as it was: assigned to you. A new cold lead from a portal
-- user is assigned to its author, so it appears on their list — and so they
-- can read the row back on insert, without which the insert fails with the
-- same RLS error. Assigning it on to someone in their downline is still
-- governed by enforce_assignment_scope() from 27.
--
-- Deleting: only one you created yourself. A cold lead an admin handed you is
-- yours to work, not yours to throw away.
-- =============================================================================
create or replace function cold_leads_portal_ownership()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(current_app_has_perm('fullDashboard'), false) then return NEW; end if;
  if current_app_user_id() is null then return NEW; end if;
  if TG_OP = 'INSERT' and NEW.assigned_to is null then
    NEW.assigned_to := current_app_user_id();
  end if;
  return NEW;
end;
$$;

drop trigger if exists cold_leads_portal_ownership on cold_leads;
create trigger cold_leads_portal_ownership
  before insert on cold_leads
  for each row execute function cold_leads_portal_ownership();

drop trigger if exists cold_leads_stamp_created_by on cold_leads;
create trigger cold_leads_stamp_created_by
  before insert or update on cold_leads
  for each row execute function portal_stamp_created_by();

drop policy if exists "cold_leads_insert" on cold_leads;
create policy "cold_leads_insert" on cold_leads
  for insert to authenticated
  with check (
    current_app_has_perm('fullDashboard')
    or assigned_to = current_app_user_id()
  );

drop policy if exists "cold_leads_delete" on cold_leads;
create policy "cold_leads_delete" on cold_leads
  for delete to authenticated
  using (
    current_app_has_perm('fullDashboard')
    or (created_by = current_app_user_id() and assigned_to = current_app_user_id())
  );


-- =============================================================================
-- CONTACTS and LENDING LEADS — owned by whoever created them
--
-- Neither has an assignee, so ownership is created_by. A portal user sees,
-- edits and deletes their own; staff see everyone's. An agent's rolodex is
-- theirs, and nobody else's contacts are visible to them — the same "they
-- cannot see our details" line the rest of the portal holds.
-- =============================================================================
drop trigger if exists contacts_stamp_created_by on contacts;
create trigger contacts_stamp_created_by
  before insert or update on contacts
  for each row execute function portal_stamp_created_by();

drop policy if exists "contacts_all" on contacts;
create policy "contacts_all" on contacts
  for all to authenticated
  using (
    current_app_has_perm('fullDashboard')
    or created_by = current_app_user_id()
  )
  with check (
    current_app_has_perm('fullDashboard')
    or created_by = current_app_user_id()
  );

drop trigger if exists lending_leads_stamp_created_by on lending_leads;
create trigger lending_leads_stamp_created_by
  before insert or update on lending_leads
  for each row execute function portal_stamp_created_by();

drop policy if exists "lending_leads_all" on lending_leads;
create policy "lending_leads_all" on lending_leads
  for all to authenticated
  using (
    current_app_has_perm('fullDashboard')
    or created_by = current_app_user_id()
  )
  with check (
    current_app_has_perm('fullDashboard')
    or created_by = current_app_user_id()
  );


-- =============================================================================
-- AFTER RUNNING THIS
--   Signed in as an agent for real (Preview as uses your admin session and
--   will not reproduce any of this), add one of each: a cold lead, a contact,
--   a lending lead, and on Envision ATM an ISO lead. Each should save and
--   appear on that tab.
--
--   Then sign in as a DIFFERENT agent and confirm none of the first agent's
--   records are visible. That second half is the part that matters.
-- =============================================================================

-- =============================================================================
-- EPAY POS / Envision ATM Control Center — agents and resellers adding leads
-- ---------------------------------------------------------------------------
-- Run after 55_notifications.sql. Safe to re-run.
--
-- THE ERROR
--
--   Could not add lead: new row violates row-level security policy for
--   table "leads"
--
-- leads_write (04_rls.sql) let a non-staff user write a row only if
--
--   linked_partner_id = current_app_linked_partner_id()
--
-- and the Add Lead form sends linked_partner_id from its "Referred by"
-- dropdown, which defaults to None. NULL = anything is never true, so every
-- lead an agent added without first picking themselves in that dropdown was
-- refused. A reseller crediting a lead to someone in their downline was
-- refused too: their downline's partner id is not their own.
--
-- THE SECOND BUG, SAME POLICY
--
-- A `for all` policy applies its WITH CHECK to updates as well. So an agent
-- could SEE a lead an admin had assigned to them (leads_select matches on
-- assigned_to) but not EDIT it unless it also happened to be linked to their
-- own partner record — dragging it to a new stage failed with the same
-- error. Assignment granted the read and not the write.
--
-- THE FIX, IN TWO PARTS
--
--   1. A trigger fills in ownership for a portal user's new lead: credited to
--      their own partner record and assigned to them, unless they chose
--      otherwise. Being assigned is also what lets them read the row back
--      the moment it is created — an insert whose result the author cannot
--      see fails with this same RLS error.
--
--   2. The write check now accepts a row assigned to the caller, or credited
--      to them or to someone in their downline.
--
-- Accepting "assigned to me" alone would let an agent credit a lead to ANY
-- partner — someone else's pipeline stats and, eventually, their residuals.
-- So the trigger also refuses to credit a lead outside the caller's own
-- record and downline, and only objects when the credit actually changes, so
-- an agent editing an admin-assigned lead is not blocked by a credit they
-- never touched. Same shape as 27_assignment_scope.sql, for the same reason:
-- a WITH CHECK sees the new row only and cannot tell a change from a value
-- that was already there.
--
-- What is deliberately NOT changed: who can SEE leads. An upline still sees
-- only leads credited to them or assigned to them, not their downline's.
-- 26_downline_visibility.sql opened partner records, notes and documents to
-- uplines and stopped short of leads; widening that is a business decision,
-- not a bug fix.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1. Ownership defaults and the credit guard
-- ---------------------------------------------------------------------------
create or replace function leads_portal_ownership()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me         uuid := current_app_user_id();
  v_my_partner uuid := current_app_linked_partner_id();
begin
  -- Staff assign and credit freely; this is about portal users only.
  if coalesce(current_app_has_perm('fullDashboard'), false) then
    return NEW;
  end if;

  -- No app user behind the write: a public form or referral page running as
  -- anon through a SECURITY DEFINER function, or the service role. Those set
  -- their own attribution and must not be second-guessed here.
  if v_me is null then
    return NEW;
  end if;

  if TG_OP = 'INSERT' then
    if NEW.linked_partner_id is null then
      NEW.linked_partner_id := v_my_partner;   -- null for a user with no partner record, which is fine
    end if;
    if NEW.assigned_to is null then
      NEW.assigned_to := v_me;
    end if;
  end if;

  -- Only when the credit is set or changed. An agent editing a lead an admin
  -- assigned them, credited to someone else, has not touched the credit.
  if (TG_OP = 'INSERT' or NEW.linked_partner_id is distinct from OLD.linked_partner_id)
     and NEW.linked_partner_id is not null
     and NEW.linked_partner_id is distinct from v_my_partner
     and not current_partner_has_in_downline(NEW.linked_partner_id) then
    raise exception 'You can only credit a lead to yourself or to someone in your downline';
  end if;

  return NEW;
end;
$$;

-- BEFORE triggers fire in name order, so leads_assignment_scope (27) runs
-- first and this second. That order is fine: on insert the assignment check
-- sees a null assignee, which it always allows, and this then fills in the
-- author. Had it run the other way it would see the author, which it also
-- allows. An explicit assignee outside the author's downline is still
-- refused by that trigger either way.
drop trigger if exists leads_portal_ownership on leads;
create trigger leads_portal_ownership
  before insert or update on leads
  for each row execute function leads_portal_ownership();


-- ---------------------------------------------------------------------------
-- 2. The write policy
--
-- USING is unchanged: what you may touch at all. WITH CHECK is what the row
-- must look like afterwards, and now matches what the trigger guarantees.
-- ---------------------------------------------------------------------------
drop policy if exists "leads_write" on leads;

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
    or assigned_to = current_app_user_id()
    or current_partner_has_in_downline(linked_partner_id)
  );


-- =============================================================================
-- AFTER RUNNING THIS
--   Log in as an agent (or use "Preview as" and then sign in as them for
--   real — preview mode uses your admin session and will not reproduce this)
--   and add a lead with "Referred by" left on None. It should save, show on
--   their board, and read as credited to them.
--
--   Then drag it to another stage — that is the update path, which was broken
--   for admin-assigned leads.
-- =============================================================================

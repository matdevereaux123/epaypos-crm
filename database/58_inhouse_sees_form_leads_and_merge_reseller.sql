-- =============================================================================
-- EPAY POS / Envision ATM Control Center — in-house lead visibility, and
-- EPAY Reseller folded into Agent
-- ---------------------------------------------------------------------------
-- Run after 57_portal_users_can_add_records.sql. Safe to re-run.
--
-- 1. IN-HOUSE SALES SEE FORM LEADS, NOT OTHER PEOPLE'S
--
-- In-house sales held fullDashboard, and every leads policy treated
-- fullDashboard as "sees every lead" — so an in-house rep saw each agent's
-- own pipeline and every lead any colleague had entered. The rule now:
--
--   an in-house rep sees a lead if it
--     - came in with no user behind it (created_by is null): the public
--       lead form, the referral page, the application flow, imports
--     - was created by them
--     - is assigned to them
--
--   and does NOT see a lead another user created, unless it is assigned to
--   them. That is how an admin hands an in-house rep something specific.
--
-- "Sees everything" becomes its own permission, viewAllLeads, instead of
-- riding on fullDashboard. fullDashboard still means what it always meant —
-- an internal user who gets the internal tabs — so in-house sales keeps
-- Calendar, Cold Leads, Contacts and the rest untouched.
--
-- Every role that already had fullDashboard, apart from in-house sales, is
-- given viewAllLeads here. Without that a custom internal role would quietly
-- lose most of its leads the moment this ran.
--
-- created_by is now stamped by the database for every signed-in user. The
-- rule above keys on it, so it cannot be something the browser chooses: a
-- rep sending created_by = null would otherwise make their own lead look
-- like a form submission to every other rep.
--
-- 2. EPAY RESELLER BECOMES AGENT
--
-- Everyone on the epay_reseller role moves to agent, and the role is
-- removed. users.role references roles(key), so the users move first.
-- Both roles carried identical permissions, so nobody gains or loses access.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1a. The new permission
-- ---------------------------------------------------------------------------
update roles
   set perms = perms || '{"viewAllLeads": true}'::jsonb
 where coalesce((perms->>'fullDashboard')::boolean, false)
   and key <> 'in_house_sales';

update roles
   set perms = perms || '{"viewAllLeads": false}'::jsonb
 where key = 'in_house_sales';


-- ---------------------------------------------------------------------------
-- 1b. created_by is the caller's, always
-- ---------------------------------------------------------------------------
create or replace function leads_stamp_created_by()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := current_app_user_id();
begin
  -- No app user: a public form through a SECURITY DEFINER function, the
  -- service role, or the SQL editor. Leaving created_by null is exactly
  -- what marks those as having no user behind them.
  if v_me is null then return NEW; end if;

  if TG_OP = 'INSERT' then
    NEW.created_by := v_me;
  elsif NEW.created_by is distinct from OLD.created_by
        and not coalesce(current_app_has_perm('viewAllLeads'), false) then
    raise exception 'You cannot change who created this lead';
  end if;

  return NEW;
end;
$$;

drop trigger if exists leads_stamp_created_by on leads;
create trigger leads_stamp_created_by
  before insert or update on leads
  for each row execute function leads_stamp_created_by();


-- ---------------------------------------------------------------------------
-- 1c. Who sees and writes which leads
-- ---------------------------------------------------------------------------
drop policy if exists "leads_select" on leads;
create policy "leads_select" on leads
  for select to authenticated
  using (
    current_app_has_perm('viewAllLeads')
    or linked_partner_id = current_app_linked_partner_id()
    or assigned_to       = current_app_user_id()
    or created_by        = current_app_user_id()
    or (current_app_has_perm('fullDashboard') and created_by is null)
  );

-- Same visibility governs writing: a rep cannot update or delete a lead by
-- id that they are not allowed to see. The check adds only what 56 added —
-- crediting a lead to your own downline.
drop policy if exists "leads_write" on leads;
create policy "leads_write" on leads
  for all to authenticated
  using (
    current_app_has_perm('viewAllLeads')
    or linked_partner_id = current_app_linked_partner_id()
    or assigned_to       = current_app_user_id()
    or created_by        = current_app_user_id()
    or (current_app_has_perm('fullDashboard') and created_by is null)
  )
  with check (
    current_app_has_perm('viewAllLeads')
    or linked_partner_id = current_app_linked_partner_id()
    or assigned_to       = current_app_user_id()
    or created_by        = current_app_user_id()
    or (current_app_has_perm('fullDashboard') and created_by is null)
    or current_partner_has_in_downline(linked_partner_id)
  );


-- ---------------------------------------------------------------------------
-- 2. EPAY Reseller -> Agent
-- ---------------------------------------------------------------------------
update users set role = 'agent' where role = 'epay_reseller';
delete from roles where key = 'epay_reseller';


-- =============================================================================
-- AFTER RUNNING THIS
--   Check the permission landed where intended:
--     select key, perms->>'fullDashboard' as internal,
--                 perms->>'viewAllLeads'  as all_leads
--       from roles order by key;
--   Admin should read true/true, in_house_sales true/false.
--
--   Then sign in as an in-house rep for real (not Preview as): leads from
--   the public form should be there, an agent's own leads should not.
-- =============================================================================

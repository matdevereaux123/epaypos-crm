-- =============================================================================
-- EPAY POS / Envision ATM Control Center — who you may assign work to
-- ---------------------------------------------------------------------------
-- Run after 26_downline_visibility.sql.
--
-- leads_write's with-check validates linked_partner_id and says nothing about
-- assigned_to, so a portal user could reassign a lead to ANY user id. Since
-- assignment is what grants access — leads_select matches on assigned_to —
-- that let an agent hand a record to anyone at all.
--
-- Why this is a trigger and not a policy: a with-check is evaluated against
-- the new row on every write, with no view of the old one. Constraining
-- assigned_to there would block an agent from editing a lead that someone
-- internal had assigned elsewhere — the value would be "wrong" even though
-- they never touched it. A trigger can compare OLD and NEW and only object
-- when the assignment actually changes.
--
-- The rule: anyone with fullDashboard assigns freely. Everyone else may
-- assign only to themselves, or to someone whose partner record sits beneath
-- theirs in the recruiting tree. Unassigning is always allowed.
-- =============================================================================

create or replace function current_user_may_assign_to(p_target_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    -- staff assign freely
    coalesce(current_app_has_perm('fullDashboard'), false)
    -- clearing an assignment is always fine
    or p_target_user is null
    -- to yourself
    or p_target_user = current_app_user_id()
    -- or to someone in your downline
    or exists (
      select 1
        from users target
        join users me on me.auth_id = auth.uid()
       where target.id = p_target_user
         and me.linked_partner_id is not null
         and target.linked_partner_id is not null
         and target.linked_partner_id in (select partner_downline_ids(me.linked_partner_id))
    );
$$;

revoke execute on function current_user_may_assign_to(uuid) from public;
revoke execute on function current_user_may_assign_to(uuid) from anon;
grant execute on function current_user_may_assign_to(uuid) to authenticated;


create or replace function enforce_assignment_scope()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Only when the assignment itself changes. An unrelated edit to a row that
  -- happens to be assigned elsewhere is none of this trigger's business.
  if TG_OP = 'UPDATE' and NEW.assigned_to is not distinct from OLD.assigned_to then
    return NEW;
  end if;

  if not current_user_may_assign_to(NEW.assigned_to) then
    raise exception 'You can only assign work to yourself or to someone in your downline';
  end if;

  return NEW;
end;
$$;


drop trigger if exists leads_assignment_scope on leads;
create trigger leads_assignment_scope
  before insert or update on leads
  for each row execute function enforce_assignment_scope();

drop trigger if exists cold_leads_assignment_scope on cold_leads;
create trigger cold_leads_assignment_scope
  before insert or update on cold_leads
  for each row execute function enforce_assignment_scope();

drop trigger if exists applications_assignment_scope on applications;
create trigger applications_assignment_scope
  before insert or update on applications
  for each row execute function enforce_assignment_scope();


-- =============================================================================
-- AFTER RUNNING THIS
--   As an agent, assigning one of your leads to yourself or to someone you
--   recruited should work, and assigning it to an unrelated user should be
--   refused. Editing any other field on a lead assigned elsewhere must still
--   work — that is the case the trigger exists to protect.
-- =============================================================================

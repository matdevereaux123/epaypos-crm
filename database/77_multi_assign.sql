-- =============================================================================
-- EPAY POS / Envision ATM Control Center — assign a record to several people
-- ---------------------------------------------------------------------------
-- Run after 76_task_organisation.sql. Safe to re-run.
--
-- Adds assigned_to_ids uuid[] to tasks, leads, cold_leads, applications and
-- recruit_leads, alongside the existing single assigned_to column (kept, not
-- replaced — everything that already reads assigned_to alone keeps working).
-- assigned_to_ids[1] mirrors assigned_to going forward.
--
-- Direction matters, and is deliberately one-way: a trigger fills the ARRAY
-- from the single column only when the array is empty (covers old code that
-- has never heard of assigned_to_ids — public_submit_application, scripts,
-- the portal-ownership triggers that default assigned_to to the author).
-- It never fills the single column from the array, because that direction
-- cannot tell "caller didn't mention assigned_to_ids" apart from "caller
-- re-sent the same array" — SQL UPDATE simply leaves an unmentioned column
-- at its old value either way. So the app is what keeps them in sync: every
-- save that changes who a record is assigned to now sends assigned_to and
-- assigned_to_ids together in the same call.
--
-- WHY THE SCOPE CHECK NEEDED CHANGING (leads / cold_leads / applications)
-- enforce_assignment_scope() (27_assignment_scope.sql) exists specifically
-- because a portal user could otherwise hand a record to anyone at all —
-- its own header calls that out as the bug it closed. It only ever checked
-- the single assigned_to column. A multi-assign write that put someone
-- outside a portal user's downline into assigned_to_ids — while leaving
-- assigned_to itself pointed at someone allowed — would have walked right
-- past that check. The function below now validates every id in the array
-- the same way it already validated the one column. tasks and recruit_leads
-- have no such restriction today (tasks_write already lets a portal user
-- assign to anyone, per its own with-check), so they get the array-fill
-- only, not a new restriction.
-- =============================================================================

alter table tasks         add column if not exists assigned_to_ids uuid[] not null default '{}'::uuid[];
alter table leads         add column if not exists assigned_to_ids uuid[] not null default '{}'::uuid[];
alter table cold_leads    add column if not exists assigned_to_ids uuid[] not null default '{}'::uuid[];
alter table applications  add column if not exists assigned_to_ids uuid[] not null default '{}'::uuid[];
alter table recruit_leads add column if not exists assigned_to_ids uuid[] not null default '{}'::uuid[];

create index if not exists tasks_assigned_to_ids_idx        on tasks         using gin (assigned_to_ids);
create index if not exists leads_assigned_to_ids_idx        on leads         using gin (assigned_to_ids);
create index if not exists cold_leads_assigned_to_ids_idx   on cold_leads    using gin (assigned_to_ids);
create index if not exists applications_assigned_to_ids_idx on applications  using gin (assigned_to_ids);

-- Carry over what is already assigned so existing records show up correctly
-- the first time the new checklist renders, before anyone re-saves them.
update tasks         set assigned_to_ids = ARRAY[assigned_to] where assigned_to is not null and coalesce(array_length(assigned_to_ids,1),0) = 0;
update leads          set assigned_to_ids = ARRAY[assigned_to] where assigned_to is not null and coalesce(array_length(assigned_to_ids,1),0) = 0;
update cold_leads     set assigned_to_ids = ARRAY[assigned_to] where assigned_to is not null and coalesce(array_length(assigned_to_ids,1),0) = 0;
update applications   set assigned_to_ids = ARRAY[assigned_to] where assigned_to is not null and coalesce(array_length(assigned_to_ids,1),0) = 0;
update recruit_leads  set assigned_to_ids = ARRAY[assigned_to] where assigned_to is not null and coalesce(array_length(assigned_to_ids,1),0) = 0;

-- ---------------------------------------------------------------------------
-- leads / cold_leads / applications: extend the existing downline-scope
-- trigger function in place — every table using it (via its own
-- {table}_assignment_scope trigger, already created) picks up the change
-- with no new trigger to attach.
-- ---------------------------------------------------------------------------
create or replace function enforce_assignment_scope()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if NEW.assigned_to_ids is null then
    NEW.assigned_to_ids := '{}'::uuid[];
  end if;
  if array_length(NEW.assigned_to_ids, 1) is null and NEW.assigned_to is not null then
    NEW.assigned_to_ids := ARRAY[NEW.assigned_to];
  end if;

  if TG_OP = 'UPDATE'
     and NEW.assigned_to is not distinct from OLD.assigned_to
     and NEW.assigned_to_ids = coalesce(OLD.assigned_to_ids, '{}'::uuid[]) then
    return NEW;
  end if;

  if not current_user_may_assign_to(NEW.assigned_to) then
    raise exception 'You can only assign work to yourself or to someone in your downline';
  end if;

  foreach v_id in array NEW.assigned_to_ids loop
    if not current_user_may_assign_to(v_id) then
      raise exception 'You can only assign work to yourself or to someone in your downline';
    end if;
  end loop;

  return NEW;
end;
$$;

-- ---------------------------------------------------------------------------
-- tasks / recruit_leads: same array-fill, no scope restriction to extend.
-- ---------------------------------------------------------------------------
create or replace function fill_assigned_to_ids_from_single()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if NEW.assigned_to_ids is null then
    NEW.assigned_to_ids := '{}'::uuid[];
  end if;
  if array_length(NEW.assigned_to_ids, 1) is null and NEW.assigned_to is not null then
    NEW.assigned_to_ids := ARRAY[NEW.assigned_to];
  end if;
  return NEW;
end;
$$;

drop trigger if exists tasks_fill_assigned_to_ids on tasks;
create trigger tasks_fill_assigned_to_ids
  before insert or update on tasks
  for each row execute function fill_assigned_to_ids_from_single();

drop trigger if exists recruit_leads_fill_assigned_to_ids on recruit_leads;
create trigger recruit_leads_fill_assigned_to_ids
  before insert or update on recruit_leads
  for each row execute function fill_assigned_to_ids_from_single();

-- ---------------------------------------------------------------------------
-- RLS: visible/writable if you are the primary assignee OR anywhere in the
-- array OR (existing rules) creator / downline / fullDashboard.
-- ---------------------------------------------------------------------------
drop policy if exists "tasks_select" on tasks;
create policy "tasks_select" on tasks
  for select to authenticated
  using (
    current_app_has_perm('fullDashboard')
    or created_by = current_app_user_id()
    or assigned_to = current_app_user_id()
    or current_app_user_id() = ANY(assigned_to_ids)
  );

drop policy if exists "tasks_write" on tasks;
create policy "tasks_write" on tasks
  for all to authenticated
  using (
    current_app_has_perm('fullDashboard')
    or created_by = current_app_user_id()
    or assigned_to = current_app_user_id()
    or current_app_user_id() = ANY(assigned_to_ids)
  )
  with check (
    current_app_has_perm('fullDashboard')
    or created_by = current_app_user_id()
    or assigned_to = current_app_user_id()
    or current_app_user_id() = ANY(assigned_to_ids)
  );

drop policy if exists "leads_select" on leads;
create policy "leads_select" on leads
  for select to authenticated
  using (
    current_app_has_perm('viewAllLeads')
    or linked_partner_id = current_app_linked_partner_id()
    or assigned_to       = current_app_user_id()
    or current_app_user_id() = ANY(assigned_to_ids)
    or created_by        = current_app_user_id()
    or (current_app_has_perm('fullDashboard') and created_by is null)
  );

drop policy if exists "leads_write" on leads;
create policy "leads_write" on leads
  for all to authenticated
  using (
    current_app_has_perm('viewAllLeads')
    or linked_partner_id = current_app_linked_partner_id()
    or assigned_to       = current_app_user_id()
    or current_app_user_id() = ANY(assigned_to_ids)
    or created_by        = current_app_user_id()
    or (current_app_has_perm('fullDashboard') and created_by is null)
  )
  with check (
    current_app_has_perm('viewAllLeads')
    or linked_partner_id = current_app_linked_partner_id()
    or assigned_to       = current_app_user_id()
    or current_app_user_id() = ANY(assigned_to_ids)
    or created_by        = current_app_user_id()
    or (current_app_has_perm('fullDashboard') and created_by is null)
  );

drop policy if exists "cold_leads_select" on cold_leads;
create policy "cold_leads_select" on cold_leads
  for select to authenticated
  using (
    current_app_has_perm('fullDashboard')
    or assigned_to = current_app_user_id()
    or current_app_user_id() = ANY(assigned_to_ids)
  );

drop policy if exists "cold_leads_update" on cold_leads;
create policy "cold_leads_update" on cold_leads
  for update to authenticated
  using (
    current_app_has_perm('fullDashboard')
    or assigned_to = current_app_user_id()
    or current_app_user_id() = ANY(assigned_to_ids)
  )
  with check (
    current_app_has_perm('fullDashboard')
    or assigned_to = current_app_user_id()
    or current_app_user_id() = ANY(assigned_to_ids)
  );

drop policy if exists "cold_leads_insert" on cold_leads;
create policy "cold_leads_insert" on cold_leads
  for insert to authenticated
  with check (
    current_app_has_perm('fullDashboard')
    or assigned_to = current_app_user_id()
    or current_app_user_id() = ANY(assigned_to_ids)
  );

drop policy if exists "applications_select" on applications;
create policy "applications_select" on applications
  for select to authenticated
  using (
    current_app_has_perm('fullDashboard')
    or assigned_to = current_app_user_id()
    or current_app_user_id() = ANY(assigned_to_ids)
  );

drop policy if exists "applications_update" on applications;
create policy "applications_update" on applications
  for update to authenticated
  using (
    current_app_has_perm('fullDashboard')
    or assigned_to = current_app_user_id()
    or current_app_user_id() = ANY(assigned_to_ids)
  )
  with check (
    current_app_has_perm('fullDashboard')
    or assigned_to = current_app_user_id()
    or current_app_user_id() = ANY(assigned_to_ids)
  );

-- =============================================================================
-- AFTER RUNNING THIS
--   As an agent, open a lead and check a teammate under the new "Assigned
--   to" checklist alongside yourself; save; confirm it in their own login.
--   As the same agent, try checking someone OUTSIDE your downline and
--   confirm the save is refused. As admin, confirm the multi-assign
--   checklist works with no restriction on Tasks, Leads, Cold Leads,
--   Applications and Recruiting.
-- =============================================================================

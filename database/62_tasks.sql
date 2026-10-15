-- =============================================================================
-- EPAY POS / Envision ATM Control Center — Tasks
-- ---------------------------------------------------------------------------
-- Run after 61_application_link_cold_lead.sql.
--
-- A task can optionally point at the record it's about (a lead/account, a
-- cold lead, or an application) — all three nullable, at most one set,
-- exactly like calendar_events already does with linked_cold_lead_id /
-- linked_lead_id. A bare task with nothing linked is also valid — "call the
-- bank" doesn't need a record.
--
-- Ownership follows the same shape as cold_leads/contacts/lending_leads
-- (57_portal_users_can_add_records.sql): created_by is stamped by trigger,
-- never trusted from the browser. Visibility is created_by OR assigned_to,
-- so handing a task to someone (assigned_to) shows it on their list even
-- though they didn't create it — staff (fullDashboard) sees every task.
-- =============================================================================

create table if not exists tasks (
  id                      uuid primary key default gen_random_uuid(),
  title                   text not null,
  notes                   text,
  due_date                date,
  completed               boolean not null default false,
  completed_at            timestamptz,
  created_by              uuid references users(id) on delete set null,
  assigned_to             uuid references users(id) on delete set null,
  linked_lead_id          uuid references leads(id) on delete set null,
  linked_cold_lead_id     uuid references cold_leads(id) on delete set null,
  linked_application_id   uuid references applications(id) on delete set null,
  created_at              timestamptz not null default now()
);
create index if not exists tasks_assigned_to_idx on tasks (assigned_to, completed);
create index if not exists tasks_created_by_idx on tasks (created_by);

alter table tasks enable row level security;

drop policy if exists "tasks_select" on tasks;
drop policy if exists "tasks_write" on tasks;

create policy "tasks_select" on tasks
  for select to authenticated
  using (
    current_app_has_perm('fullDashboard')
    or created_by = current_app_user_id()
    or assigned_to = current_app_user_id()
  );

create policy "tasks_write" on tasks
  for all to authenticated
  using (
    current_app_has_perm('fullDashboard')
    or created_by = current_app_user_id()
    or assigned_to = current_app_user_id()
  )
  with check (
    current_app_has_perm('fullDashboard')
    or created_by = current_app_user_id()
    or assigned_to = current_app_user_id()
  );

create or replace function tasks_stamp_created_by()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := current_app_user_id();
begin
  if v_me is null then return NEW; end if;
  if TG_OP = 'INSERT' then
    NEW.created_by := v_me;
    if NEW.assigned_to is null then NEW.assigned_to := v_me; end if;
  elsif NEW.created_by is distinct from OLD.created_by
        and not coalesce(current_app_has_perm('fullDashboard'), false) then
    raise exception 'You cannot change who created this task';
  end if;
  return NEW;
end;
$$;

drop trigger if exists tasks_stamp_created_by on tasks;
create trigger tasks_stamp_created_by
  before insert or update on tasks
  for each row execute function tasks_stamp_created_by();

-- =============================================================================
-- AFTER RUNNING THIS
--   As an agent, add a task from the new + button, confirm it lands on
--   their own Tasks list under Overview, and that a different agent cannot
--   see it. As staff, confirm every task from every user is visible.
-- =============================================================================

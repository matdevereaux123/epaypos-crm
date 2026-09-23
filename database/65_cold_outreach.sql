-- =============================================================================
-- EPAY POS / Envision ATM Control Center — Cold Outreach (Prospecting)
-- ---------------------------------------------------------------------------
-- Run after 64_meeting_reminders.sql.
--
-- A basic log of in-person prospecting: places someone physically went to
-- door-knock/drop by, with whatever they picked up while there — a business
-- name and address at minimum, a contact name/phone/email if they got one.
-- Deliberately NOT cold_leads: no temperature, no source category, no
-- follow-up scheduling, no promotion pipeline. If one of these turns into
-- something real, it gets entered as its own Cold Lead by hand — this table
-- is just the visit log.
--
-- Ownership follows the exact shape already proven out for cold_leads in
-- 57_portal_users_can_add_records.sql: assigned_to defaults to whoever
-- created it (cold_outreach_portal_ownership, mirroring
-- cold_leads_portal_ownership), created_by is stamped and locked by the
-- existing portal_stamp_created_by() trigger (reused, not redefined),
-- staff (fullDashboard) sees and manages everything, everyone else sees
-- their own, and only the creator can delete their own entry.
-- =============================================================================

create table if not exists cold_outreach (
  id             uuid primary key default gen_random_uuid(),
  business_name  text not null,
  address        text,
  contact_name   text,
  contact_phone  text,
  contact_email  text,
  notes          text,
  created_by     uuid references users(id) on delete set null,
  assigned_to    uuid references users(id) on delete set null,
  created_at     date not null default current_date
);
create index if not exists cold_outreach_assigned_to_idx on cold_outreach (assigned_to);

alter table cold_outreach enable row level security;

create or replace function cold_outreach_portal_ownership()
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

drop trigger if exists cold_outreach_portal_ownership on cold_outreach;
create trigger cold_outreach_portal_ownership
  before insert on cold_outreach
  for each row execute function cold_outreach_portal_ownership();

drop trigger if exists cold_outreach_stamp_created_by on cold_outreach;
create trigger cold_outreach_stamp_created_by
  before insert or update on cold_outreach
  for each row execute function portal_stamp_created_by();

drop policy if exists "cold_outreach_select" on cold_outreach;
create policy "cold_outreach_select" on cold_outreach
  for select to authenticated
  using (
    current_app_has_perm('fullDashboard')
    or assigned_to = current_app_user_id()
    or created_by = current_app_user_id()
  );

drop policy if exists "cold_outreach_insert" on cold_outreach;
create policy "cold_outreach_insert" on cold_outreach
  for insert to authenticated
  with check (
    current_app_has_perm('fullDashboard')
    or assigned_to = current_app_user_id()
  );

drop policy if exists "cold_outreach_update" on cold_outreach;
create policy "cold_outreach_update" on cold_outreach
  for update to authenticated
  using (
    current_app_has_perm('fullDashboard')
    or assigned_to = current_app_user_id()
    or created_by = current_app_user_id()
  )
  with check (
    current_app_has_perm('fullDashboard')
    or assigned_to = current_app_user_id()
    or created_by = current_app_user_id()
  );

-- Only your own — same reasoning as cold_leads: something an admin handed
-- you (or that a teammate logged) is yours to work, not yours to throw away.
drop policy if exists "cold_outreach_delete" on cold_outreach;
create policy "cold_outreach_delete" on cold_outreach
  for delete to authenticated
  using (
    current_app_has_perm('fullDashboard')
    or created_by = current_app_user_id()
  );

-- =============================================================================
-- AFTER RUNNING THIS
--   As a non-admin (agent/ISO/in-house), add a Cold Outreach entry under the
--   new Prospecting section, confirm it shows on your own list, and that a
--   different non-admin user cannot see it. As staff, confirm you see every
--   entry from everyone.
-- =============================================================================

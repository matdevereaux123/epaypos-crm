-- =============================================================================
-- EPAY POS / Envision ATM Control Center — calendars belong to people
-- ---------------------------------------------------------------------------
-- Run after 37_calendar_two_way_sync.sql.
--
-- calendar_events had one policy:
--
--     for all to authenticated using (current_app_has_perm('fullDashboard'))
--
-- Every internal user could read and write every row. That was survivable
-- while the calendar only ever held meetings this system booked itself. It
-- stopped being survivable the moment 37 started importing people's real
-- Google Calendars — dentist appointments, school runs, interviews — into the
-- same table.
--
-- The distinction this file draws:
--
--   google_origin = false   a meeting booked in the CRM. Work. The team
--                           schedules around each other, so everyone internal
--                           can see it, and an admin can fix one.
--
--   google_origin = true    pulled in from somebody's personal Google
--                           Calendar. Theirs. Only they can see it, and only
--                           they can change it — an admin cannot, deliberately.
--                           Being able to manage the system is not a reason to
--                           read someone's private diary.
-- =============================================================================

alter table calendar_events
  add column if not exists owner_id uuid references users(id) on delete set null;

create index if not exists calendar_events_owner_idx on calendar_events (owner_id);


-- Existing rows: an event filed under a linked calendar belongs to whoever
-- linked it. Anything else keeps a null owner and stays team-editable, which
-- is exactly how it behaved before this file — no one loses access to
-- something they could reach yesterday.
update calendar_events e
   set owner_id = c.user_id
  from connected_calendars c
 where e.calendar_id = c.id
   and c.user_id is not null
   and e.owner_id is null;


-- ---------------------------------------------------------------------------
-- Ownership is set server-side, not by whoever sends the insert.
--
-- A trigger rather than a default, because it has to look at calendar_id --
-- and because a client that simply omits owner_id must not end up creating an
-- unowned row that everyone can edit.
-- ---------------------------------------------------------------------------
create or replace function calendar_events_set_owner()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.owner_id is null and new.calendar_id is not null then
    select user_id into new.owner_id from connected_calendars where id = new.calendar_id;
  end if;

  -- Falls back to the caller. Null when the edge function writes as the
  -- service role, which is fine: those inserts always carry a calendar_id,
  -- so the branch above has already answered.
  if new.owner_id is null then
    new.owner_id := current_app_user_id();
  end if;

  return new;
end;
$$;

drop trigger if exists calendar_events_owner_trg on calendar_events;
create trigger calendar_events_owner_trg
  before insert on calendar_events
  for each row execute function calendar_events_set_owner();


-- ---------------------------------------------------------------------------
-- The policies.
-- ---------------------------------------------------------------------------
drop policy if exists "calendar_events_all"    on calendar_events;
drop policy if exists "calendar_events_select" on calendar_events;
drop policy if exists "calendar_events_insert" on calendar_events;
drop policy if exists "calendar_events_update" on calendar_events;
drop policy if exists "calendar_events_delete" on calendar_events;

-- Work is shared. Someone's own Google Calendar is not.
create policy "calendar_events_select" on calendar_events
  for select to authenticated
  using (
    coalesce(current_app_has_perm('fullDashboard'), false)
    and (
      google_origin = false
      or owner_id is null
      or owner_id = current_app_user_id()
    )
  );

create policy "calendar_events_insert" on calendar_events
  for insert to authenticated
  with check (
    coalesce(current_app_has_perm('fullDashboard'), false)
    -- Nobody books into someone else's name. The trigger has already run by
    -- the time this is checked, so owner_id is populated.
    and (owner_id is null or owner_id = current_app_user_id())
  );

-- Work events: yours, unowned legacy ones, or an admin tidying up.
-- Personal events: yours alone.
create policy "calendar_events_update" on calendar_events
  for update to authenticated
  using (
    coalesce(current_app_has_perm('fullDashboard'), false)
    and (
      case when google_origin
           then owner_id = current_app_user_id()
           else owner_id is null
                or owner_id = current_app_user_id()
                or coalesce(current_app_has_perm('manageSettings'), false)
      end
    )
  );

create policy "calendar_events_delete" on calendar_events
  for delete to authenticated
  using (
    coalesce(current_app_has_perm('fullDashboard'), false)
    and (
      case when google_origin
           then owner_id = current_app_user_id()
           else owner_id is null
                or owner_id = current_app_user_id()
                or coalesce(current_app_has_perm('manageSettings'), false)
      end
    )
  );


-- =============================================================================
-- AFTER RUNNING THIS
--   Redeploy the google-calendar function so imports stamp an owner.
--
--   To check it from an ordinary internal login, not an admin one:
--     select count(*) from calendar_events where google_origin;
--   should count only that person's own imported events, never a colleague's.
-- =============================================================================

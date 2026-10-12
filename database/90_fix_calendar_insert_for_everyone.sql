/* =========================================================================
   90_fix_calendar_insert_for_everyone.sql

     "Could not schedule meeting: new row violates row-level security policy
      for table calendar_events"

   reported by an agent. The insert check that is supposed to be live is
   permissive —

       owner_id is null or owner_id = current_app_user_id()

   — so the only way to violate it is for owner_id to land on somebody
   else. There are exactly two ways that happens, and this file closes
   both, because the live policies cannot be read from outside the database
   and guessing which one it is would be a coin toss.

   1. database/52_calendar_per_user.sql never ran.
      Before it, calendar was admin-only (database/47): every calendar
      policy began with manageUsers. The app has shown the Calendar tab to
      everyone since 52, so a non-admin would get exactly this error on
      insert — and would also have been seeing an empty calendar without
      necessarily noticing. Re-asserting 52's policies here is a no-op if
      they are already in place.

   2. The ownership trigger inherited an owner from somebody else's
      calendar.
      calendar_events_set_owner() takes owner_id from
      connected_calendars.user_id for the chosen calendar_id, and it is
      SECURITY DEFINER, so it reads every row regardless of who is asking.
      Any path that puts another person's calendar_id on the insert —
      a stale row, a shared calendar, a dropdown that was not scoped when
      the page was loaded — stamps their id on the event and the check
      then refuses it.

      Inheriting is right for the edge function, which writes as the
      service role while importing somebody's Google events. It is wrong
      for a person: a meeting somebody books is theirs. So the trigger now
      only inherits when the caller has no app identity at all, which is
      exactly the service-role case.

   The insert check also now lets whoever manages users book on another
   person's behalf, which is the one legitimate reason to set an owner_id
   that is not your own.
   ========================================================================= */

-- ------------------------------------------------------------- the trigger
create or replace function calendar_events_set_owner()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := current_app_user_id();
begin
  -- A real person booking a meeting owns it, whatever calendar it is
  -- filed against. Only an identity-less caller — the edge function
  -- writing as the service role — inherits the calendar's owner.
  if v_me is not null then
    if new.owner_id is null then
      new.owner_id := v_me;
    end if;
    return new;
  end if;

  if new.owner_id is null and new.calendar_id is not null then
    select user_id into new.owner_id from connected_calendars where id = new.calendar_id;
  end if;

  return new;
end;
$$;


-- -------------------------------------------------------------- the policies
-- Identical in effect to database/52_calendar_per_user.sql, restated so this
-- file repairs the case where that one never ran. Dropping by name first
-- means it does not matter which version is currently in place.
drop policy if exists "calendar_events_all"    on calendar_events;
drop policy if exists "calendar_events_select" on calendar_events;
drop policy if exists "calendar_events_insert" on calendar_events;
drop policy if exists "calendar_events_update" on calendar_events;
drop policy if exists "calendar_events_delete" on calendar_events;

create policy "calendar_events_select" on calendar_events
  for select to authenticated
  using (
    owner_id = current_app_user_id()
    or coalesce(current_app_has_perm('manageUsers'), false)
  );

create policy "calendar_events_insert" on calendar_events
  for insert to authenticated
  with check (
    owner_id is null
    or owner_id = current_app_user_id()
    -- Booking on somebody else's behalf: the one honest reason to write an
    -- owner_id that is not your own.
    or coalesce(current_app_has_perm('manageUsers'), false)
  );

create policy "calendar_events_update" on calendar_events
  for update to authenticated
  using (
    owner_id = current_app_user_id()
    or coalesce(current_app_has_perm('manageUsers'), false)
  )
  with check (
    owner_id = current_app_user_id()
    or coalesce(current_app_has_perm('manageUsers'), false)
  );

create policy "calendar_events_delete" on calendar_events
  for delete to authenticated
  using (
    owner_id = current_app_user_id()
    or coalesce(current_app_has_perm('manageUsers'), false)
  );


drop policy if exists "connected_calendars_all"    on connected_calendars;
drop policy if exists "connected_calendars_select" on connected_calendars;
drop policy if exists "connected_calendars_insert" on connected_calendars;
drop policy if exists "connected_calendars_update" on connected_calendars;
drop policy if exists "connected_calendars_delete" on connected_calendars;

create policy "connected_calendars_select" on connected_calendars
  for select to authenticated
  using (
    user_id = current_app_user_id()
    or coalesce(current_app_has_perm('manageUsers'), false)
  );

create policy "connected_calendars_insert" on connected_calendars
  for insert to authenticated
  with check (user_id = current_app_user_id());

create policy "connected_calendars_update" on connected_calendars
  for update to authenticated
  using (user_id = current_app_user_id())
  with check (user_id = current_app_user_id());

create policy "connected_calendars_delete" on connected_calendars
  for delete to authenticated
  using (user_id = current_app_user_id());

/* =========================================================================
   AFTER RUNNING THIS
     Have Mitch schedule a meeting. It should save, and show on his
     calendar and nobody else's.

     If it still refuses, the cause is neither of the two above and the
     next thing to look at is whether his login resolves to a CRM user at
     all — current_app_user_id() returning null is survivable here (the
     check allows a null owner) but would mean the event belongs to
     nobody, which is worth knowing either way.
   ========================================================================= */

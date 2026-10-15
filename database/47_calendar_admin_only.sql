-- =============================================================================
-- EPAY POS / Envision ATM Control Center — Calendar, admin-only for now
-- ---------------------------------------------------------------------------
-- Run after 38_calendar_ownership.sql.
--
-- Calendar access was fullDashboard-gated, which in_house_sales also holds —
-- so tightening the app's nav to fullDashboard (the previous fix) still left
-- every non-admin internal user able to read/write calendar_events and
-- connected_calendars directly through the API, nav hidden or not. This
-- narrows every policy on both tables to manageUsers specifically — the
-- same permission the app already treats as "is the Admin role" (see
-- `const isAdmin = perms.manageUsers` in app/index.html) — so the database
-- itself now matches "admins only, nobody else" rather than the UI being the
-- only thing enforcing it.
--
-- connected_calendars_update/delete also drops the "or you own this row"
-- carve-out from 35_google_calendar_oauth.sql — an admin manages every
-- connection for now, not just their own. Revisit if/when this opens back
-- up beyond admins.
-- =============================================================================

drop policy if exists "calendar_events_select" on calendar_events;
drop policy if exists "calendar_events_insert" on calendar_events;
drop policy if exists "calendar_events_update" on calendar_events;
drop policy if exists "calendar_events_delete" on calendar_events;

create policy "calendar_events_select" on calendar_events
  for select to authenticated
  using (
    coalesce(current_app_has_perm('manageUsers'), false)
    and (
      google_origin = false
      or owner_id is null
      or owner_id = current_app_user_id()
    )
  );

create policy "calendar_events_insert" on calendar_events
  for insert to authenticated
  with check (
    coalesce(current_app_has_perm('manageUsers'), false)
    and (owner_id is null or owner_id = current_app_user_id())
  );

create policy "calendar_events_update" on calendar_events
  for update to authenticated
  using (
    coalesce(current_app_has_perm('manageUsers'), false)
    and (
      case when google_origin
           then owner_id = current_app_user_id()
           else owner_id is null or owner_id = current_app_user_id()
      end
    )
  );

create policy "calendar_events_delete" on calendar_events
  for delete to authenticated
  using (
    coalesce(current_app_has_perm('manageUsers'), false)
    and (
      case when google_origin
           then owner_id = current_app_user_id()
           else owner_id is null or owner_id = current_app_user_id()
      end
    )
  );

drop policy if exists "connected_calendars_select" on connected_calendars;
drop policy if exists "connected_calendars_insert" on connected_calendars;
drop policy if exists "connected_calendars_update" on connected_calendars;
drop policy if exists "connected_calendars_delete" on connected_calendars;

create policy "connected_calendars_select" on connected_calendars
  for select to authenticated
  using (coalesce(current_app_has_perm('manageUsers'), false));

create policy "connected_calendars_insert" on connected_calendars
  for insert to authenticated
  with check (coalesce(current_app_has_perm('manageUsers'), false));

create policy "connected_calendars_update" on connected_calendars
  for update to authenticated
  using (coalesce(current_app_has_perm('manageUsers'), false));

create policy "connected_calendars_delete" on connected_calendars
  for delete to authenticated
  using (coalesce(current_app_has_perm('manageUsers'), false));

-- =============================================================================
-- AFTER RUNNING THIS
--   Log in as anyone other than Admin and confirm the Calendar tab is gone
--   AND that a direct query (e.g. from the SQL editor's authenticated role
--   impersonation, or the browser console while logged in as them) against
--   calendar_events / connected_calendars returns nothing.
-- =============================================================================

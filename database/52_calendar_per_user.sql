-- =============================================================================
-- EPAY POS / Envision ATM Control Center — Calendar reopened, per-user
-- ---------------------------------------------------------------------------
-- Run after 47_calendar_admin_only.sql.
--
-- 47 narrowed Calendar to admins only, after a real gap (UI-only hiding, no
-- matching RLS) left it borderline for anyone who wasn't full staff. This
-- reopens it to Agents, Referral Partners, ISOs, and In-House Sales — but
-- each one sees and manages only their own calendar_events/connected_calendars
-- rows. This is NOT a return to the pre-47 model, where every fullDashboard
-- holder could see every other internal staffer's "work" meetings (see
-- 38_calendar_ownership.sql) — that shared-team-calendar concept is dropped
-- entirely here, since the audience now includes external portal logins who
-- have no business seeing an internal meeting, let alone the Admin's.
-- Admin (manageUsers) keeps the ability to see/manage every row, for genuine
-- oversight/fixing — everyone else only ever sees their own, full stop.
-- =============================================================================

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
    -- The ownership trigger (calendar_events_set_owner(), 38) has already run
    -- by the time this check happens, so owner_id is populated. Nobody books
    -- into someone else's name.
    owner_id is null or owner_id = current_app_user_id()
  );

create policy "calendar_events_update" on calendar_events
  for update to authenticated
  using (
    owner_id = current_app_user_id()
    or coalesce(current_app_has_perm('manageUsers'), false)
  );

create policy "calendar_events_delete" on calendar_events
  for delete to authenticated
  using (
    owner_id = current_app_user_id()
    or coalesce(current_app_has_perm('manageUsers'), false)
  );

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
  with check (
    user_id = current_app_user_id()
    or coalesce(current_app_has_perm('manageUsers'), false)
  );

create policy "connected_calendars_update" on connected_calendars
  for update to authenticated
  using (
    user_id = current_app_user_id()
    or coalesce(current_app_has_perm('manageUsers'), false)
  );

create policy "connected_calendars_delete" on connected_calendars
  for delete to authenticated
  using (
    user_id = current_app_user_id()
    or coalesce(current_app_has_perm('manageUsers'), false)
  );

-- =============================================================================
-- AFTER RUNNING THIS
--   Log in as an Agent or Referral Partner and confirm: the Calendar tab is
--   back, "Connect with Google" works for their own account, and any events
--   they create only ever show on their own calendar — never the Admin's or
--   another agent's. Log in as Admin and confirm you can still see and fix
--   anyone's row directly (e.g. from the SQL editor's authenticated role
--   impersonation), but a non-admin querying calendar_events/
--   connected_calendars directly still gets back only their own rows.
-- =============================================================================

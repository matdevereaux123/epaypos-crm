-- =============================================================================
-- 108 - A calendar belongs to the person whose calendar it is.
--
-- 90 let anyone holding manageUsers read every connected calendar and every
-- event on it. manageUsers is how a role is marked as administrative, and it
-- is handed to every sub-admin role somebody creates in Settings - so adding
-- an office manager, a team lead or a second admin quietly handed them the
-- owner's Google calendar. A permission about managing users should not be
-- the one that unlocks reading someone's diary.
--
-- Three changes:
--
--   * connected_calendars: the owner, and nobody else. Which Google account
--     somebody linked is not administrative information, and no screen in
--     the CRM needs another person's row.
--
--   * calendar_events: the owner, or someone explicitly granted
--     viewAllCalendars. That permission is new, nobody has it by default,
--     and the built-in Admin role is given it in the app so the person who
--     runs the company keeps the team view they already had. A custom role
--     gets it only if somebody ticks it.
--
--   * Attendees still gain nothing, exactly as 63 intended: being invited to
--     a meeting puts it on your Google calendar, not in your CRM.
--
-- Safe to run twice.
-- =============================================================================

drop policy if exists "connected_calendars_select" on connected_calendars;
create policy "connected_calendars_select" on connected_calendars
  for select to authenticated
  using ( user_id = current_app_user_id() );

drop policy if exists "calendar_events_select" on calendar_events;
create policy "calendar_events_select" on calendar_events
  for select to authenticated
  using (
    owner_id = current_app_user_id()
    or coalesce(current_app_has_perm('viewAllCalendars'), false)
  );

-- The same hole was in update and delete: manageUsers could edit or remove
-- somebody else's meeting, which is the half of this that loses work rather
-- than just reading it. Both now follow the select rule.
drop policy if exists "calendar_events_update" on calendar_events;
create policy "calendar_events_update" on calendar_events
  for update to authenticated
  using (
    owner_id = current_app_user_id()
    or coalesce(current_app_has_perm('viewAllCalendars'), false)
  )
  with check (
    owner_id = current_app_user_id()
    or coalesce(current_app_has_perm('viewAllCalendars'), false)
  );

drop policy if exists "calendar_events_delete" on calendar_events;
create policy "calendar_events_delete" on calendar_events
  for delete to authenticated
  using (
    owner_id = current_app_user_id()
    or coalesce(current_app_has_perm('viewAllCalendars'), false)
  );

-- connected_calendars insert, update and delete were already owner-only in
-- 90 and are left exactly as they are.

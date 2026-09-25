-- =============================================================================
-- EPAY POS / Envision ATM Control Center — meeting reminders + invite emails
-- ---------------------------------------------------------------------------
-- Run after 63_meeting_attendees.sql.
--
-- Two separate things land in this one migration because they share the
-- same new columns:
--
--   1. "Also invite" (63) already adds someone to a meeting and pushes them
--      to Google as an attendee. This adds a CRM-native email on top of
--      that — sent by the google-calendar edge function's new
--      notify_attendees action, so it reaches someone even if they have no
--      Google account connected. notified_attendee_ids remembers who has
--      already been told, so re-saving the same meeting twice does not
--      re-email everyone on it — only whoever is newly checked.
--
--   2. A per-meeting "Remind me 30 min before" toggle (remind_before). Firing
--      it on time needs something that runs on its own, on a schedule, with
--      nobody's browser open — this project has had no server-side
--      scheduler until now. pg_cron calls a brand new edge function
--      (supabase/functions/meeting-reminders) once a minute; it finds every
--      meeting inside its 30-minute window that has not been reminded yet,
--      emails the owner and every attendee, drops a row in `notifications`
--      for each of them (so the bell picks it up too), and stamps
--      reminder_sent_at so it never fires twice.
--
-- The scheduled job that actually fires reminders is a separate file,
-- 73_meeting_reminders_cron.sql. It used to live here; when pg_cron could not
-- be switched on the whole script failed and the columns below never got
-- added, which broke saving ANY meeting.
-- =============================================================================

alter table calendar_events
  add column if not exists attendee_user_ids     uuid[] not null default '{}'::uuid[],
  add column if not exists remind_before         boolean not null default false,
  add column if not exists reminder_sent_at      timestamptz,
  add column if not exists notified_attendee_ids uuid[] not null default '{}'::uuid[];

-- =============================================================================
-- AFTER RUNNING THIS
--   Saving a meeting works again. Reminders only actually fire once
--   73_meeting_reminders_cron.sql is run too.
-- =============================================================================

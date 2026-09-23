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
-- SETUP THIS FILE NEEDS BEFORE YOU RUN IT
--   Find your project's service_role key: Supabase Dashboard -> Project
--   Settings -> API -> service_role (the "secret" one, not anon). Paste it
--   over <YOUR_SERVICE_ROLE_KEY> below, in the cron.schedule call near the
--   bottom, before running this. It goes into cron.job, a table only the
--   project owner (you, via the SQL Editor) can query — nothing to do with
--   anon/authenticated access, same as any other server-side secret in this
--   project.
--
--   This also needs pg_cron and pg_net switched on: Dashboard -> Database ->
--   Extensions -> enable both, or the two `create extension` lines below do
--   the same thing (they may already be on).
-- =============================================================================

create extension if not exists pg_cron;
create extension if not exists pg_net;

alter table calendar_events
  add column if not exists remind_before        boolean not null default false,
  add column if not exists reminder_sent_at      timestamptz,
  add column if not exists notified_attendee_ids uuid[] not null default '{}'::uuid[];

-- Re-running this file (e.g. after editing the key below) should replace the
-- job, not stack a second copy of it.
select cron.unschedule(jobid) from cron.job where jobname = 'epay-meeting-reminders';

select cron.schedule(
  'epay-meeting-reminders',
  '* * * * *',  -- once a minute; reminder_sent_at keeps a slow tick from ever double-sending
  $$
  select net.http_post(
    url     := 'https://gfnodfqkidtqjoofvwzr.supabase.co/functions/v1/meeting-reminders',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer <YOUR_SERVICE_ROLE_KEY>'
    ),
    body := '{}'::jsonb
  );
  $$
);

-- =============================================================================
-- AFTER RUNNING THIS
--   1. Deploy the two edge function changes this migration goes with:
--      google-calendar (adds the notify_attendees action) and the brand new
--      meeting-reminders function — both from the Supabase Dashboard, since
--      this project has no CLI installed.
--   2. select * from cron.job where jobname = 'epay-meeting-reminders'; —
--      confirm it's there and active.
--   3. Schedule a meeting a few minutes out with "Remind me 30 min before"
--      on (or edit reminder_sent_at/the time by hand to force it due sooner
--      for a real test) and confirm both the notification bell and an email
--      arrive. Separately, add a teammate under "Also invite" on any meeting
--      and confirm they get the "you've been added" email.
-- =============================================================================

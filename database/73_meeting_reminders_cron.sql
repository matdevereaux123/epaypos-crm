-- =============================================================================
-- EPAY POS / Envision ATM Control Center — schedule the meeting reminder job
-- ---------------------------------------------------------------------------
-- Run after 64_meeting_reminders.sql (which adds the columns this needs).
-- Kept separate so that a problem enabling pg_cron cannot stop the columns
-- from being added — saving meetings depends on those, reminders do not.
--
-- BEFORE YOU RUN IT: replace <YOUR_SERVICE_ROLE_KEY> below with your project's
-- service_role key (Supabase Dashboard -> Project Settings -> API -> the
-- secret one, not anon). It goes into cron.job, which only the project owner
-- can query.
--
-- If the first line fails, switch pg_cron and pg_net on under Dashboard ->
-- Database -> Extensions, then run this again.
-- =============================================================================

create extension if not exists pg_cron;
create extension if not exists pg_net;

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
--   select * from cron.job where jobname = 'epay-meeting-reminders';
--   Also deploy the google-calendar and meeting-reminders edge functions
--   (Supabase Dashboard) — the job calls meeting-reminders once a minute.
-- =============================================================================

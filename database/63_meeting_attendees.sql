-- =============================================================================
-- EPAY POS / Envision ATM Control Center — attach people to a meeting
-- ---------------------------------------------------------------------------
-- Run after 62_tasks.sql.
--
-- A meeting has always had exactly one owner (whoever scheduled it) and
-- pushed to exactly that one person's Google Calendar. This adds an optional
-- list of teammates to invite alongside them — the meeting itself still
-- belongs to whoever created it (that never changes, and stays first/
-- implicit — nobody needs to add themselves), but Google can now be told
-- who else should get an invite.
--
-- Deliberately NOT a second owner and NOT CRM-side visibility for the people
-- attached: calendar_events RLS (52_calendar_per_user.sql) stays exactly as
-- strict as it is — an attendee does not gain the ability to see or edit
-- someone else's meeting in the CRM just by being invited to it. Google's
-- own invite/RSVP flow is what actually notifies them and puts it on their
-- calendar; app/index.html and the google-calendar edge function are the
-- only things that read this column.
-- =============================================================================

alter table calendar_events
  add column if not exists attendee_user_ids uuid[] not null default '{}'::uuid[];

-- =============================================================================
-- AFTER RUNNING THIS
--   Schedule a meeting, check off a teammate under "Also invite", save it,
--   and confirm (from Google's side, if connected) that they show up as an
--   invited attendee on the event Google created.
-- =============================================================================

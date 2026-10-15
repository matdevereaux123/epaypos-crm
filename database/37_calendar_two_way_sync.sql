-- =============================================================================
-- EPAY POS / Envision ATM Control Center — two-way Google Calendar sync
-- ---------------------------------------------------------------------------
-- Run after 36_fix_missing_vault_key.sql.
--
-- Sync was one-way: the CRM pushed meetings to Google and never looked back.
-- Move a meeting in Google and the CRM went on showing the old time, which is
-- worse than not syncing at all — two calendars that disagree while both
-- claim to be right.
--
-- This adds what pulling the other direction needs.
--
-- The important column is google_sync_token. Google's events.list returns a
-- nextSyncToken; handing it back next time returns ONLY what changed since,
-- including deletions (as status:"cancelled" tuples, which a plain date-range
-- query never shows). Without it there is no way to learn that an event was
-- deleted in Google — it simply stops appearing, which is indistinguishable
-- from it being outside the window you asked for.
-- =============================================================================

alter table connected_calendars
  -- Opaque to us. Google's cursor into "what has changed since".
  add column if not exists google_sync_token text,
  add column if not exists last_synced_at    timestamptz;

alter table calendar_events
  -- true  = created in Google, mirrored here
  -- false = created here, pushed there
  -- Decides who wins an edit, and stops the importer treating a meeting the
  -- CRM just pushed as a new external event and duplicating it.
  add column if not exists google_origin    boolean not null default false,
  -- Google's own updated stamp, so a re-import can skip rows that have not
  -- moved rather than rewriting every one of them every time.
  add column if not exists google_updated_at timestamptz,
  add column if not exists all_day           boolean not null default false;

-- An event id is unique within a calendar, not globally — two team members
-- invited to the same meeting see the same id on their own calendars. Keyed
-- by both so that stays representable rather than colliding.
create unique index if not exists calendar_events_google_unique
  on calendar_events (calendar_id, google_event_id)
  where google_event_id is not null;

-- `type` was phone | zoom_meeting | zoom_demo | in_person. Anything imported
-- from Google is none of those, and the UI looks the type up in a table and
-- reads .color off the result — an unrecognised value there is a crash, not a
-- blank. 'external' is a real member of the set instead.
alter table calendar_events drop constraint if exists calendar_events_type_check;
alter table calendar_events
  add constraint calendar_events_type_check
  check (type is null or type in ('phone','zoom_meeting','zoom_demo','in_person','external'));

create index if not exists calendar_events_date_idx on calendar_events (date);


-- =============================================================================
-- AFTER RUNNING THIS
--   Redeploy the google-calendar function, then press Sync on the Calendar
--   tab. Events from your Google Calendar appear alongside CRM meetings;
--   move one in Google, sync again, and the CRM follows.
-- =============================================================================

-- =============================================================================
-- Tasks: priority and category
-- ---------------------------------------------------------------------------
-- Run after 75_record_notes.sql. Safe to re-run.
--
-- The Tasks page can now group and filter by priority and by a free-text
-- category (Follow-up, Paperwork, Call…). Existing tasks become Normal
-- priority with no category. RLS is unchanged — these are just two more
-- columns on rows people can already see and edit.
-- =============================================================================
alter table tasks
  add column if not exists priority text not null default 'normal'
    check (priority in ('high','normal','low')),
  add column if not exists category text;

create index if not exists tasks_priority_idx on tasks (priority);

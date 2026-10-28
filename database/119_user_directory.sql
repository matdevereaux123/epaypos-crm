-- =============================================================================
-- 119 - A staff directory everyone can read, without opening the users table.
--
-- users_select lets you read your own row, or every row if you hold
-- manageUsers. That is right for the users table, which carries extra_perms,
-- auth_id and everything else that decides what a person can do.
--
-- It is wrong for two things that need nothing of the sort:
--
--   * inviting a colleague to a meeting. An agent's portal holds exactly one
--     user row - their own - so the attendee list was empty for everybody
--     outside head office.
--
--   * a manager seeing their team's leads. The database serves them
--     (database/109), but the browser works out who reports to whom from the
--     user list, so a manager without manageUsers saw nothing and the grant
--     looked broken.
--
-- Both need the same four facts about a colleague: who they are, what to
-- call them, how to reach them, and who they report to. None of that is
-- sensitive among employees of one company, and none of it is a permission.
--
-- A view rather than a second policy, because the point is to expose some
-- COLUMNS to everyone, and RLS only decides rows.
--
-- Safe to run twice.
-- =============================================================================

create or replace view user_directory
with (security_invoker = false) as
  select id, name, email, job_title, manager_id, role
    from users;

comment on view user_directory is
  'Names, titles and reporting lines, readable by anyone signed in. Deliberately '
  'without extra_perms, auth_id, brands or anything else that decides access - '
  'for inviting a colleague to a meeting and for drawing the reporting line.';

revoke all on user_directory from public, anon;
grant select on user_directory to authenticated;

select count(*) as people_in_the_directory from user_directory;

-- =============================================================================
-- 127 - Someone who has left should not be in anybody's pick list.
--
-- 119 gave everyone a staff directory so an agent could invite a colleague to
-- a meeting. It selects every row in users, and users still holds people who
-- no longer work here - so the directory handed the whole company, including
-- the ones who have gone, to every portal login.
--
-- Deleting those rows is not the answer and never will be. created_by and
-- assigned_to point at them from leads, notes, meetings and agreements going
-- back years; delete the row and every one of those reads "Unknown", which
-- quietly rewrites your own history. The row stays and stops being offered.
--
--   users.active = false   ->  not in the directory, not in a pick list,
--                              not in the org chart. Still the name on the
--                              lead they created in March.
--
-- AND THE OTHER HALF. Marking somebody inactive must not hide the people who
-- are still here: if Aleshia or Matthew assigns a rep a lead, or invites them
-- to a meeting, that rep still sees who it came from. That works because
-- names are resolved from the record, not from the directory - the directory
-- only decides who you can PICK. So an active colleague who shares something
-- is visible, and a departed one is not offered.
--
-- Nobody is marked inactive here. That is done in Settings - Users, on the
-- person's own row, because knowing who has left is your call and not a
-- guess I should make in SQL.
--
-- Safe to run twice.
-- =============================================================================

alter table users add column if not exists active boolean not null default true;

-- coalesce, not "= true": a row written before this column existed, or by
-- something that does not know about it, is still here until somebody says
-- otherwise.
create or replace view user_directory
with (security_invoker = false) as
  select id, name, email, job_title, manager_id, role
    from users
   where coalesce(active, true);

comment on view user_directory is
  'Names, titles and reporting lines of people who are still here, readable by '
  'anyone signed in. Deliberately without extra_perms, auth_id, brands or '
  'anything else that decides access. Someone marked inactive keeps their rows '
  'and their name on old records, but drops out of this - see database/127.';

revoke all on user_directory from public, anon;
grant select on user_directory to authenticated;

select (select count(*) from users)                         as people_on_file,
       (select count(*) from user_directory)                as in_the_directory,
       (select count(*) from users where active = false)     as marked_as_gone;

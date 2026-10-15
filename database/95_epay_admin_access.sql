-- =============================================================================
-- 95 - Who may open the EPAY admin portal.
--
-- ADR-0016 serves the EPAY-staff admin portal from this CRM, at /admin. It is
-- reached with the Control Center login somebody already has, so the question
-- "may this person board a merchant" has to be answerable here rather than in
-- the portal itself.
--
-- One column on users, and the rule that only somebody with manageUsers may
-- change it.
--
-- WHY A COLUMN AND NOT A ROLE PERMISSION
-- Every other gate in this app is a key on roles.perms, and this deliberately
-- is not. A permission is granted to a role and inherited by everybody in it;
-- this is a decision about a person. The whole estate's merchant accounts sit
-- behind it, so it should be a tick somebody made on purpose about a named
-- individual and can see at a glance in the user list.
--
-- DEFAULT FALSE, AND NOT BACKFILLED
-- Nobody gains access by already existing — not owners, not admins, not the
-- person running this. An automatic grant is one nobody remembers to review,
-- and the first thing you will do after running this is tick yourself.
--
-- Safe to run twice.
-- =============================================================================

alter table users
  add column if not exists epay_admin boolean not null default false;

comment on column users.epay_admin is
  'May open the EPAY admin portal at /admin. Per-person, never inherited from '
  'a role. Checked live by the pos-admin edge function, so unticking takes '
  'effect on the next request rather than at the next sign-in.';

-- ---------------------------------------------------------------------------
-- Only manageUsers may set it.
--
-- The existing "users_write" policy already restricts every write on this
-- table to manageUsers, so a separate policy would add nothing. What it does
-- NOT stop is somebody with manageUsers granting it to themselves — which is
-- correct and worth being explicit about: manageUsers can already change any
-- role in the system, so anybody holding it can reach everything regardless.
-- The protection that matters is who holds manageUsers, not this column.
--
-- Listed here so a reader does not go looking for a policy that is missing.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- A quick way to see who has it. Read-only; no grant needed beyond the
-- existing users_select policy.
-- ---------------------------------------------------------------------------
create or replace view epay_admins as
  select id, name, email, role, epay_admin
  from users
  where epay_admin;

comment on view epay_admins is
  'Everybody who may open the EPAY admin portal. Expect this to be short.';

-- =============================================================================
-- AFTER RUNNING THIS
--
-- Nobody can open the portal yet, including you. Tick yourself:
--
--   update users set epay_admin = true where email = 'YOUR EMAIL HERE';
--
-- Then check it took, and that it is only you:
--
--   select * from epay_admins;
-- =============================================================================

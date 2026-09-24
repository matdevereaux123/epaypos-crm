-- =============================================================================
-- EPAY POS / Envision ATM Control Center — in-app training
-- ---------------------------------------------------------------------------
-- Run after 67_application_documents.sql. Safe to re-run.
--
-- Nobody has been taught this system. Handing someone a login is not the same
-- as handing them a working tool, and the gap shows up as questions that get
-- asked once per new person, forever.
--
-- A short walkthrough runs the first time someone logs in, built from what
-- their own role can actually see — an agent is never shown Cold Leads or
-- Applications, because a walkthrough that teaches things untrue of your
-- account is worse than none. It can be skipped, and re-run any time from
-- the profile menu.
--
-- WHY THE PROGRESS IS WRITTEN BY A FUNCTION
--
-- users_write is manageUsers-only, so a portal user cannot update their own
-- row — including to record that they finished training. Granting them write
-- access to `users` to tick one box would be absurd: that table holds roles
-- and partner links. This function writes those three columns for the caller
-- and nothing else, for nobody else.
-- =============================================================================

alter table users
  add column if not exists training_completed_at timestamptz,
  add column if not exists training_skipped_at   timestamptz,
  -- Bumped when the walkthrough changes materially, so an existing user can
  -- be shown it again without resetting who has seen what.
  add column if not exists training_version      integer not null default 0;


create or replace function set_my_training_state(
  p_completed boolean,
  p_version   integer default 1
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := current_app_user_id();
begin
  if v_me is null then
    raise exception 'Not signed in';
  end if;

  -- Only ever the caller's own row, and only these columns. The whole point
  -- of doing this here rather than granting the table.
  update users
     set training_completed_at = case when p_completed then now() else training_completed_at end,
         training_skipped_at   = case when p_completed then training_skipped_at else now() end,
         training_version      = greatest(coalesce(training_version, 0), coalesce(p_version, 1))
   where id = v_me;
end;
$$;

revoke execute on function set_my_training_state(boolean, integer) from public, anon;
grant  execute on function set_my_training_state(boolean, integer) to authenticated;


-- Everyone already using the CRM has learned it the hard way. Marking them as
-- having seen it stops the walkthrough ambushing the whole team at once on
-- the next login; they can still open it from the profile menu.
update users
   set training_skipped_at = now(), training_version = 1
 where training_completed_at is null and training_skipped_at is null;


-- =============================================================================
-- AFTER RUNNING THIS
--   Existing users are marked as having seen it, so nobody is interrupted.
--   To try it yourself, clear your own state and reload:
--     update users set training_completed_at = null, training_skipped_at = null
--      where email = 'matthew@epaypos.net';
-- =============================================================================

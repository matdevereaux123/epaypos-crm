-- =============================================================================
-- EPAY POS / Envision ATM Control Center — link Supabase Auth to users table
-- ---------------------------------------------------------------------------
-- The app's model is: a `public.users` row already exists (created via
-- "+ Add User" or automatically when a partner is added) BEFORE that person
-- ever logs in. This trigger fires whenever someone completes signup
-- through Supabase Auth (accepting an invite, or setting a password) and
-- links their new `auth.users` identity to the matching `public.users` row
-- by email — filling in the `auth_id` column the schema already has for
-- this purpose.
--
-- If someone signs up with an email that doesn't match any existing
-- `public.users` row, this deliberately does nothing — no row gets
-- auto-created. In this app, a login should never grant default access;
-- someone has to have been added as a user first. If that happens and you
-- want it logged instead of silently ignored, add a table to record it.
-- =============================================================================

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.users
    set auth_id = new.id
    where lower(email) = lower(new.email)
      and auth_id is null;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();

-- =============================================================================
-- Also handle the case where someone's email changes in Supabase Auth
-- after the fact (rare, but cheap to cover) — keep auth_id linked to
-- whichever public.users row currently has that email, in case it drifts.
-- =============================================================================
create or replace function public.handle_auth_user_email_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.email is distinct from old.email then
    update public.users set auth_id = new.id where lower(email) = lower(new.email);
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_email_updated on auth.users;
create trigger on_auth_user_email_updated
  after update on auth.users
  for each row execute function public.handle_auth_user_email_update();

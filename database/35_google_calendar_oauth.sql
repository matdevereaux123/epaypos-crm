-- =============================================================================
-- EPAY POS / Envision ATM Control Center — Google Calendar via OAuth
-- ---------------------------------------------------------------------------
-- Run after 34_terms_acceptance.sql.
--
-- Replaces the placeholder calendar list — where "connecting" meant typing a
-- name and an email into a box — with a real per-user Google sign-in.
--
-- THE PART THAT MATTERS: a Google refresh token is a long-lived key to
-- someone's calendar. It does not expire on its own, and anyone holding one
-- can read and write that calendar until it is explicitly revoked. So:
--
--   * Tokens live in google_calendar_tokens, encrypted with the same
--     encrypt_sensitive() every other secret in this system uses.
--   * That table has RLS on and NOT ONE POLICY. No policy means no row is
--     ever visible to `anon` or `authenticated`, whatever their role says.
--     Only the service role — which bypasses RLS and lives exclusively in
--     edge-function environment variables — can reach it.
--   * The three accessor functions below are granted to service_role ONLY.
--     google_calendar_get_tokens() returns plaintext, so an accidental grant
--     to `authenticated` would hand every logged-in user every team member's
--     calendar key. It is revoked from public, anon and authenticated
--     explicitly rather than relying on defaults.
--
-- The browser never sees a token. It reads connected_calendars, which holds
-- only who is connected and under which Google address.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1. CSRF state for the OAuth round trip.
--
-- Google sends the user back to our callback with whatever `state` we set.
-- Without checking it, anyone could forge a callback and bind their own
-- Google account to someone else's CRM login. Each state is random,
-- single-use and short-lived.
-- ---------------------------------------------------------------------------
create table if not exists google_oauth_states (
  state       text primary key,
  user_id     uuid not null references users(id) on delete cascade,
  redirect_to text,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '10 minutes'
);

create index if not exists google_oauth_states_expiry_idx on google_oauth_states (expires_at);

alter table google_oauth_states enable row level security;
-- Deliberately no policy. Service role only.
revoke all on google_oauth_states from anon, authenticated;


-- ---------------------------------------------------------------------------
-- 2. The tokens themselves.
-- ---------------------------------------------------------------------------
create table if not exists google_calendar_tokens (
  user_id            uuid primary key references users(id) on delete cascade,
  refresh_token      bytea not null,          -- encrypted; the long-lived one
  access_token       bytea,                   -- encrypted; ~1 hour
  access_expires_at  timestamptz,
  scope              text,
  google_email       text,
  updated_at         timestamptz not null default now()
);

alter table google_calendar_tokens enable row level security;
-- Deliberately no policy. See the header — this is the whole point.
revoke all on google_calendar_tokens from anon, authenticated;


-- ---------------------------------------------------------------------------
-- 3. connected_calendars becomes a real record of who linked what.
--
-- Existing rows keep working: they simply have a null user_id and read as
-- "not linked to a Google account" in the UI.
-- ---------------------------------------------------------------------------
alter table connected_calendars
  add column if not exists user_id            uuid references users(id) on delete cascade,
  add column if not exists google_email       text,
  add column if not exists google_calendar_id text not null default 'primary',
  add column if not exists sync_enabled       boolean not null default true,
  add column if not exists connected_at       timestamptz;

-- One Google link per person. Partial so the old placeholder rows, which all
-- have a null user_id, do not collide with each other.
create unique index if not exists connected_calendars_user_idx
  on connected_calendars (user_id) where user_id is not null;


-- ---------------------------------------------------------------------------
-- 4. calendar_events remembers what it pushed.
--
-- google_event_id is how an edit here becomes an edit there rather than a
-- second copy on the calendar. google_sync_error keeps a failed push visible
-- in the UI instead of silently doing nothing.
-- ---------------------------------------------------------------------------
alter table calendar_events
  add column if not exists google_event_id   text,
  add column if not exists google_synced_at  timestamptz,
  add column if not exists google_sync_error text;

create index if not exists calendar_events_google_idx
  on calendar_events (google_event_id) where google_event_id is not null;


-- ---------------------------------------------------------------------------
-- 5. Accessors. Service role only.
-- ---------------------------------------------------------------------------
-- Called once, from the OAuth callback, when a refresh token actually exists.
-- It insists on one: a row here without a refresh token is a link that dies
-- within the hour and cannot renew itself, which is worse than no row at all.
create or replace function google_calendar_store_tokens(
  p_user_id       uuid,
  p_refresh_token text,
  p_access_token  text,
  p_expires_at    timestamptz,
  p_scope         text,
  p_google_email  text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text;
begin
  if nullif(trim(coalesce(p_refresh_token, '')), '') is null then
    raise exception 'A refresh token is required to link a calendar';
  end if;

  insert into google_calendar_tokens (
    user_id, refresh_token, access_token, access_expires_at, scope, google_email, updated_at
  ) values (
    p_user_id,
    encrypt_sensitive(p_refresh_token),
    case when nullif(trim(coalesce(p_access_token, '')), '') is null
         then null else encrypt_sensitive(p_access_token) end,
    p_expires_at, p_scope, p_google_email, now()
  )
  on conflict (user_id) do update set
    refresh_token     = excluded.refresh_token,
    access_token      = excluded.access_token,
    access_expires_at = excluded.access_expires_at,
    scope             = coalesce(excluded.scope, google_calendar_tokens.scope),
    google_email      = coalesce(excluded.google_email, google_calendar_tokens.google_email),
    updated_at        = now();

  select coalesce(name, email, p_google_email) into v_name from users where id = p_user_id;

  insert into connected_calendars (user_id, name, email, google_email, connected, connected_at)
  values (p_user_id, coalesce(v_name, p_google_email), p_google_email, p_google_email, true, now())
  on conflict (user_id) where user_id is not null do update set
    google_email = excluded.google_email,
    email        = excluded.email,
    connected    = true,
    connected_at = now();
end;
$$;


-- The hourly path, and the reason this is a SEPARATE function rather than
-- store_tokens with a null refresh token.
--
-- Google returns no refresh token when it hands back a renewed access token —
-- you keep using the one you already have. Feeding that null through the
-- insert above cannot work: refresh_token is NOT NULL, and Postgres checks
-- that while building the row, BEFORE ON CONFLICT can divert to the update.
-- The row never reaches the coalesce that was meant to protect it, and every
-- renewal after the first hour throws instead. An UPDATE simply never touches
-- the column.
create or replace function google_calendar_update_access_token(
  p_user_id      uuid,
  p_access_token text,
  p_expires_at   timestamptz,
  p_scope        text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update google_calendar_tokens set
    access_token      = case when nullif(trim(coalesce(p_access_token, '')), '') is null
                             then null else encrypt_sensitive(p_access_token) end,
    access_expires_at = p_expires_at,
    scope             = coalesce(p_scope, scope),
    updated_at        = now()
  where user_id = p_user_id;
end;
$$;


-- Returns PLAINTEXT tokens. service_role only — see the file header.
create or replace function google_calendar_get_tokens(p_user_id uuid)
returns table (
  refresh_token     text,
  access_token      text,
  access_expires_at timestamptz,
  google_email      text
)
language sql
security definer
set search_path = public
as $$
  select
    decrypt_sensitive(t.refresh_token),
    case when t.access_token is null then null else decrypt_sensitive(t.access_token) end,
    t.access_expires_at,
    t.google_email
  from google_calendar_tokens t
  where t.user_id = p_user_id;
$$;

create or replace function google_calendar_disconnect(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from google_calendar_tokens where user_id = p_user_id;
  -- The calendar row goes too, rather than lingering as "connected". Events
  -- keep their google_event_id: if the same account reconnects later the
  -- link is still good, and if it does not, a stale id on a row nobody syncs
  -- costs nothing.
  delete from connected_calendars where user_id = p_user_id;
end;
$$;

-- Postgres grants EXECUTE to PUBLIC by default, and Supabase grants broadly
-- to anon/authenticated on top of that. All three have to be revoked before
-- the grant to service_role means anything.
revoke execute on function google_calendar_store_tokens(uuid, text, text, timestamptz, text, text) from public, anon, authenticated;
revoke execute on function google_calendar_update_access_token(uuid, text, timestamptz, text)      from public, anon, authenticated;
revoke execute on function google_calendar_get_tokens(uuid)                                        from public, anon, authenticated;
revoke execute on function google_calendar_disconnect(uuid)                                        from public, anon, authenticated;

grant execute on function google_calendar_store_tokens(uuid, text, text, timestamptz, text, text) to service_role;
grant execute on function google_calendar_update_access_token(uuid, text, timestamptz, text)      to service_role;
grant execute on function google_calendar_get_tokens(uuid)                                        to service_role;
grant execute on function google_calendar_disconnect(uuid)                                        to service_role;


-- ---------------------------------------------------------------------------
-- 6. Who may unlink whom.
--
-- The old policy let anyone with fullDashboard do anything to any row,
-- including flipping someone else's calendar off. Everyone still SEES the
-- list — that is the point of a shared team calendar — but only the owner
-- (or someone with manageSettings) may change or remove a linked row.
-- ---------------------------------------------------------------------------
drop policy if exists "connected_calendars_all" on connected_calendars;

create policy "connected_calendars_select" on connected_calendars
  for select to authenticated
  using (current_app_has_perm('fullDashboard'));

create policy "connected_calendars_insert" on connected_calendars
  for insert to authenticated
  with check (current_app_has_perm('fullDashboard'));

create policy "connected_calendars_update" on connected_calendars
  for update to authenticated
  using (
    coalesce(current_app_has_perm('manageSettings'), false)
    or user_id is null
    or user_id = current_app_user_id()
  );

create policy "connected_calendars_delete" on connected_calendars
  for delete to authenticated
  using (
    coalesce(current_app_has_perm('manageSettings'), false)
    or user_id is null
    or user_id = current_app_user_id()
  );


-- =============================================================================
-- AFTER RUNNING THIS
--   1. Google Cloud Console → new project → enable the Google Calendar API.
--   2. OAuth consent screen → Internal (if epaypos.net is Workspace) or
--      External. Add scopes:
--        https://www.googleapis.com/auth/calendar.events
--        openid, email
--   3. Credentials → OAuth client ID → Web application. Authorised redirect
--      URI, exactly:
--        https://gfnodfqkidtqjoofvwzr.supabase.co/functions/v1/google-calendar-callback
--   4. Deploy both functions and set on EACH of them:
--        GOOGLE_CLIENT_ID       from step 3
--        GOOGLE_CLIENT_SECRET   from step 3 — never put this in `integrations`,
--                               that table is readable by anyone with
--                               manageSettings
--        APP_URL                https://epaycrm.epaypos.net
--      google-calendar-callback must be deployed with JWT verification OFF;
--      Google calls it directly and has no Supabase token.
--   5. Settings → Integrations → Google Calendar → Connect my calendar.
--
--   Then confirm the browser genuinely cannot read a token:
--     select * from google_calendar_tokens;   -- as an ordinary logged-in user
--   should return zero rows, not an error and not data.
-- =============================================================================

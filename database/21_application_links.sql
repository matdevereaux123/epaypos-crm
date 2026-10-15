-- =============================================================================
-- EPAY POS / Envision ATM Control Center — managed application links
-- ---------------------------------------------------------------------------
-- Run after 20_revoke_anon_onboarding.sql.
--
-- The application-link dropdown on a lead was a hardcoded array in
-- app/index.html, so adding a link meant a code change and a deploy. This
-- moves the list into a table anyone with manageSettings can maintain from
-- Settings.
--
-- The two links already in that array are seeded here with their existing
-- keys, so leads that already store application_link_choice = 'sign_up' or
-- 'free_processing' keep resolving to the same URL.
--
-- 'custom' stays a special case in the app rather than a row here — it means
-- "type a one-off URL on this lead" and is stored per-lead in
-- leads.application_link_custom.
-- =============================================================================

create table if not exists application_links (
  id          uuid primary key default gen_random_uuid(),
  key         text unique not null,
  label       text not null,
  url         text not null,
  brand       text not null default 'both' check (brand in ('epay', 'atm', 'both')),
  sort_order  integer not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  -- 'custom' is handled in the app and must never be a row, or the dropdown
  -- ends up with two entries meaning different things.
  constraint application_links_key_not_custom check (key <> 'custom')
);

create index if not exists application_links_sort_idx on application_links (sort_order, label);

alter table application_links enable row level security;

-- Every signed-in user needs to read these to render the dropdown; only
-- manageSettings can change what the options are.
create policy "application_links_select" on application_links
  for select to authenticated
  using (true);

create policy "application_links_write" on application_links
  for all to authenticated
  using (current_app_has_perm('manageSettings'))
  with check (current_app_has_perm('manageSettings'));

-- Seed the two that were hardcoded, keeping their existing keys so leads
-- already pointing at them keep working.
insert into application_links (key, label, url, brand, sort_order) values
  ('free_processing', 'Free Processing Application', 'https://www.epaypos.net/copy-of-free-processing', 'epay', 10),
  ('sign_up',         'Sign Up',                     'https://www.epaypos.net/sign-up',                'epay', 20)
on conflict (key) do nothing;

-- =============================================================================
-- AFTER RUNNING THIS
--   Settings -> Application links lets anyone with manageSettings add, edit,
--   reorder and deactivate options. Deactivating hides a link from the
--   dropdown without breaking leads that already reference it.
-- =============================================================================

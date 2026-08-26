-- =============================================================================
-- EPAY POS / Envision ATM Control Center — ATM loaders
-- ---------------------------------------------------------------------------
-- Run after 39_residual_payouts.sql.
--
-- People and companies who load cash into ATMs. An internal address book:
-- who they are, where they are, how to reach them. Kept so someone can ask
-- "who loads in Ohio?" and get an answer.
--
-- WHY THIS IS NOT A `partners` ROW
--
-- The obvious move is partner_type = 'loader' and reuse everything. That
-- would be wrong here. A partners row carries an onboarding flow, an invite
-- that creates a portal login, a signed admit packet, residual splits, a
-- downline and encrypted banking. A loader has none of those and is not
-- meant to. Reusing the table means every one of those code paths has to
-- learn about a partner type that must never reach them — and the failure
-- mode is somebody accidentally getting a login to a CRM they have no
-- business seeing.
--
-- Separate table, internal-only policy, no portal path at all. It cannot go
-- wrong by omission.
-- =============================================================================

create table if not exists atm_loaders (
  id            uuid primary key default gen_random_uuid(),

  business_name text not null,
  contact_name  text,
  phone         text,
  email         text,

  address       text,
  city          text,
  -- Two-letter code, stored uppercase. The whole point of this table is
  -- looking people up by state, and 'oh' / 'Ohio' / 'OH' in one column makes
  -- that filter quietly incomplete.
  state         text,
  zip           text,

  notes         text,
  active        boolean not null default true,

  created_by    uuid references users(id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index if not exists atm_loaders_state_idx  on atm_loaders (state);
create index if not exists atm_loaders_active_idx on atm_loaders (active);
create index if not exists atm_loaders_name_idx   on atm_loaders (lower(business_name));

-- Normalised on the way in rather than trusted from the browser. A row
-- inserted by anything other than this app's form still lands searchable.
create or replace function atm_loaders_normalise()
returns trigger
language plpgsql
as $$
begin
  new.state := nullif(upper(trim(coalesce(new.state, ''))), '');
  new.email := nullif(lower(trim(coalesce(new.email, ''))), '');
  new.business_name := trim(new.business_name);
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists atm_loaders_normalise_trg on atm_loaders;
create trigger atm_loaders_normalise_trg
  before insert or update on atm_loaders
  for each row execute function atm_loaders_normalise();

alter table atm_loaders enable row level security;

drop policy if exists "atm_loaders_all" on atm_loaders;

-- Internal staff only. There is deliberately no portal branch: a loader has
-- no login, and nothing in the partner portal should ever read this table.
create policy "atm_loaders_all" on atm_loaders
  for all to authenticated
  using (coalesce(current_app_has_perm('fullDashboard'), false))
  with check (coalesce(current_app_has_perm('fullDashboard'), false));


-- =============================================================================
-- AFTER RUNNING THIS
--   Switch to Envision ATM. The Agents tab reads Loaders there; on EPAY POS
--   it is unchanged. Add one, then filter by state to confirm it is found.
-- =============================================================================

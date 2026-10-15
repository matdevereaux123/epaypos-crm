-- =============================================================================
-- 96 - The POS side: merchants, their locations, and the hardware on them.
--
-- The EPAY Back End tab is being built into this CRM as real pages rather than
-- a frame around another application, so the records those pages read have to
-- live here. This is them.
--
-- WHAT THESE ARE NOT
-- Not leads, and not accounts in the CRM sense. A lead is a deal being worked;
-- this is a business that is already running on EPAY POS — what edition they
-- are on, what rate, which tills are in the shop. A lead becomes one of these
-- when it is boarded, and leads.pos_merchant_id is the join.
--
-- WHY NOT REUSE leads
-- A lead has a stage, an owner, a close date and a quote. A merchant has
-- locations, a dual-pricing rate and seven card terminals. Forcing both into
-- one table gives every lead forty empty columns and makes "which of these is
-- live" a question about a text field.
--
-- CARD DATA: nothing here holds a PAN or anything like one. mid is the
-- processor's merchant id — it identifies the business, not a cardholder.
--
-- Safe to run twice.
-- =============================================================================

create table if not exists pos_merchants (
  id             uuid primary key default gen_random_uuid(),
  dba            text not null,
  legal_name     text,
  -- onboarding | live | paused | closed. Plain text like leads.stage, so a new
  -- one needs no migration.
  status         text not null default 'onboarding',
  owner_name     text,
  owner_email    text,
  owner_phone    text,
  -- The business's own number. Printed on receipts; the owner's is not.
  phone          text,
  website        text,
  street         text,
  city           text,
  state          text,
  zip            text,
  -- The EPAY person who owns the relationship.
  rep            text,
  -- Processor merchant id, once boarded. Absent until it is issued, which is
  -- later than the account is set up.
  mid            text,
  tax_id         text,
  created_by     uuid references users(id) on delete set null,
  created_at     timestamptz not null default now()
);
create index if not exists pos_merchants_status_idx on pos_merchants (status);

create table if not exists pos_locations (
  id                       uuid primary key default gen_random_uuid(),
  merchant_id              uuid not null references pos_merchants(id) on delete cascade,
  name                     text not null,
  street                   text,
  city                     text,
  state                    text,
  zip                      text,
  -- restaurant | quick-retail | retail-inventory | salon | epay-charge
  edition                  text not null default 'restaurant',
  add_ons                  text[] not null default '{}',
  -- Dual pricing in parts per million: 39900 ppm is 3.99%. Integer, never a
  -- float — this is money and a rounding error here is a chargeback.
  dual_pricing_ppm         integer not null default 0,
  -- And the flat part, for interchange-plus. Cents, per transaction.
  dual_pricing_fixed_cents integer not null default 0,
  tax_ppm                  integer not null default 0,
  created_at               timestamptz not null default now()
);
create index if not exists pos_locations_merchant_idx on pos_locations (merchant_id);

create table if not exists pos_devices (
  id           uuid primary key default gen_random_uuid(),
  location_id  uuid not null references pos_locations(id) on delete cascade,
  -- station | mini | handheld | tablet | kds | card-terminal
  kind         text not null default 'station',
  label        text not null,
  -- Set by the device when it checks in; never typed.
  last_seen_at timestamptz,
  -- Six digits typed into a device to pair it. Cleared once it checks in.
  pairing_code text,
  created_at   timestamptz not null default now()
);
create index if not exists pos_devices_location_idx on pos_devices (location_id);

-- ---------------------------------------------------------------------------
-- The relationship log. Append-only by intent: a note explaining why a rate
-- changed is worth more than the rate, and it has to survive whoever wrote it
-- leaving. Nothing here is ever edited, only added to.
-- ---------------------------------------------------------------------------
create table if not exists pos_merchant_notes (
  id          uuid primary key default gen_random_uuid(),
  merchant_id uuid not null references pos_merchants(id) on delete cascade,
  -- call | email | visit | support | system
  kind        text not null default 'call',
  body        text not null,
  by_name     text not null,
  created_at  timestamptz not null default now()
);
create index if not exists pos_merchant_notes_merchant_idx
  on pos_merchant_notes (merchant_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Link a lead to the account it became.
--
-- Not by MID: the processor issues that later than the account is set up, so
-- a boarded merchant would have no link for days.
-- ---------------------------------------------------------------------------
alter table leads
  add column if not exists pos_merchant_id uuid references pos_merchants(id) on delete set null;

-- ---------------------------------------------------------------------------
-- Who may see any of this.
--
-- The same tick that opens the portal: users.epay_admin. Not manageUsers and
-- not fullDashboard — this is every merchant on the platform, their rates and
-- their hardware, and it should be behind the switch somebody turned on
-- deliberately for a named person rather than one inherited from a role.
-- ---------------------------------------------------------------------------
create or replace function current_user_is_epay_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select epay_admin from users where auth_id = auth.uid()), false);
$$;

grant execute on function current_user_is_epay_admin() to authenticated;

do $$
declare t text;
begin
  foreach t in array array['pos_merchants','pos_locations','pos_devices','pos_merchant_notes']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists "%s_epay_admin" on %I', t, t);
    execute format(
      'create policy "%s_epay_admin" on %I for all to authenticated '
      'using (current_user_is_epay_admin()) with check (current_user_is_epay_admin())',
      t, t);
  end loop;
end $$;

-- =============================================================================
-- AFTER RUNNING THIS
--
-- Four empty tables and nobody but an EPAY admin can see them. The Back End
-- pages read these; boarding an account from the portal writes to them.
--
--   select count(*) from pos_merchants;   -- 0, expected
-- =============================================================================

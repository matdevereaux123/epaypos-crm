-- =============================================================================
-- 106 - The pricing program, back-office config, and a trail of who changed it
--
-- THREE THINGS, AND THE FIRST IS THE ONE THAT MATTERS
--
-- 1. WHICH PRICING PROGRAM A LOCATION IS ON
--
-- There are two, and they are not two settings of one thing:
--
--   interchange_plus - EPAY's cost plus a margin, billed to the merchant.
--                      NOTHING is passed to the cardholder. The card price
--                      and the cash price are the same price.
--
--   consumer_choice  - the card price carries an adjustable percentage that
--                      the customer pays, shown to them before they choose
--                      how to pay.
--
-- Until now there was only `dual_pricing_ppm`, and zero had to mean both
-- "this merchant is on interchange plus, correctly passing nothing on" and
-- "nobody has set this up yet". Those are opposite situations: the first is
-- finished, the second is every card sale that day run at a loss. A column
-- that cannot tell them apart cannot be checked before a shop opens, which
-- is exactly what the setup gates have to do.
--
-- So the program is its own column. The percentage keeps meaning what it
-- meant, and now only applies to one of the two programs.
--
-- Existing rows: anything with a rate above zero was passing something on,
-- so it is consumer choice. Anything at zero is left unset rather than
-- guessed into a program - an unanswered question somebody can see beats an
-- invented answer nobody can.
--
-- 2. WHAT THE BACK OFFICE CAN CHANGE WITHOUT A RELEASE
--
-- `pos_addons` and `pos_referral_offer` already work this way. The same move
-- for the rest of it: receipt wording, tip presets, void and discount
-- reasons, the setup questionnaire, and whether a connector is live yet.
-- A merchant asking on a Friday for a different receipt footer should not
-- be waiting on a deploy.
--
-- One table, keyed by scope, rather than six. These are read together, they
-- are written by the same screen, and six tables is six sets of policies to
-- keep in step.
--
-- 3. WHO CHANGED THE RATE
--
-- Rate disputes are the expensive kind and a change left no trace at all.
-- Every change to anything priced or programmatic writes a row here: what
-- it was, what it became, who did it, when.
--
-- Safe to run twice.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The pricing program
-- ---------------------------------------------------------------------------
alter table pos_locations
  add column if not exists pricing_mode text;

comment on column pos_locations.pricing_mode is
  'interchange_plus (nothing passed to the cardholder) or consumer_choice '
  '(an adjustable percentage is). Null means nobody has chosen yet, which '
  'is not the same as a zero rate and must not be read as one.';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'pos_locations_pricing_mode_ck'
  ) then
    alter table pos_locations add constraint pos_locations_pricing_mode_ck
      check (pricing_mode is null or pricing_mode in ('interchange_plus','consumer_choice'));
  end if;
end $$;

-- A rate above zero was passing something on. That is consumer choice,
-- whatever it was called when it was entered.
update pos_locations
   set pricing_mode = 'consumer_choice'
 where pricing_mode is null
   and (coalesce(dual_pricing_ppm,0) > 0 or coalesce(dual_pricing_fixed_cents,0) > 0);

-- ---------------------------------------------------------------------------
-- 2. Config the back office owns
-- ---------------------------------------------------------------------------
create table if not exists pos_config (
  scope       text not null,
  key         text not null,
  value       jsonb not null,
  label       text,
  sort        integer not null default 0,
  active      boolean not null default true,
  updated_at  timestamptz not null default now(),
  updated_by  text,
  primary key (scope, key)
);

comment on table pos_config is
  'Anything the back office can change without a release: receipt wording, '
  'tip presets, void and discount reasons, the setup questionnaire, and '
  'whether a connector is live. Scope says which; key is stable and is what '
  'the software looks up.';

insert into pos_config (scope, key, value, label, sort) values
  ('receipt','header_lines', '[]'::jsonb, 'Lines above the business name', 10),
  ('receipt','footer_lines', '["Thank you"]'::jsonb, 'Lines under the total', 20),
  ('receipt','show_cash_and_card', 'true'::jsonb, 'Print both prices', 30),

  ('tips','presets', '[18,20,25]'::jsonb, 'Tip buttons, as percentages', 10),
  ('tips','on_cash', 'false'::jsonb, 'Ask for a tip on cash too', 20),

  ('reasons','void', '["Wrong item","Customer changed their mind","Rung twice","Kitchen error"]'::jsonb,
     'Why a line or ticket was voided', 10),
  ('reasons','discount', '["Manager comp","Staff meal","Loyalty reward","Service recovery"]'::jsonb,
     'Why a discount was given', 20),
  ('reasons','refund', '["Faulty item","Not as described","Duplicate charge"]'::jsonb,
     'Why money went back', 30),

  -- Which connectors are sellable today. The POS ships a list; this is what
  -- overrides "coming soon" without a release.
  ('connectors','live', '["kiosk","giftcards","doordash","grubhub","ubereats","epay-online"]'::jsonb,
     'Connectors a merchant can switch on', 10)
on conflict (scope, key) do nothing;

create index if not exists pos_config_scope_idx on pos_config (scope, sort);

-- ---------------------------------------------------------------------------
-- 3. Who changed it
-- ---------------------------------------------------------------------------
create table if not exists pos_change_log (
  id           uuid primary key default gen_random_uuid(),
  -- What was changed: 'pos_locations', 'pos_addons', 'pos_config', ...
  entity       text not null,
  entity_id    text,
  -- The merchant it belongs to, where it belongs to one. Null for catalogue
  -- and config changes, which belong to everybody.
  merchant_id  uuid references pos_merchants(id) on delete cascade,
  field        text not null,
  old_value    text,
  new_value    text,
  changed_by   text not null,
  changed_at   timestamptz not null default now(),
  -- Free text, for the changes that need one.
  note         text
);

comment on table pos_change_log is
  'What a priced or programmatic setting was, what it became, who did it '
  'and when. Rate disputes are the expensive kind and a change used to '
  'leave no trace at all.';

create index if not exists pos_change_log_merchant_idx
  on pos_change_log (merchant_id, changed_at desc);
create index if not exists pos_change_log_entity_idx
  on pos_change_log (entity, entity_id, changed_at desc);

-- ---------------------------------------------------------------------------
-- Who can read and write these
-- ---------------------------------------------------------------------------
alter table pos_config enable row level security;
drop policy if exists "pos_config_read" on pos_config;
-- Read by anybody signed in: a till and a merchant portal both need these.
create policy "pos_config_read" on pos_config for select to authenticated using (true);
drop policy if exists "pos_config_write" on pos_config;
create policy "pos_config_write" on pos_config for all to authenticated
  using (current_user_is_epay_admin()) with check (current_user_is_epay_admin());

alter table pos_change_log enable row level security;
drop policy if exists "pos_change_log_read" on pos_change_log;
create policy "pos_change_log_read" on pos_change_log
  for select to authenticated using (true);
-- Written by anybody whose change it records. Never updated and never
-- deleted: a log somebody can edit is not one.
drop policy if exists "pos_change_log_insert" on pos_change_log;
create policy "pos_change_log_insert" on pos_change_log
  for insert to authenticated with check (true);

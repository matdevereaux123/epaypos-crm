-- =============================================================================
-- 101 - What EPAY charges: plans, add-ons, and why an account is paused.
--
-- Prices as records, not as code. They change — a promotion, a plan retired,
-- a price rise — and a price that needs a release to change is a price that
-- goes stale in the one place everybody reads it. Every figure below came
-- from Matthew on 2026-10-15.
--
-- CENTS, ALWAYS. $69.99 is 6999. Never a float: this is money, and a rounding
-- error here is an invoice somebody disputes.
--
-- TWO THINGS LEFT NULL ON PURPOSE
-- EPAY Kiosk and EPAY Connect arrived without a figure. A null price shows as
-- "price not set" and cannot be sold, which is the honest state — guessing a
-- number and having it appear on a merchant's agreement is the worse failure.
--
-- Safe to run twice.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- What a plan costs, per edition and service mode.
-- ---------------------------------------------------------------------------
create table if not exists pos_plans (
  key          text primary key,
  label        text not null,
  -- Cents per month. Null means not for sale yet.
  price_cents  integer,
  -- Which edition this plan belongs to, for defaulting a new location.
  edition      text,
  note         text,
  sort         integer not null default 0
);

insert into pos_plans (key, label, price_cents, edition, note, sort) values
  ('full_service',   'Full service restaurant', 6999, 'restaurant',       null, 10),
  ('express',        'Express restaurant',      7499, 'restaurant',       null, 20),
  ('retail',         'Retail',                  7499, 'retail-inventory', null, 30),
  ('express_retail', 'Express retail',          3999, 'quick-retail',     null, 40),
  ('smart_terminal', 'Smart terminal',           999, 'epay-charge',      null, 50),
  ('salon',          'Salon',                   8999, 'salon',
     'Nail salon software included at no extra charge.', 60)
on conflict (key) do update set
  label = excluded.label, price_cents = excluded.price_cents,
  edition = excluded.edition, note = excluded.note, sort = excluded.sort;

-- ---------------------------------------------------------------------------
-- What an add-on costs, and what it unlocks.
--
-- `capability` is the id the software checks. A merchant reaching a feature
-- they are not on sees the paywall for the add-on that carries it, which is
-- why the two have to be joined here rather than guessed at either end.
-- ---------------------------------------------------------------------------
create table if not exists pos_addons (
  key          text primary key,
  label        text not null,
  -- Cents per month. 0 is genuinely free; null is a price nobody has set.
  price_cents  integer,
  blurb        text,
  -- The capability id the register and portal gate on.
  capability   text,
  -- Another add-on that has to be on first, where one does.
  requires     text references pos_addons(key),
  active       boolean not null default true,
  sort         integer not null default 0
);

insert into pos_addons (key, label, price_cents, blurb, capability, requires, sort) values
  ('quickbooks',    'QuickBooks',               0,
     'Sales and payouts into QuickBooks. Included at no charge.', 'quickbooks', null, 10),
  ('gift_cards',    'EPAY gift cards',       1500,
     'Sell and redeem gift cards. The cards themselves are at cost.', 'gift-cards', null, 20),
  ('loyalty',       'EPAY loyalty',          2999,
     'Points, rewards and the customer record behind them.', 'loyalty', null, 30),
  ('online_order',  'EPAY online ordering',  3999,
     'Your own ordering page, straight onto the kitchen screen.', 'online-ordering', null, 40),
  ('doordash',      'DoorDash link',          500,
     'DoorDash orders on the same ticket rail as everything else.', 'doordash', null, 50),
  ('grubhub',       'Grubhub link',           500,
     'Grubhub orders on the same ticket rail.', 'grubhub', null, 60),
  ('ubereats',      'Uber Eats link',         500,
     'Uber Eats orders on the same ticket rail.', 'ubereats', null, 70),
  ('profit',        'EPAY Profit',          14999,
     'Cost, margin and what each dish actually makes.', 'profit', null, 80),
  ('recipe_depth',  'Recipe-level depletion',    0,
     'Ingredient-level stock from a sold dish. Included with EPAY Profit.',
     'recipe-depletion', 'profit', 90),
  ('pouring',       'Pouring system',         2500,
     'Pour-by-pour control and reconciliation behind the bar.', 'pouring', null, 100),
  ('charge',        'EPAY Charge',            3000,
     'Take a payment with no register at all.', 'epay-charge', null, 110),
  ('reservations',  'Reservations and wait list', 1000,
     'Bookings and the queue at the door.', 'reservations', null, 120),
  ('age_check',     'Age verification and ID scanning', 500,
     'Scan an ID at the till, and keep the record that you did.', 'age-check', null, 130),
  -- No figure given yet. Null rather than a guess: see the header.
  ('kiosk',         'EPAY Kiosk',            null,
     'Customers order and pay themselves.', 'kiosk', null, 140),
  ('connect',       'EPAY Connect',          null,
     'What reaches this business from outside it.', 'connect', null, 150)
on conflict (key) do update set
  label = excluded.label, price_cents = excluded.price_cents,
  blurb = excluded.blurb, capability = excluded.capability,
  requires = excluded.requires, sort = excluded.sort;

-- ---------------------------------------------------------------------------
-- What a location is actually on. `pos_locations.add_ons` already exists and
-- nothing set it; this is the plan beside it.
-- ---------------------------------------------------------------------------
alter table pos_locations
  add column if not exists plan_key text references pos_plans(key);

-- ---------------------------------------------------------------------------
-- Why an account is paused.
--
-- The status already said that it was. A merchant who is paused rings and
-- asks why, and "it says paused" is not an answer anybody can act on.
-- ---------------------------------------------------------------------------
alter table pos_merchants
  add column if not exists pause_reason text,
  add column if not exists paused_at    timestamptz,
  add column if not exists paused_by    text;

-- ---------------------------------------------------------------------------
-- Pairing a device.
--
-- `pos_devices.pairing_code` existed and nothing generated one, so a station
-- added here had no way for the actual till in the shop to claim it. A code
-- is short enough to read down a phone and dies on its own, because one that
-- works forever is a till anybody can add to somebody's shop.
-- ---------------------------------------------------------------------------
alter table pos_devices
  add column if not exists pairing_expires_at timestamptz,
  add column if not exists paired_at          timestamptz;

-- Read by anybody signed in — the merchant portal shows prices on a paywall.
-- Changed only by an EPAY admin.
do $$
declare t text;
begin
  foreach t in array array['pos_plans','pos_addons']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists "%s_read" on %I', t, t);
    execute format('create policy "%s_read" on %I for select to authenticated using (true)', t, t);
    execute format('drop policy if exists "%s_write" on %I', t, t);
    execute format(
      'create policy "%s_write" on %I for all to authenticated '
      'using (current_user_is_epay_admin()) with check (current_user_is_epay_admin())', t, t);
  end loop;
end $$;

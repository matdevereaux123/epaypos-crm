-- =============================================================================
-- 102 - What a merchant agreed to, and at what price.
--
-- A paywall that only switches a feature on is a feature nobody can bill for.
-- This is the other half: who accepted, when, which terms they accepted, and
-- crucially WHAT IT COST AT THE TIME.
--
-- WHY THE PRICE IS COPIED IN
-- `pos_addons.price_cents` is today's price. This is the price somebody saw
-- on the screen and ticked a box next to. When the list price changes next
-- quarter, an agreement that pointed at the catalogue would quietly rewrite
-- what a merchant was promised — and the first they would hear of it is an
-- invoice. So the number is copied, not referenced.
--
-- Same reasoning for the terms: the version is recorded, because "they agreed
-- to the terms" means nothing if nobody can say which terms.
--
-- APPEND ONLY
-- Nothing here is edited or deleted. Cancelling an add-on is its own row with
-- a cancelled_at, not the removal of the agreement — an agreement that can
-- vanish is one nobody can rely on in a dispute.
--
-- Safe to run twice.
-- =============================================================================

create table if not exists pos_addon_agreements (
  id             uuid primary key default gen_random_uuid(),
  merchant_id    uuid not null references pos_merchants(id) on delete cascade,
  location_id    uuid references pos_locations(id) on delete set null,
  addon_key      text not null,
  -- As shown on the screen they ticked. Cents.
  price_cents    integer,
  -- Which terms. Bare 'v1' is enough while there is one; it stops being
  -- enough the moment there are two, which is exactly when nobody remembers.
  terms_version  text not null default 'v1',
  -- Who ticked it. A person in the merchant's business, not EPAY.
  accepted_by    text not null,
  accepted_email text,
  -- Where from: 'portal' (their back office) or 'register' (a till).
  accepted_in    text,
  accepted_at    timestamptz not null default now(),
  -- Set when it is turned off. The row stays.
  cancelled_at   timestamptz,
  cancelled_by   text
);
create index if not exists pos_addon_agreements_merchant_idx
  on pos_addon_agreements (merchant_id, accepted_at desc);

comment on table pos_addon_agreements is
  'Every time somebody at a merchant accepted a paid add-on, at the price and '
  'terms they were shown. Append-only: cancelling sets cancelled_at rather '
  'than removing the row.';

-- ---------------------------------------------------------------------------
-- The terms somebody is accepting.
--
-- A record, so the wording can change without a release, and so an older
-- agreement can still be shown the terms it was made under.
-- ---------------------------------------------------------------------------
create table if not exists pos_terms (
  version    text primary key,
  body       text not null,
  published  boolean not null default false,
  created_at timestamptz not null default now()
);

insert into pos_terms (version, published, body) values ('v1', true,
'EPAY POS add-on terms

1. What this is. By accepting, the business named on this account agrees to
   add the feature shown above to its EPAY POS subscription at the monthly
   price shown.

2. Billing. The price is per month, per location, and is added to the next
   invoice. It is not prorated for the month in which it is accepted.

3. Cancelling. The feature can be turned off at any time from the back
   office. Billing stops at the end of the month in which it is cancelled.
   Amounts already invoiced are not refunded.

4. Card processing is separate. Nothing here changes processing rates,
   interchange or anything else charged by the processor. This covers
   software only.

5. Who may accept. Only somebody authorised to commit the business. By
   accepting you confirm you are.

6. Changes. If the price of a feature changes, the business keeps the price
   it accepted until it cancels or changes plan.')
on conflict (version) do nothing;

-- Read by anybody signed in: the merchant portal and a till both show these.
-- Written by a merchant accepting, and by EPAY.
alter table pos_addon_agreements enable row level security;
drop policy if exists "pos_addon_agreements_read" on pos_addon_agreements;
create policy "pos_addon_agreements_read" on pos_addon_agreements
  for select to authenticated using (true);
drop policy if exists "pos_addon_agreements_insert" on pos_addon_agreements;
create policy "pos_addon_agreements_insert" on pos_addon_agreements
  for insert to authenticated with check (true);
-- Only EPAY may change one after the fact, and even then not delete it.
drop policy if exists "pos_addon_agreements_update" on pos_addon_agreements;
create policy "pos_addon_agreements_update" on pos_addon_agreements
  for update to authenticated
  using (current_user_is_epay_admin()) with check (current_user_is_epay_admin());

alter table pos_terms enable row level security;
drop policy if exists "pos_terms_read" on pos_terms;
create policy "pos_terms_read" on pos_terms for select to authenticated using (true);
drop policy if exists "pos_terms_write" on pos_terms;
create policy "pos_terms_write" on pos_terms for all to authenticated
  using (current_user_is_epay_admin()) with check (current_user_is_epay_admin());

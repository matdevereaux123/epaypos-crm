-- =============================================================================
-- 103 - EPAY Kiosk gets a price. EPAY Connect stops pretending to be an add-on.
--
-- Two different problems that looked the same, because both rows had a null
-- price and the portal treated null as "cannot be sold yet".
--
-- KIOSK was simply unpriced. It is $39.99 a month.
--
-- CONNECT was never a thing to sell. It is a list indicator - a marker on
-- what reaches a business from outside it - and it ended up in the add-on
-- catalogue because that is where the list lived. Leaving it there has two
-- costs: it sits in "add-ons without a price" as a permanent nag that nobody
-- can clear, and a merchant who reaches the feature is shown a paywall
-- reading "ask EPAY and we will sort it out" for something nobody intends
-- to charge for.
--
-- So: a `sellable` flag rather than deleting the row. Deleting it would take
-- the indicator with it. Not-for-sale is its own state, distinct from
-- not-yet-priced, and the two need to read differently everywhere.
--
-- Safe to run twice.
-- =============================================================================

alter table pos_addons
  add column if not exists sellable boolean not null default true;

comment on column pos_addons.sellable is
  'False for rows that exist as indicators rather than as things to sell. '
  'A non-sellable add-on never produces a paywall and is not counted as '
  'missing a price.';

-- $39.99 a month.
update pos_addons set price_cents = 3999 where key = 'kiosk';

-- Not sold. The null price is correct for this row and always will be.
update pos_addons set sellable = false where key = 'connect';

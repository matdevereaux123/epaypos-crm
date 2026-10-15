-- =============================================================================
-- 104 - Point the add-ons at capability ids the software actually gates on.
--
-- `pos_addons.capability` was written with sensible-looking names - `profit`,
-- `age-check`, `reservations`, `kiosk`, `quickbooks` - and the software's own
-- feature ids, in packages/editions, are none of those. Nothing matched.
--
-- That failure was silent and in the worst direction. A paywall asks "which
-- add-on carries this feature"; no match means nothing gates it, so every
-- one of these would have been let through free rather than refused. Nobody
-- would have reported it.
--
-- THE THREE DELIVERY LINKS LOSE THEIRS ON PURPOSE
-- DoorDash, Grubhub and Uber Eats are three separate $5 purchases, and the
-- software has one `delivery-aggregators` capability covering all three.
-- Asking by capability returns whichever row is found first, which would
-- offer DoorDash to a merchant who clicked Grubhub. They are sold by their
-- own key instead, from their row on the EPAY Connect page.
--
-- POURING and EPAY CHARGE have no capability either: neither is a feature
-- flag in the software. Both are sold from their Connect row.
--
-- Safe to run twice.
-- =============================================================================

update pos_addons set capability = 'quickbooks-export'   where key = 'quickbooks';
update pos_addons set capability = 'gift-cards'          where key = 'gift_cards';
update pos_addons set capability = 'loyalty'             where key = 'loyalty';
update pos_addons set capability = 'online-ordering'     where key = 'online_order';
update pos_addons set capability = 'cost-margin-reporting' where key = 'profit';
update pos_addons set capability = 'recipe-depletion'    where key = 'recipe_depth';
update pos_addons set capability = 'reservations-waitlist' where key = 'reservations';
update pos_addons set capability = 'age-verification'    where key = 'age_check';
update pos_addons set capability = 'self-checkout-kiosk' where key = 'kiosk';

-- Sold by key, from the EPAY Connect page. See the header.
update pos_addons set capability = null
  where key in ('doordash', 'grubhub', 'ubereats', 'pouring', 'charge', 'connect');

-- Which row on the EPAY Connect page sells this, where one does. The Connect
-- page is the switchboard a merchant actually turns these on from, so it is
-- also where the price and the terms belong.
alter table pos_addons
  add column if not exists connect_id text;

comment on column pos_addons.connect_id is
  'The EPAY Connect row this add-on is sold from, matching ConnectId in the '
  'POS. Null for add-ons reached from a page rather than from Connect.';

update pos_addons set connect_id = 'quickbooks'  where key = 'quickbooks';
update pos_addons set connect_id = 'giftcards'   where key = 'gift_cards';
update pos_addons set connect_id = 'epay-online' where key = 'online_order';
update pos_addons set connect_id = 'doordash'    where key = 'doordash';
update pos_addons set connect_id = 'grubhub'     where key = 'grubhub';
update pos_addons set connect_id = 'ubereats'    where key = 'ubereats';
update pos_addons set connect_id = 'epay-profit' where key = 'profit';
update pos_addons set connect_id = 'pouring'     where key = 'pouring';
update pos_addons set connect_id = 'epay-charge' where key = 'charge';
update pos_addons set connect_id = 'kiosk'       where key = 'kiosk';

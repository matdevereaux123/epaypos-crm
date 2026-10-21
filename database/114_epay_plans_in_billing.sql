-- =============================================================================
-- 114 - The EPAY plans, in the page that edits plans.
--
-- There are two plan catalogues in this system and only one of them was on
-- the Subscriptions page.
--
--   pos_plans (101)        what the back end bills from, seeded with the
--                          platform's six editions - full service, express,
--                          retail, express retail, smart terminal, salon.
--
--   POS_SYSTEM_PLANS       the five EPAY plans sales actually quote, which
--   (app/index.html)       live in the app as a constant and are what gets
--                          put on an account: Terminal, Lite, Retail, Table,
--                          Custom.
--
-- The second set is the one being sold, and it was not editable anywhere.
-- This puts it in the table the editor reads, at the prices that constant
-- carries, so a price change is a change in one place rather than a release.
--
-- EDITION IS LEFT NULL ON PURPOSE. edition is what tells provisioning which
-- software a location gets, and guessing that mapping from a plan's name is
-- how a merchant ends up with the wrong till. Set it in the editor once the
-- right pairing is settled - these rows are priced and sellable without it.
--
-- The six from 101 are left exactly as they are. If they are superseded
-- rather than parallel, retiring them is a separate decision and a separate
-- migration - deleting a plan a merchant is on is not a tidy-up.
--
-- Safe to run twice.
-- =============================================================================

insert into pos_plans (key, label, price_cents, edition, note, sort) values
  ('epay_terminal', 'EPAY Terminal', 1499, null, 'Sold as EPAY Terminal.',       110),
  ('epay_lite',     'EPAY Lite',     3999, null, 'Sold as EPAY Lite.',           120),
  ('epay_retail',   'EPAY Retail',   7499, null, 'Sold as EPAY Retail.',         130),
  ('epay_table',    'EPAY Table',    6999, null, 'Sold as EPAY Table.',          140),
  -- Custom is quoted per deal, so it has no price. Null is "nobody set one",
  -- which is exactly right here and keeps it out of any paywall.
  ('epay_custom',   'EPAY Custom',   null, null, 'Quoted per deal.',             150)
on conflict (key) do update set
  label = excluded.label,
  price_cents = excluded.price_cents,
  note = excluded.note,
  sort = excluded.sort;

-- What the page will now list, in order.
select key, label,
       case when price_cents is null then 'no price set'
            else '$' || to_char(price_cents / 100.0, 'FM999990.00') end as price,
       coalesce(edition, '(edition not set)') as edition
  from pos_plans
 order by sort, key;

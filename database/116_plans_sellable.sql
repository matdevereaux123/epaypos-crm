-- =============================================================================
-- 116 - Which plans are still sold.
--
-- Now that the CRM reads pos_plans instead of its own constant, every row in
-- that table appears in the plan dropdown on a lead and in the subscription
-- picker on an account. That is eleven plans where sales used to see five:
-- the EPAY five, plus the platform's own six from 101, which are the same
-- software under its internal names.
--
-- Add-ons already had this problem and 103 solved it with a sellable flag -
-- a row that exists as an indicator rather than as a thing to sell. Plans
-- get the same.
--
-- The six platform rows are marked not sold rather than deleted. A merchant
-- billing from full_service today keeps billing from it; what changes is
-- that nobody can put a new account on it by accident. Flipping one back is
-- a tick in the Subscriptions editor.
--
-- Safe to run twice.
-- =============================================================================

alter table pos_plans
  add column if not exists sellable boolean not null default true;

comment on column pos_plans.sellable is
  'False for a plan that is no longer offered. It stays in the table because '
  'accounts still bill from it; it is kept out of the pickers where new '
  'business is written.';

update pos_plans set sellable = false
 where key in ('full_service','express','retail','express_retail','smart_terminal','salon');

update pos_plans set sellable = true
 where key like 'epay\_%';

select key, label, sellable,
       case when price_cents is null then 'quoted per deal'
            else '$' || to_char(price_cents / 100.0, 'FM999990.00') end as price
  from pos_plans
 order by sellable desc, sort;

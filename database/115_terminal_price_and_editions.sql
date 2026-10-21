-- =============================================================================
-- 115 - EPAY Terminal is $9.99, and the EPAY plans get their editions.
--
-- 114 put the five sold plans into pos_plans at the prices the app's old
-- constant carried. One of those was wrong: EPAY Terminal is 9.99 a month,
-- not 14.99. The constant was the only record of it, which is the argument
-- for the table being the catalogue rather than the code.
--
-- The editions follow from the prices lining up with the platform's own six,
-- confirmed by the Terminal price matching Smart terminal:
--
--   EPAY Terminal  ->  epay-charge        (= Smart terminal,      $9.99)
--   EPAY Lite      ->  quick-retail       (= Express retail,     $39.99)
--   EPAY Retail    ->  retail-inventory   (= Retail,             $74.99)
--   EPAY Table     ->  restaurant         (= Full service,       $69.99)
--   EPAY Custom    ->  left unset; it is quoted per deal and the software it
--                      comes with is part of the quote.
--
-- edition is what provisioning reads to decide which till a location gets,
-- so these are set from evidence rather than from the names.
--
-- Safe to run twice.
-- =============================================================================

update pos_plans set price_cents = 999 where key = 'epay_terminal';

update pos_plans set edition = 'epay-charge'      where key = 'epay_terminal';
update pos_plans set edition = 'quick-retail'     where key = 'epay_lite';
update pos_plans set edition = 'retail-inventory' where key = 'epay_retail';
update pos_plans set edition = 'restaurant'       where key = 'epay_table';

select key, label,
       case when price_cents is null then 'quoted per deal'
            else '$' || to_char(price_cents / 100.0, 'FM999990.00') end as price,
       coalesce(edition, '(unset - quoted per deal)') as edition
  from pos_plans
 where key like 'epay\_%'
 order by sort;

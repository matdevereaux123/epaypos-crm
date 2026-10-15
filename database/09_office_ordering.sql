-- =============================================================================
-- EPAY POS / Envision ATM Control Center — office display order
-- ---------------------------------------------------------------------------
-- Lets office boxes be dragged into a custom left-to-right order in the
-- Team Structure hierarchy view, instead of always sorting alphabetically.
-- =============================================================================

alter table offices add column if not exists sort_order integer;

-- Give the existing seeded offices a stable initial order (alphabetical,
-- same as what the app already showed) rather than leaving sort_order null
-- for everyone, which would make the first drag-reorder jump unpredictably.
update offices set sort_order = sub.rn
from (
  select id, row_number() over (order by name) as rn
  from offices
) sub
where offices.id = sub.id and offices.sort_order is null;

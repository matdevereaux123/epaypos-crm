-- =============================================================================
-- EPAY POS / Envision ATM Control Center — freeform canvas + residual/equipment fields
-- ---------------------------------------------------------------------------
-- Part 1: lets every box in the Team Structure hierarchy view (offices and
-- people) be dragged to an arbitrary position and have it stick, instead of
-- being auto-arranged by the CSS tree layout. Nullable — anything without a
-- saved position yet falls back to an auto-layout default in the app.
--
-- Part 2: residual split % and equipment placement info for Agents/EPAY
-- Resellers specifically — kept as text like every other money/percentage
-- field in this schema (commission_value, highest_sale_amount, etc.), since
-- the app already treats those as free-form rather than strictly numeric.
-- =============================================================================

alter table partners
  add column if not exists canvas_x double precision,
  add column if not exists canvas_y double precision,
  add column if not exists residual_percentage text,
  add column if not exists free_equipment_placement text,
  add column if not exists purchased_equipment text;

alter table offices
  add column if not exists canvas_x double precision,
  add column if not exists canvas_y double precision;

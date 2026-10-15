-- =============================================================================
-- EPAY POS / Envision ATM Control Center — turning a visit into a lead
-- ---------------------------------------------------------------------------
-- Run after 65_cold_outreach.sql. Safe to re-run.
--
-- The visit log records places someone physically called on. When one of
-- those turns into something, it had to be retyped into Cold Leads or the
-- pipeline by hand — the business name, address and whatever contact details
-- were collected at the door, all entered twice.
--
-- These columns record that a visit was converted, and into what. The visit
-- itself stays: it is a log of where someone went, and that history is worth
-- keeping whether or not the call led anywhere. Marking it also stops the
-- same visit being converted twice, which is the failure that produces two
-- cold leads for one business and no sign of why.
-- =============================================================================

alter table cold_outreach
  add column if not exists converted_to        text
    check (converted_to is null or converted_to in ('cold_lead', 'lead')),
  add column if not exists converted_record_id uuid,
  add column if not exists converted_at        timestamptz;

-- Deliberately not a foreign key. If the lead it became is later deleted,
-- the visit should keep saying it was converted rather than silently
-- reverting to looking un-actioned.
create index if not exists cold_outreach_converted_idx
  on cold_outreach (converted_to) where converted_to is not null;


-- =============================================================================
-- AFTER RUNNING THIS
--   Prospecting -> Visits, use Convert on a row, and check the new record
--   carries the business name, address and contact from the visit.
-- =============================================================================

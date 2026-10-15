-- =============================================================================
-- EPAY POS / Envision ATM Control Center — Account Boarding stage / MID
-- ---------------------------------------------------------------------------
-- New "Account Boarding" stage on the EPAY POS pipeline, between App ID
-- Entered and Equipment Shipment & Confirmation. A lead can't move past it
-- until the MID (Merchant ID Number, issued by the processor) is on file.
-- No check constraint on leads.stage — it's a plain text column, so the new
-- stage key needs no schema change beyond this one new column.
-- =============================================================================

alter table leads add column if not exists mid text;

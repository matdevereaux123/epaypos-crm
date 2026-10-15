-- =============================================================================
-- 94 - Read-only. What is actually sitting in cold_leads from that import.
--
-- The leftover report showed 9 rows whose source still carries the mojibake
-- dash, i.e. rows from the FIRST pass of the account sheet import. The REDO
-- was meant to delete that pass before re-inserting it, but its delete said
--     created_at = '2026-09-13'
-- which compares a timestamp to a date and matches only exactly midnight, so
-- it removed nothing. Those 9 are very likely duplicates of 9 of the 14 clean
-- rows, carrying mangled placeholders where the contact and email should be.
--
-- This only looks. Nothing is changed, nothing is deleted.
-- =============================================================================

select business_name,
       case when contact_name = 'needs to be filled'
            then 'redo (clean)'
            else 'first pass (mangled)' end            as which_pass,
       phone,
       contact_name,
       (created_by is null)                            as unattributed,
       promoted,
       created_at
  from cold_leads
 where source like 'Imported from Salesforce export%'
   and source like '%flagged for manual review'
 order by business_name, which_pass;

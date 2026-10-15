-- =============================================================================
-- 105 - Read-only. What is actually stored as a date of birth.
--
-- Reported: an application filled in from a /apply link shows today's date as
-- the date of birth in the CRM. There are two very different causes and this
-- tells them apart in one run:
--
--   a) dob_decrypted matches what the applicant typed
--      -> the database is right and the CRM is displaying it wrong.
--
--   b) dob_decrypted is the submission date, or null
--      -> the value is being lost or overwritten on the way in, and the fix
--         is in public_submit_application / the form.
--
-- Nothing is changed by this file.
-- =============================================================================

select id,
       coalesce(first_name, '') || ' ' || coalesce(last_name, '') as applicant,
       submitted_at::date                                          as submitted,
       (dob is null)                                               as dob_is_null,
       decrypt_sensitive(dob)                                      as dob_decrypted,
       decrypt_sensitive(dob) = submitted_at::date::text           as dob_equals_submitted,
       source
  from applications
 order by submitted_at desc
 limit 10;

-- =============================================================================
-- EPAY POS / Envision ATM Control Center — finish locking down the onboarding RPCs
-- ---------------------------------------------------------------------------
-- Run after 19_partner_onboarding_submit.sql.
--
-- 19 revoked EXECUTE from PUBLIC, which was not enough: Supabase's default
-- privileges grant EXECUTE on new functions in the public schema to `anon`
-- and `authenticated` DIRECTLY. Revoking from public leaves that direct grant
-- in place, so my_onboarding_status() was still callable with the anon key
-- after 19 ran. (18 appeared to work only because 17 had already revoked
-- from anon separately — the two halves together did the job.)
--
-- Locking a function to signed-in users therefore takes all three:
--
--   revoke execute on function <name>(<args>) from public;
--   revoke execute on function <name>(<args>) from anon;
--   grant  execute on function <name>(<args>) to authenticated;
--
-- No data was exposed by this. my_onboarding_status() keys off auth.uid(),
-- which is null for an anonymous caller, so it matched no row and returned
-- an empty object. This is consistency rather than incident.
-- =============================================================================

revoke execute on function my_onboarding_status() from anon;
revoke execute on function my_onboarding_status() from public;
grant  execute on function my_onboarding_status() to authenticated;

revoke execute on function submit_partner_onboarding(
  uuid, text, text, text, text, text, text, text, text, date, text, text, text, text, text, text, text, text
) from anon;
revoke execute on function submit_partner_onboarding(
  uuid, text, text, text, text, text, text, text, text, date, text, text, text, text, text, text, text, text
) from public;
grant execute on function submit_partner_onboarding(
  uuid, text, text, text, text, text, text, text, text, date, text, text, text, text, text, text, text, text
) to authenticated;

-- Belt and braces on the earlier set, since the same default-privilege
-- behaviour applies to all of them.
revoke execute on function current_partner_is_own(uuid)    from anon;
revoke execute on function can_invite_partner(uuid)        from anon;
revoke execute on function mark_partner_invited(uuid)      from anon;
revoke execute on function reveal_partner_banking(uuid)    from anon;
revoke execute on function set_partner_banking(uuid, text) from anon;
revoke execute on function reveal_partner_sensitive(uuid)  from anon;
revoke execute on function set_partner_sensitive(uuid, text, text, text, text) from anon;

-- =============================================================================
-- VERIFY: every one of these, called with only the public anon key, must come
-- back 401. Anything returning 200 or 204 is still reachable.
-- =============================================================================

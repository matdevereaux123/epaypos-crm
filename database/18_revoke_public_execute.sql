-- =============================================================================
-- EPAY POS / Envision ATM Control Center — take EXECUTE away from public
-- ---------------------------------------------------------------------------
-- Follow-up to 17_harden_permission_checks.sql. Run after it.
--
-- 17 tried to lock these down with `revoke execute ... from anon`, and that
-- had no effect. Postgres grants EXECUTE on a new function to the PUBLIC
-- pseudo-role automatically, and `anon` inherits from public — so revoking
-- from anon while public still holds the grant changes nothing. Verified
-- after running 17: current_partner_is_own and can_invite_partner were both
-- still callable with only the public anon key.
--
-- The fix is to revoke from PUBLIC, then grant back to `authenticated`
-- explicitly. That is the pattern every function here should follow.
--
-- These two leak no data on their own — both return a boolean, and for an
-- anonymous caller that boolean is always false. can_invite_partner is worth
-- closing anyway: it answers "does this partner have a signed admit packet on
-- file", which is an existence oracle for anyone who has a partner UUID.
-- =============================================================================

revoke execute on function current_partner_is_own(uuid)   from public;
revoke execute on function can_invite_partner(uuid)       from public;
revoke execute on function mark_partner_invited(uuid)     from public;
revoke execute on function reveal_partner_banking(uuid)   from public;
revoke execute on function set_partner_banking(uuid, text) from public;
revoke execute on function reveal_partner_sensitive(uuid) from public;
revoke execute on function set_partner_sensitive(uuid, text, text, text, text) from public;

grant execute on function current_partner_is_own(uuid)   to authenticated;
grant execute on function can_invite_partner(uuid)       to authenticated;
grant execute on function mark_partner_invited(uuid)     to authenticated;
grant execute on function reveal_partner_banking(uuid)   to authenticated;
grant execute on function set_partner_banking(uuid, text) to authenticated;
grant execute on function reveal_partner_sensitive(uuid) to authenticated;
grant execute on function set_partner_sensitive(uuid, text, text, text, text) to authenticated;

-- =============================================================================
-- WORTH KNOWING FOR EVERY FUTURE FUNCTION
-- `grant execute ... to authenticated` on its own does not restrict anything,
-- because public already holds the grant. To actually limit a function to
-- signed-in users it takes both halves:
--
--   revoke execute on function <name>(<args>) from public;
--   grant  execute on function <name>(<args>) to authenticated;
--
-- The same applies to the lead-side RPCs in 02_encryption.sql. They fail
-- closed on their own permission checks, so they are not exposed — but they
-- are still callable by anon, and tightening them the same way would be
-- worthwhile housekeeping.
-- =============================================================================

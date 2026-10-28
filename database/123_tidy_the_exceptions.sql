-- =============================================================================
-- 123 - Clear the extras that no longer mean anything, and stop a role
--       promising access it does not grant.
--
-- Two bits of housekeeping that both come out of 121. Neither widens anybody's
-- access by a single record - read the statements, nothing here grants.
--
-- 1. FOUR REDUNDANT EXTRAS. Kennedy, Riley, Steven and Talgat each carry
--    extra_perms {"staffTools": true}. Since 121 the in_house_sales role
--    grants staffTools itself, so those ticks change nothing.
--
--    Worth removing anyway, and not for tidiness: Mitch's viewAllLeads leak
--    went unnoticed for months because extra_perms was full of ticks that
--    looked normal. If that column only ever holds genuine exceptions, the
--    next one is visible the moment you glance at the users list. This only
--    removes the key where the role already provides it, so nobody loses a
--    capability - verified by the report at the end.
--
-- 2. A ROLE THAT OVERSTATES ITSELF. in_house_sales describes itself as
--    "Full access to partners and follow-ups; can view but not edit payout
--    banking" - but the stored row has viewAllPartners false and viewBanking
--    false, and has for a long time. The permissions are almost certainly the
--    deliberate choice and the sentence is the stale part, so the sentence is
--    what changes here. Nothing about what the role can do is touched.
--
--    If reps ARE meant to see the partner pages, that is the opposite fix and
--    one line - say so and it gets its own migration.
--
-- Safe to run twice.
-- =============================================================================

update users u
   set extra_perms = nullif(u.extra_perms - 'staffTools', '{}'::jsonb)
  from roles r
 where r.key = u.role
   and u.extra_perms ? 'staffTools'
   and coalesce((r.perms ->> 'staffTools')::boolean, false) = true;

update roles
   set description = 'Internal reps - their own records plus their team''s, '
                  || 'and the inbound leads that arrive through the public '
                  || 'forms. Not other users'' leads and not the imported back '
                  || 'catalogue. Can send applications, contracts and emails. '
                  || 'No partner pages, no payout banking, no user or settings '
                  || 'management.'
 where key = 'in_house_sales';

-- Who still carries an exception, and whether it is a real one. Anything
-- listed here is now a genuine grant that the role does not already give.
select u.name, u.role, u.extra_perms,
       r.perms ->> 'staffTools' as role_already_grants_staff_tools
  from users u
  join roles r on r.key = u.role
 where u.extra_perms is not null and u.extra_perms <> '{}'::jsonb
 order by u.name;

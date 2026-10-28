-- =============================================================================
-- 122 - A portal login that is not joined to its partner row sees nothing.
--
-- Found while checking why Mitch could not see his sub-agents' leads. The
-- policies were right; the join was missing:
--
--     users.linked_partner_id = null
--
-- Everything an ISO or agent can see starts from that column. 120 walks
-- partners.parent_partner_id to reach the downline, 26 does the same for the
-- partner list, and leads carry linked_partner_id. With a null there, every
-- one of those rules begins at nothing and matches nothing - so the fix in
-- 120 reported "0 downline agent leads" and looked like an empty downline
-- rather than a broken link.
--
-- This is not a Mitch problem. Any portal user invited before the link was
-- set, or created by hand, is in the same state and equally blind.
--
-- HOW IT MATCHES. Email first, because it is unique on both tables and is
-- what the invite was sent to. Then an exact name match as a fallback. In
-- both cases ONLY when exactly one partner row matches and that row is not
-- already claimed by another user - a wrong join here would show one
-- partner's deals and banking to another person, which is worse than the
-- blindness it cures. Anything ambiguous is left alone and listed at the end
-- for you to pair by hand.
--
-- Changes no lead, account or note. Safe to run twice.
-- =============================================================================

-- Email, the reliable one.
update users u
   set linked_partner_id = p.id
  from partners p
 where u.linked_partner_id is null
   and u.role in ('iso','agent','referral_partner','epay_reseller')
   and u.email is not null
   and lower(p.email) = lower(u.email)
   and not exists (select 1 from users o
                    where o.linked_partner_id = p.id and o.id <> u.id)
   and (select count(*) from partners q
         where lower(q.email) = lower(u.email)) = 1;

-- Exact name, for the rows whose partner record carries a different contact
-- address from the login.
update users u
   set linked_partner_id = p.id
  from partners p
 where u.linked_partner_id is null
   and u.role in ('iso','agent','referral_partner','epay_reseller')
   and lower(trim(p.name)) = lower(trim(u.name))
   and not exists (select 1 from users o
                    where o.linked_partner_id = p.id and o.id <> u.id)
   and (select count(*) from partners q
         where lower(trim(q.name)) = lower(trim(u.name))) = 1;

-- ------------------------------------------------------------------ report
-- Every portal login and where it stands. "STILL NOT LINKED" rows are the
-- ones no safe match existed for.
select u.name, u.role, u.email,
       p.name as joined_to_partner,
       (select count(*) from partners c where c.parent_partner_id = u.linked_partner_id)
         as agents_under_them,
       (select count(*) from leads l
         where l.linked_partner_id = u.linked_partner_id)              as own_partner_leads,
       case when u.linked_partner_id is null
            then 'STILL NOT LINKED - no single safe match'
            else 'linked' end as state
  from users u
  left join partners p on p.id = u.linked_partner_id
 where u.role in ('iso','agent','referral_partner','epay_reseller')
 order by (u.linked_partner_id is null) desc, u.name;

-- Partner rows with nobody logging in as them, to pair against the list
-- above by eye. A name here that obviously belongs to a "STILL NOT LINKED"
-- person above is a hand-join: tell me the two and I will write it.
select p.name, p.email, p.type, p.reseller_type, p.link_slug,
       (select count(*) from partners c where c.parent_partner_id = p.id) as agents_under_it,
       (select count(*) from leads l where l.linked_partner_id = p.id)    as leads_on_it
  from partners p
 where not exists (select 1 from users u where u.linked_partner_id = p.id)
 order by (select count(*) from partners c where c.parent_partner_id = p.id) desc, p.name;

-- =============================================================================
-- 121 - Permissions come from the role, and palm_tree_admin goes.
--
-- Two problems, one cause. The stored roles had drifted from what their own
-- labels claim - Admin, the role described as "full control, every record",
-- had viewAllLeads false - and the gaps were being patched per person in
-- users.extra_perms. That is how Mitch ended up able to read every lead in
-- the company while the admins could not: a tick on one person, invisible
-- unless you go looking for it.
--
-- So: each role is set to what its label says, once, here. Extras stay
-- available for genuine exceptions, and there is one left at the end of
-- this file - said out loud rather than left to be discovered.
--
-- WHAT EACH ROLE MEANS NOW
--
--   admin              everything. Every record, both brands, banking,
--                      users, settings, every calendar.
--   in_house_sales     the staff tools to do the job - send an
--                      application, a contract, an email - and their own
--                      records plus their team's (109/120). Not everyone's
--                      leads, not everyone's partners, not banking.
--   internal_management nothing by default. The role exists to be granted
--                      piece by piece, which is what it was built for.
--   iso, agent,
--   referral_partner,
--   epay_reseller      their own portal: their deals, their link, their own
--                      payout banking. Nothing internal.
--
-- Safe to run twice.
-- =============================================================================

-- Admin, saying what its label says.
update roles set perms = perms || jsonb_build_object(
  'manageUsers', true, 'manageSettings', true, 'viewAllPartners', true,
  'editPartners', true, 'viewBanking', true, 'editBanking', true,
  'manageAutomation', true, 'fullDashboard', true, 'viewAllLeads', true,
  'viewAllCalendars', true, 'staffTools', true)
 where key = 'admin';

-- In House Sales: the tools, not the keys.
update roles set perms = perms || jsonb_build_object(
  'staffTools', true, 'manageAutomation', true,
  'manageUsers', false, 'manageSettings', false,
  'viewAllPartners', false, 'editPartners', false,
  'viewBanking', false, 'editBanking', false,
  'fullDashboard', false, 'viewAllLeads', false, 'viewAllCalendars', false)
 where key = 'in_house_sales';

-- Internal Management: deliberately empty, granted per person.
update roles set perms = perms || jsonb_build_object(
  'staffTools', false, 'manageUsers', false, 'manageSettings', false,
  'viewAllPartners', false, 'editPartners', false, 'viewBanking', false,
  'editBanking', false, 'manageAutomation', false, 'fullDashboard', false,
  'viewAllLeads', false, 'viewAllCalendars', false)
 where key = 'internal_management';

-- The portal roles: their own, and nothing else. editBanking 'own' is what
-- lets a partner maintain their own payout details.
update roles set perms = perms || jsonb_build_object(
  'staffTools', false, 'manageUsers', false, 'manageSettings', false,
  'viewAllPartners', false, 'editPartners', false, 'viewBanking', false,
  'editBanking', 'own', 'manageAutomation', false, 'fullDashboard', false,
  'viewAllLeads', false, 'viewAllCalendars', false)
 where key in ('iso','agent','referral_partner','epay_reseller');

-- ---------------------------------------------------------------- palm tree
-- Mitch moves to ISO, which is what he is: a partner with agents under him.
-- He keeps his own leads, his agents' (120) and his team's (109) - that is
-- the ISO role plus the two downline rules, not a permission.
update users set role = 'iso' where role = 'palm_tree_admin';

-- THE ONE EXTRA LEFT ON PURPOSE. staffTools lets him send an application, a
-- contract and an email, which he does daily. It is a tool, not a view: it
-- widens nothing about whose records he can read. To take it away:
--   update users set extra_perms = extra_perms - 'staffTools'
--    where name = 'Mitchell Cochran';
update users
   set extra_perms = (coalesce(extra_perms, '{}'::jsonb) - 'viewAllLeads')
                     || '{"staffTools": true}'::jsonb
 where name = 'Mitchell Cochran';

-- Only once nobody is on it. A role with users still attached would orphan
-- their logins, so this refuses rather than cascades.
do $$
declare v_left int;
begin
  select count(*) into v_left from users where role = 'palm_tree_admin';
  if v_left > 0 then
    raise exception 'palm_tree_admin still has % user(s). Move them first.', v_left;
  end if;
  delete from roles where key = 'palm_tree_admin';
end $$;

select key, label,
       perms ->> 'staffTools'      as staff_tools,
       perms ->> 'fullDashboard'   as full_dashboard,
       perms ->> 'viewAllLeads'    as sees_every_lead,
       perms ->> 'manageUsers'     as manages_users,
       (select string_agg(u.name || coalesce(' [extra ' || u.extra_perms::text || ']', ''), ', ')
          from users u where u.role = roles.key) as people
  from roles
 order by key;

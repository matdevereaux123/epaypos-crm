-- =============================================================================
-- 121 - Permissions come from the role, and palm_tree_admin goes.
--
-- Admin, the role whose own description reads "full control, every record",
-- had viewAllLeads false in the stored row - so the people who are meant to
-- see everything could not, and the gap was being patched one person at a
-- time in users.extra_perms. That is how Mitch came to read every lead in the
-- company: a single tick on a single row, invisible unless you went looking.
--
-- This sets each role to what its label claims. It is deliberately surgical:
-- it forces only the permissions that decide WHO CAN SEE WHOSE RECORDS, and
-- leaves every working permission - partner access, follow-up automation,
-- banking visibility - exactly as you have it. The final SELECT prints the
-- result so you can read the whole matrix in one place.
--
-- One thing to know, because it is not obvious from the name:
--
--     fullDashboard is a see-every-lead permission.
--
-- app/index.html line 10809: "if(perms.viewAllLeads || perms.fullDashboard)
-- return inPlay" - it returns the unfiltered pool. So fullDashboard stays
-- false for every role except admin. In House Sales already had it false in
-- the stored row, which now looks like a deliberate decision rather than
-- drift, and this keeps it that way.
--
-- WHAT EACH ROLE MEANS AFTERWARDS
--
--   admin               every record, both brands, banking, users, settings,
--                       every calendar.
--   in_house_sales      the staff tools to do the job - send an application, a
--                       contract, an email - plus their own records and their
--                       team's (109/120). Not everyone's leads. Partner and
--                       banking access left as you have it.
--   internal_management no company-wide visibility. The role is granted piece
--                       by piece per person, which is what it was built for.
--   iso, agent,
--   referral_partner,
--   epay_reseller       their own portal: their deals, their link, their own
--                       payout banking, their downline's work (120). Nothing
--                       internal.
--
-- Safe to run twice. Changes no lead, account or note.
-- =============================================================================

-- Admin, finally saying what its label says.
update roles set perms = perms || jsonb_build_object(
  'manageUsers', true, 'manageSettings', true, 'viewAllPartners', true,
  'editPartners', true, 'viewBanking', true, 'editBanking', true,
  'manageAutomation', true, 'fullDashboard', true, 'viewAllLeads', true,
  'viewAllCalendars', true, 'staffTools', true)
 where key = 'admin';

-- In House Sales: the tools, not the company's whole pipeline. Note what is
-- NOT in this list - viewAllPartners, editPartners, viewBanking and
-- manageAutomation are untouched, because those are how the reps work.
update roles set perms = perms || jsonb_build_object(
  'staffTools', true,
  'viewAllLeads', false, 'fullDashboard', false,
  'manageUsers', false, 'manageSettings', false, 'viewAllCalendars', false)
 where key = 'in_house_sales';

-- Internal Management: no company-wide view by default. Anything a particular
-- person needs is granted on their own row in Settings - Users, which is the
-- point of the role.
update roles set perms = perms || jsonb_build_object(
  'viewAllLeads', false, 'fullDashboard', false, 'viewAllCalendars', false,
  'manageUsers', false, 'manageSettings', false)
 where key = 'internal_management';

-- The portal roles: their own, and nothing internal. editBanking 'own' is
-- what lets a partner maintain their payout details.
update roles set perms = perms || jsonb_build_object(
  'staffTools', false, 'manageUsers', false, 'manageSettings', false,
  'viewAllPartners', false, 'editPartners', false, 'viewBanking', false,
  'editBanking', 'own', 'manageAutomation', false, 'fullDashboard', false,
  'viewAllLeads', false, 'viewAllCalendars', false)
 where key in ('iso','agent','referral_partner','epay_reseller');

-- ---------------------------------------------------------------- palm tree
-- Mitch moves to ISO, which is what he is: a partner with agents under him.
-- His own leads, his agents' (120) and his team's (109) reach him through the
-- downline rules - not through a permission that also shows him ours.
update users set role = 'iso' where role = 'palm_tree_admin';

-- THE ONE EXTRA LEFT ON PURPOSE, said out loud rather than left to be found.
-- staffTools sends an application, a contract and an email, which he does
-- daily. It is a tool, not a view: it widens nothing about whose records he
-- can read. viewAllLeads comes off - that was the leak. To remove the extra
-- entirely as well:
--   update users set extra_perms = extra_perms - 'staffTools'
--    where name = 'Mitchell Cochran';
update users
   set extra_perms = (coalesce(extra_perms, '{}'::jsonb)
                       - 'viewAllLeads' - 'fullDashboard')
                     || '{"staffTools": true}'::jsonb
 where name = 'Mitchell Cochran';

-- Only once nobody is on it. A role with users still attached would strand
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

-- The whole matrix, to read in one go.
select key, label,
       perms ->> 'staffTools'       as staff_tools,
       perms ->> 'viewAllLeads'     as sees_every_lead,
       perms ->> 'fullDashboard'    as full_dashboard_also_sees_every_lead,
       perms ->> 'viewAllCalendars' as sees_every_calendar,
       perms ->> 'manageUsers'      as manages_users,
       perms ->> 'viewAllPartners'  as sees_partners,
       perms ->> 'editBanking'      as edits_banking,
       (select string_agg(u.name || coalesce(' [extra ' || nullif(u.extra_perms::text,'{}') || ']', ''), ', ' order by u.name)
          from users u where u.role = roles.key) as people
  from roles
 order by (key = 'admin') desc, key;

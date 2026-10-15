/* =========================================================================
   84_scope_in_house_sales.sql — In House Sales sees their own, and what is
   assigned to them

   fullDashboard was doing two jobs at once:

     "see every record"        — visibility
     "you are staff, you may
      send email, send a
      contract, add an
      application"             — capability

   One permission, two meanings, so scoping what an In House Sales rep can
   SEE would also have taken away the tools they work with. This splits
   them: fullDashboard keeps the visibility meaning and comes off that role,
   and a new staffTools carries the capability and stays on.

   What a rep sees afterwards: leads, cold leads, applications, contacts,
   tasks, cold outreach, lending and ISO leads that are theirs or assigned
   to them. Nothing another rep created.

   What they keep: the unclaimed inbound pool. A lead or application that
   came in through a public form has no creator, and somebody has to work
   it — that was the rule asked for when In House Sales was first scoped
   ("just see any leads that come in through forms but not created by any
   other users"), and it still holds. Those two clauses move to staffTools
   so they survive.

   RUN ORDER MATTERS
     Redeploy the send-email function BEFORE running this. The version
     deployed today checks fullDashboard alone, so between this file and
     that deploy an In House Sales rep cannot send any email at all. The
     new version accepts either.
   ========================================================================= */

-- ---------------------------------------------------------------- the roles
update roles
   set perms = perms || '{"staffTools": true}'::jsonb
 where key in ('admin', 'in_house_sales');

update roles
   set perms = perms || '{"fullDashboard": false}'::jsonb
 where key = 'in_house_sales';


-- ------------------------------------------- the unclaimed inbound clauses
-- Only ever about records with NO creator: a form submission nobody has
-- claimed. It does not expose anything another rep entered.
drop policy if exists "leads_select" on leads;
create policy "leads_select" on leads
  for select to authenticated
  using (
    current_app_has_perm('viewAllLeads')
    or linked_partner_id = current_app_linked_partner_id()
    or assigned_to       = current_app_user_id()
    or current_app_user_id() = ANY(assigned_to_ids)
    or created_by        = current_app_user_id()
    or ((current_app_has_perm('fullDashboard') or current_app_has_perm('staffTools'))
        and created_by is null)
  );

drop policy if exists "applications_select" on applications;
create policy "applications_select" on applications
  for select to authenticated
  using (
    current_app_has_perm('fullDashboard')
    or assigned_to = current_app_user_id()
    or current_app_user_id() = ANY(assigned_to_ids)
    -- An application submitted through a public link whose own creator was
    -- nobody. This table has no created_by; assigned_to is what gets set,
    -- from the link's creator (database/59_application_assignment.sql), so
    -- "unclaimed" is simply having no assignee.
    or (current_app_has_perm('staffTools')
        and assigned_to is null
        and coalesce(array_length(assigned_to_ids, 1), 0) = 0)
  );

comment on column roles.perms is
  'fullDashboard means "sees every record". staffTools means "is staff": may send email, send a contract, add an application, edit marketing materials. They were one permission until database/84_scope_in_house_sales.sql split them.';

/* =========================================================================
   AFTER RUNNING THIS
     Preview as an In House Sales rep. Leads, cold leads, applications,
     contacts and tasks should narrow to theirs plus unclaimed inbound. The
     Agreements tab, the email buttons and Add Application should all still
     be there.
   ========================================================================= */

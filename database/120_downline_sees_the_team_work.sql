-- =============================================================================
-- 120 - A downline is agents as well as employees, and it reaches cold leads.
--
-- There are two chains in this system and visibility only ever followed one
-- of them:
--
--   users.manager_id          an employee reports to a manager  (109)
--   partners.parent_partner_id  an agent is recruited under another agent
--
-- An ISO with sub-agents is the second kind. leads_select gives them
-- "linked_partner_id = my own partner row" and nothing more, so every lead
-- their downline submitted was invisible to them - while partners_select has
-- used current_partner_has_in_downline since 26, which is why they can see
-- the agents but not the agents' work.
--
-- Cold leads were narrower still: your own assignments, full stop. No
-- reporting line, no partner downline. A manager or an ISO could not see
-- what their people were working, which is most of what either job is.
--
-- Both policies now follow both chains. Employees below you on the reporting
-- line, agents below you in the recruiting tree, and the leads and cold leads
-- belonging to either.
--
-- Safe to run twice.
-- =============================================================================

-- ---------------------------------------------------------------------- leads
drop policy if exists "leads_select" on leads;
create policy "leads_select" on leads
  for select to authenticated
  using (
    current_app_has_perm('viewAllLeads')
    or current_app_has_perm('fullDashboard')
    or linked_partner_id = current_app_linked_partner_id()
    -- new: an agent recruited under me, however many levels down
    or (linked_partner_id is not null and current_partner_has_in_downline(linked_partner_id))
    or assigned_to       = current_app_user_id()
    or current_app_user_id() = ANY(assigned_to_ids)
    or created_by        = current_app_user_id()
    or assigned_to = ANY(current_app_downline_user_ids())
    or created_by  = ANY(current_app_downline_user_ids())
    or assigned_to_ids && current_app_downline_user_ids()
    or ((current_app_has_perm('fullDashboard') or current_app_has_perm('staffTools'))
        and lead_is_unclaimed_inbound(created_by, assigned_to, assigned_to_ids, lead_source))
  );

drop policy if exists "leads_write" on leads;
create policy "leads_write" on leads
  for all to authenticated
  using (
    current_app_has_perm('viewAllLeads')
    or current_app_has_perm('fullDashboard')
    or linked_partner_id = current_app_linked_partner_id()
    or (linked_partner_id is not null and current_partner_has_in_downline(linked_partner_id))
    or assigned_to       = current_app_user_id()
    or current_app_user_id() = ANY(assigned_to_ids)
    or created_by        = current_app_user_id()
    or assigned_to = ANY(current_app_downline_user_ids())
    or created_by  = ANY(current_app_downline_user_ids())
    or assigned_to_ids && current_app_downline_user_ids()
    or ((current_app_has_perm('fullDashboard') or current_app_has_perm('staffTools'))
        and lead_is_unclaimed_inbound(created_by, assigned_to, assigned_to_ids, lead_source))
  )
  with check (
    current_app_has_perm('viewAllLeads')
    or current_app_has_perm('fullDashboard')
    or linked_partner_id = current_app_linked_partner_id()
    or (linked_partner_id is not null and current_partner_has_in_downline(linked_partner_id))
    or assigned_to       = current_app_user_id()
    or current_app_user_id() = ANY(assigned_to_ids)
    or created_by        = current_app_user_id()
    or assigned_to = ANY(current_app_downline_user_ids())
    or created_by  = ANY(current_app_downline_user_ids())
    or assigned_to_ids && current_app_downline_user_ids()
  );

-- ----------------------------------------------------------------- cold leads
drop policy if exists "cold_leads_select" on cold_leads;
create policy "cold_leads_select" on cold_leads
  for select to authenticated
  using (
    current_app_has_perm('fullDashboard')
    or assigned_to = current_app_user_id()
    or current_app_user_id() = ANY(assigned_to_ids)
    or created_by  = current_app_user_id()
    -- the reporting line
    or assigned_to = ANY(current_app_downline_user_ids())
    or created_by  = ANY(current_app_downline_user_ids())
    or assigned_to_ids && current_app_downline_user_ids()
  );

-- Editing one stays with the person working it and the people above them,
-- which is the same rule: you can work on what your team is working.
drop policy if exists "cold_leads_update" on cold_leads;
create policy "cold_leads_update" on cold_leads
  for update to authenticated
  using (
    current_app_has_perm('fullDashboard')
    or assigned_to = current_app_user_id()
    or current_app_user_id() = ANY(assigned_to_ids)
    or created_by  = current_app_user_id()
    or assigned_to = ANY(current_app_downline_user_ids())
    or created_by  = ANY(current_app_downline_user_ids())
    or assigned_to_ids && current_app_downline_user_ids()
  )
  with check (
    current_app_has_perm('fullDashboard')
    or assigned_to = current_app_user_id()
    or current_app_user_id() = ANY(assigned_to_ids)
    or created_by  = current_app_user_id()
    or assigned_to = ANY(current_app_downline_user_ids())
    or created_by  = ANY(current_app_downline_user_ids())
    or assigned_to_ids && current_app_downline_user_ids()
  );

-- What this opens up, per person with somebody under them.
select u.name,
       u.role,
       (select count(*) from users d where d.manager_id = u.id)              as reports,
       (select count(*) from leads l
         where l.linked_partner_id in (select partner_downline_ids(u.linked_partner_id)))
                                                                            as downline_agent_leads
  from users u
 where exists (select 1 from users d where d.manager_id = u.id)
    or (u.linked_partner_id is not null
        and exists (select 1 from partners p where p.parent_partner_id = u.linked_partner_id))
 order by u.name;

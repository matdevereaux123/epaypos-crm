-- =============================================================================
-- 118 - "Unclaimed" should mean an inbound form lead, not an old one.
--
-- leads_select lets staff see a lead nobody owns:
--
--     (fullDashboard or staffTools) and created_by is null
--
-- The intent was the inbound pool - a lead that arrived through a form with
-- nobody's name on it, which anybody on the team may pick up. What it
-- actually matches is every lead with no creator, and that includes:
--
--   * everything imported from Salesforce (created through the SQL editor,
--     where there is no app user to stamp),
--   * every lead created before 46 added created_by at all.
--
-- Which is why a rep scoped to his own records can read the whole back
-- catalogue of company accounts.
--
-- An inbound lead is one that came through a form or a partner link, has no
-- creator AND no assignee. All three, because any one of them alone is the
-- bug: no creator catches the imports, a form source alone would catch a
-- form lead somebody is already working, and no assignee alone catches
-- anything unassigned.
--
-- The form functions (12, 33, 34) write lead_source as 'Lead form - <label>'
-- or 'Referral link - <partner>'. That prefix is the marker; a lead typed in
-- by hand carries whatever the rep chose and does not match.
--
-- Safe to run twice.
-- =============================================================================

create or replace function lead_is_unclaimed_inbound(
  p_created_by uuid, p_assigned_to uuid, p_assigned_to_ids uuid[], p_lead_source text
) returns boolean
language sql
immutable
as $$
  select p_created_by is null
     and p_assigned_to is null
     and coalesce(array_length(p_assigned_to_ids, 1), 0) = 0
     and p_lead_source is not null
     and (p_lead_source like 'Lead form%' or p_lead_source like 'Referral link%');
$$;

grant execute on function lead_is_unclaimed_inbound(uuid, uuid, uuid[], text) to authenticated;

drop policy if exists "leads_select" on leads;
create policy "leads_select" on leads
  for select to authenticated
  using (
    current_app_has_perm('viewAllLeads')
    or linked_partner_id = current_app_linked_partner_id()
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
    or linked_partner_id = current_app_linked_partner_id()
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
    or linked_partner_id = current_app_linked_partner_id()
    or assigned_to       = current_app_user_id()
    or current_app_user_id() = ANY(assigned_to_ids)
    or created_by        = current_app_user_id()
    or assigned_to = ANY(current_app_downline_user_ids())
    or created_by  = ANY(current_app_downline_user_ids())
    or assigned_to_ids && current_app_downline_user_ids()
    or ((current_app_has_perm('fullDashboard') or current_app_has_perm('staffTools'))
        and lead_is_unclaimed_inbound(created_by, assigned_to, assigned_to_ids, lead_source))
  );

-- How many leads this takes off a scoped rep's board, and what is left in
-- the genuine inbound pool.
select count(*) filter (where created_by is null)                            as no_creator_at_all,
       count(*) filter (where lead_is_unclaimed_inbound(created_by, assigned_to, assigned_to_ids, lead_source))
                                                                             as genuinely_unclaimed_inbound
  from leads;

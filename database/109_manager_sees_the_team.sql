-- =============================================================================
-- 109 - A manager sees the leads their team is working.
--
-- Who may see a lead has been: whoever it is assigned to, whoever created it,
-- the partner it belongs to, anyone with viewAllLeads, and the unclaimed
-- inbound pool for staff. Nothing about the reporting line - so somebody with
-- three reps under them saw their own leads and nothing their team was
-- working, and the only fix on offer was viewAllLeads, which is everybody's
-- leads rather than their team's.
--
-- The reporting line already exists and is already used this way elsewhere:
-- internal_sales_comp scopes pay by users.manager_id (79). This applies the
-- same line to leads.
--
-- Recursive on purpose. A manager of managers sees the whole branch beneath
-- them, not just their direct reports. The CTE carries the path and refuses
-- to revisit a user, so two people set as each other's manager - which the
-- UI permits - loops once and stops rather than spinning.
--
-- Three ways a lead can belong to the team: assigned to a report, a report
-- among its extra assignees, or entered by a report. The third matters as
-- much as the first - a rep who adds leads and never assigns them would
-- otherwise be invisible to the manager who hired them.
--
-- Select and write together. The CRM's existing rule is that being able to
-- open a record you cannot save is never a sensible pair.
--
-- Safe to run twice.
-- =============================================================================

create or replace function current_app_downline_user_ids()
returns uuid[]
language sql
stable
security definer
set search_path = public
as $$
  with recursive line as (
    select id, array[id] as path
      from users
     where manager_id = current_app_user_id()
       and current_app_user_id() is not null
    union all
    select u.id, l.path || u.id
      from users u
      join line l on u.manager_id = l.id
     where not u.id = any(l.path)          -- a cycle stops here
       and array_length(l.path, 1) < 25    -- and so does a silly depth
  )
  select coalesce(array_agg(distinct id), '{}'::uuid[]) from line;
$$;

revoke execute on function current_app_downline_user_ids() from public;
revoke execute on function current_app_downline_user_ids() from anon;
grant  execute on function current_app_downline_user_ids() to authenticated;

comment on function current_app_downline_user_ids() is
  'Every user below the caller on users.manager_id, recursively. Empty array '
  'for somebody with nobody reporting to them. STABLE so RLS evaluates it '
  'once per statement rather than once per row.';


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
    -- new: the team's work, however it got there
    or assigned_to = ANY(current_app_downline_user_ids())
    or created_by  = ANY(current_app_downline_user_ids())
    or assigned_to_ids && current_app_downline_user_ids()
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
    or ((current_app_has_perm('fullDashboard') or current_app_has_perm('staffTools'))
        and created_by is null)
    or assigned_to = ANY(current_app_downline_user_ids())
    or created_by  = ANY(current_app_downline_user_ids())
    or assigned_to_ids && current_app_downline_user_ids()
  )
  with check (
    current_app_has_perm('viewAllLeads')
    or linked_partner_id = current_app_linked_partner_id()
    or assigned_to       = current_app_user_id()
    or current_app_user_id() = ANY(assigned_to_ids)
    or created_by        = current_app_user_id()
    or ((current_app_has_perm('fullDashboard') or current_app_has_perm('staffTools'))
        and created_by is null)
    or assigned_to = ANY(current_app_downline_user_ids())
    or created_by  = ANY(current_app_downline_user_ids())
    or assigned_to_ids && current_app_downline_user_ids()
  );

-- Check it with Mitch's id: should list his reports, and theirs.
--   select current_app_downline_user_ids();

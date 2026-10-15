-- =============================================================================
-- DIAGNOSTIC — are applications arriving, and can anyone see them?
-- ---------------------------------------------------------------------------
-- Read-only. Changes nothing. Safe to run any time.
--
-- "The form submits but nothing shows up" has two completely different
-- causes, and they need opposite fixes:
--
--   A. The row never arrives    — the link points somewhere with no backend,
--                                 or the submit is failing.
--   B. The row arrives and the  — every RLS policy on applications requires
--      viewer cannot see it       fullDashboard, which requires the login to
--                                 resolve to a users row. An account whose
--                                 auth_id was never linked is refused
--                                 everything, silently, and an empty tab
--                                 looks exactly like a form that does not work.
--
-- The same missing link also explains "new row violates row-level security
-- policy for table application_link_tokens" — that policy needs the same
-- identity this one does.
--
-- One query, one result set, because the SQL Editor only shows the last.
-- =============================================================================

select 1 as ord, 'applications in the table' as check,
       count(*)::text as detail
  from applications

union all
select 2, 'most recent application',
       coalesce((select coalesce(legal_business_name, first_name || ' ' || last_name, '(no name)')
                        || '  —  ' || to_char(submitted_at, 'Mon DD HH24:MI')
                        || '  —  source: ' || coalesce(source, 'null')
                   from applications order by submitted_at desc limit 1),
                'none yet  <-- nothing has ever arrived')

union all
select 3, 'arrived in the last 7 days',
       count(*)::text
  from applications
 where submitted_at > now() - interval '7 days'

-- Every login, and whether it resolves to anything. An account with
-- auth_linked = NO is refused by every policy in the system.
union all
select 4, 'login: ' || u.email,
       case when u.auth_id is null then 'NOT LINKED  <-- sees nothing, cannot write'
            else 'ok, role ' || coalesce(u.role, '(none)')
                 || ', fullDashboard=' || coalesce((r.perms->>'fullDashboard'), 'false')
       end
  from users u
  left join roles r on r.key = u.role

-- Which links exist to submit through, and whether they are the tracked kind.
union all
select 5, 'link: /apply/' || t.slug,
       t.label || '  —  kind: ' || coalesce(t.kind, 'application')
              || ', ' || case when t.is_active then 'active' else 'RETIRED' end
              || ', submissions: ' || t.submissions::text
  from application_link_tokens t

-- Leads still pointing at a marketing page rather than a tracked link. These
-- are the ones migration 48 repairs; anything filled in through them is
-- filled in on a page with no backend and is gone.
union all
select 6, 'leads still on a dead-end link',
       count(*)::text || case when count(*) > 0
                              then '  <-- run database/48_fix_application_link_default.sql'
                              else '' end
  from leads
 where application_link_choice is not null
   and application_link_choice <> 'portal'

order by ord;

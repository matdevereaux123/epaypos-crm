/* =========================================================================
   80_recruiting_admin_only.sql — Recruiting goes back to admins only

   79 opened Recruiting up to whoever a recruit was assigned to, on the same
   owner-scoped rule as partners. That was the wrong read of the ask: who we
   are hiring, and who has been approached, is not something the sales floor
   should be browsing at all — not even their own slice of it.

   So this is narrower than what it replaces: manageUsers, full stop. The
   assigned_to column stays, because assigning a recruit to whoever is
   working them is still useful for admins; it just no longer grants sight
   of the record.
   ========================================================================= */

drop policy if exists "recruit_leads_select" on recruit_leads;
drop policy if exists "recruit_leads_write" on recruit_leads;
drop policy if exists "recruit_leads_all" on recruit_leads;

create policy "recruit_leads_all" on recruit_leads
  for all to authenticated
  using (current_app_has_perm('manageUsers'))
  with check (current_app_has_perm('manageUsers'));

comment on table recruit_leads is
  'Our own hiring pipeline. Admins only (manageUsers) — database/80_recruiting_admin_only.sql. assigned_to records who is working a recruit; it does not grant visibility.';

/* =========================================================================
   AFTER RUNNING THIS
     Anyone who is not an admin gets an empty list from this table, and the
     Recruiting tab is hidden for them. Check by using Preview as on a rep.
   ========================================================================= */

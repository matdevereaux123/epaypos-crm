/* =========================================================================
   92_fix_write_scope_after_84.sql — saves that reported success and wrote
   nothing

     "assignments go away when we refresh"
     "subscriptions past the first one don't stay after a refresh"

   Both are the same fault, and it is mine. database/84 split fullDashboard
   into "sees every record" and staffTools "is staff", took fullDashboard
   off In House Sales, and taught leads_select and applications_select to
   accept staffTools for unclaimed inbound records — a lead or application
   that arrived through a public form and has no owner yet.

   It did not teach the matching WRITE policies the same thing.

   So for a rep working a website lead: the row is visible, and every
   update to it matches zero rows. That is the part that makes this nasty —
   an UPDATE that passes no rows is not an error. PostgREST returns
   success, the app updates what is on screen and says "Saved", and the
   row in the database never changed. It only surfaces on refresh, which
   is exactly how it was reported.

   Everything that edits one of those records is affected, not just the two
   noticed: the assignment picker, subscriptions, stage moves, notes
   written against the lead, follow-up dates.
   ========================================================================= */

drop policy if exists "leads_write" on leads;
create policy "leads_write" on leads
  for all to authenticated
  using (
    current_app_has_perm('viewAllLeads')
    or linked_partner_id = current_app_linked_partner_id()
    or assigned_to       = current_app_user_id()
    or current_app_user_id() = ANY(assigned_to_ids)
    or created_by        = current_app_user_id()
    -- Unclaimed inbound. Same test as leads_select, which is the point:
    -- being able to open a record and not being able to save it is never a
    -- sensible pair.
    or ((current_app_has_perm('fullDashboard') or current_app_has_perm('staffTools'))
        and created_by is null)
  )
  with check (
    current_app_has_perm('viewAllLeads')
    or linked_partner_id = current_app_linked_partner_id()
    or assigned_to       = current_app_user_id()
    or current_app_user_id() = ANY(assigned_to_ids)
    or created_by        = current_app_user_id()
    or ((current_app_has_perm('fullDashboard') or current_app_has_perm('staffTools'))
        and created_by is null)
  );


drop policy if exists "applications_update" on applications;
create policy "applications_update" on applications
  for update to authenticated
  using (
    current_app_has_perm('fullDashboard')
    or assigned_to = current_app_user_id()
    or current_app_user_id() = ANY(assigned_to_ids)
    or (current_app_has_perm('staffTools')
        and assigned_to is null
        and coalesce(array_length(assigned_to_ids, 1), 0) = 0)
  )
  with check (
    current_app_has_perm('fullDashboard')
    or assigned_to = current_app_user_id()
    or current_app_user_id() = ANY(assigned_to_ids)
    or (current_app_has_perm('staffTools')
        and assigned_to is null
        and coalesce(array_length(assigned_to_ids, 1), 0) = 0)
  );

/* =========================================================================
   AFTER RUNNING THIS
     Preview as an In House Sales rep, open a lead that came in through the
     website, assign it to somebody and add a subscription. Refresh. Both
     should still be there.

     The app now also refuses to say "saved" when an update touched no
     rows, so if a policy is ever wrong again it says so at the time rather
     than looking fine until the next refresh.
   ========================================================================= */

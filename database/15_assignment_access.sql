-- =============================================================================
-- EPAY POS / Envision ATM Control Center — assignment-based access
-- ---------------------------------------------------------------------------
-- Closes three gaps between "this record is assigned to you" and "you can
-- actually work it". Run after 04_rls.sql and 11_lead_documents.sql.
--
-- The rule this file enforces everywhere: an internal user with fullDashboard
-- sees everything; anyone else sees a record only if it is assigned to them,
-- or tied to their own partner record. Nothing is visible by default.
--
-- 1. lead_documents was fullDashboard-only, so an agent assigned to a lead
--    could open the lead but not the documents attached to it. Document
--    access now follows the lead, for both the table and the storage bucket.
--
-- 2. cold_leads and applications had no assigned_to column at all, so they
--    could not be handed to anyone — they were internal-only or nothing.
--
-- NOTE ON SENSITIVE FILES: lead documents can include scanned IDs, voided
-- cheques and bank statements. This file deliberately ties document access
-- to LEAD access, which means an assigned agent can open the documents on
-- their own leads. If you would rather documents stay internal even on an
-- assigned lead, change the three policies below that reference `leads` to
-- require current_app_has_perm('viewBanking') as well — the structure is
-- already there, it is a one-line addition to each `using` clause.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1a. lead_documents — access follows the parent lead
-- ---------------------------------------------------------------------------
drop policy if exists "lead_documents_all" on lead_documents;

create policy "lead_documents_select" on lead_documents
  for select to authenticated
  using (
    exists (
      select 1 from leads l
      where l.id = lead_documents.lead_id
        and (
          current_app_has_perm('fullDashboard')
          or l.linked_partner_id = current_app_linked_partner_id()
          or l.assigned_to = current_app_user_id()
        )
    )
  );

-- Whoever can see the lead can attach to it.
create policy "lead_documents_insert" on lead_documents
  for insert to authenticated
  with check (
    exists (
      select 1 from leads l
      where l.id = lead_documents.lead_id
        and (
          current_app_has_perm('fullDashboard')
          or l.linked_partner_id = current_app_linked_partner_id()
          or l.assigned_to = current_app_user_id()
        )
    )
  );

-- Editing and removing documents stays internal — an assigned agent should
-- not be able to delete paperwork off a deal.
create policy "lead_documents_update" on lead_documents
  for update to authenticated
  using (current_app_has_perm('fullDashboard'))
  with check (current_app_has_perm('fullDashboard'));

create policy "lead_documents_delete" on lead_documents
  for delete to authenticated
  using (current_app_has_perm('fullDashboard'));


-- ---------------------------------------------------------------------------
-- 1b. The storage bucket has to agree with the table, or the row is visible
--     and the file behind it still 403s.
--
--     Upload paths are built as `<lead_id>/<timestamp>-<filename>`
--     (see uploadAccountDocument in app/index.html), so the first path
--     segment identifies the lead. split_part on that is what lets the
--     bucket policy reuse the same rule as the table.
-- ---------------------------------------------------------------------------
drop policy if exists "lead_documents_bucket_select" on storage.objects;
drop policy if exists "lead_documents_bucket_insert" on storage.objects;
drop policy if exists "lead_documents_bucket_delete" on storage.objects;

create policy "lead_documents_bucket_select" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'lead-documents'
    and exists (
      select 1 from leads l
      where l.id::text = split_part(storage.objects.name, '/', 1)
        and (
          current_app_has_perm('fullDashboard')
          or l.linked_partner_id = current_app_linked_partner_id()
          or l.assigned_to = current_app_user_id()
        )
    )
  );

create policy "lead_documents_bucket_insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'lead-documents'
    and exists (
      select 1 from leads l
      where l.id::text = split_part(storage.objects.name, '/', 1)
        and (
          current_app_has_perm('fullDashboard')
          or l.linked_partner_id = current_app_linked_partner_id()
          or l.assigned_to = current_app_user_id()
        )
    )
  );

create policy "lead_documents_bucket_delete" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'lead-documents'
    and current_app_has_perm('fullDashboard')
  );


-- ---------------------------------------------------------------------------
-- 2a. cold_leads — assignable
-- ---------------------------------------------------------------------------
alter table cold_leads
  add column if not exists assigned_to uuid references users(id) on delete set null;

create index if not exists cold_leads_assigned_to_idx on cold_leads (assigned_to);

drop policy if exists "cold_leads_all" on cold_leads;

create policy "cold_leads_select" on cold_leads
  for select to authenticated
  using (
    current_app_has_perm('fullDashboard')
    or assigned_to = current_app_user_id()
  );

-- An assignee can work the record they were given; the with check stops them
-- reassigning it away from themselves or to someone else.
create policy "cold_leads_update" on cold_leads
  for update to authenticated
  using (
    current_app_has_perm('fullDashboard')
    or assigned_to = current_app_user_id()
  )
  with check (
    current_app_has_perm('fullDashboard')
    or assigned_to = current_app_user_id()
  );

create policy "cold_leads_insert" on cold_leads
  for insert to authenticated
  with check (current_app_has_perm('fullDashboard'));

create policy "cold_leads_delete" on cold_leads
  for delete to authenticated
  using (current_app_has_perm('fullDashboard'));


-- ---------------------------------------------------------------------------
-- 2b. applications — assignable, same shape
-- ---------------------------------------------------------------------------
alter table applications
  add column if not exists assigned_to uuid references users(id) on delete set null;

create index if not exists applications_assigned_to_idx on applications (assigned_to);

drop policy if exists "applications_all" on applications;

create policy "applications_select" on applications
  for select to authenticated
  using (
    current_app_has_perm('fullDashboard')
    or assigned_to = current_app_user_id()
  );

create policy "applications_update" on applications
  for update to authenticated
  using (
    current_app_has_perm('fullDashboard')
    or assigned_to = current_app_user_id()
  )
  with check (
    current_app_has_perm('fullDashboard')
    or assigned_to = current_app_user_id()
  );

create policy "applications_insert" on applications
  for insert to authenticated
  with check (current_app_has_perm('fullDashboard'));

create policy "applications_delete" on applications
  for delete to authenticated
  using (current_app_has_perm('fullDashboard'));


-- =============================================================================
-- AFTER RUNNING THIS
--   1. Confirm every table still shows RLS enabled in the Table Editor.
--   2. The real test is Phase 7: log in as an agent with one lead assigned
--      and confirm they see that lead and its documents, and nothing else —
--      no other partners, no cold leads they were not given, no applications,
--      no integrations. The SQL Editor runs as superuser and bypasses RLS
--      entirely, so none of this can be verified from in there.
-- =============================================================================

-- =============================================================================
-- EPAY POS / Envision ATM Control Center — the column that emptied the
-- Applications tab
-- ---------------------------------------------------------------------------
-- Run any time. Safe to re-run.
--
-- WHAT WAS WRONG
--
-- applications.paper_application_file_path did not exist, and the app asks
-- for it by name in loadApplicationsFromSupabase(). PostgREST rejects the
-- whole request when one column is unknown:
--
--   400  column applications.paper_application_file_path does not exist
--
-- The loader caught that, logged it to a console nobody had open, and
-- returned []. So APPLICATIONS was empty on every login regardless of how
-- many applications existed. Three had arrived and been stored correctly;
-- the tab showed nothing, which reads as the form being broken.
--
-- WHY THE COLUMN WENT MISSING
--
-- 07_applications_storage.sql adds it, then creates four policies on
-- storage.objects. The SQL editor runs a script as one transaction: if any of
-- those policy statements failed — the bucket not existing yet, or the role
-- lacking rights on storage.objects — the whole script rolled back, taking
-- the column with it. The script reports one error and undoes work that had
-- nothing to do with it.
--
-- So this file does the column on its own, first, and makes the policies
-- individually re-runnable. If the storage half still fails, the column
-- survives and the Applications tab works.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1. The column. This is the part that matters.
-- ---------------------------------------------------------------------------
alter table applications
  add column if not exists paper_application_file_path text;


-- ---------------------------------------------------------------------------
-- 2. The storage policies, from 07, made idempotent.
--
-- Postgres has no "create policy if not exists", and a duplicate aborts the
-- script — which is how the column was lost in the first place. Dropped
-- first so this section can run whatever state it is already in.
--
-- If this half errors on permissions, step 1 has already committed and the
-- Applications tab is fixed. Storage uploads for paper applications would
-- then need the bucket creating in the dashboard first.
-- ---------------------------------------------------------------------------
drop policy if exists "applications_bucket_select" on storage.objects;
drop policy if exists "applications_bucket_insert" on storage.objects;
drop policy if exists "applications_bucket_update" on storage.objects;
drop policy if exists "applications_bucket_delete" on storage.objects;

create policy "applications_bucket_select" on storage.objects
  for select to authenticated
  using (bucket_id = 'applications' and current_app_has_perm('fullDashboard'));

create policy "applications_bucket_insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'applications' and current_app_has_perm('fullDashboard'));

create policy "applications_bucket_update" on storage.objects
  for update to authenticated
  using (bucket_id = 'applications' and current_app_has_perm('fullDashboard'))
  with check (bucket_id = 'applications' and current_app_has_perm('fullDashboard'));

create policy "applications_bucket_delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'applications' and current_app_has_perm('fullDashboard'));


-- =============================================================================
-- AFTER RUNNING THIS
--   Hard-refresh the CRM and open Applications. The three that already
--   arrived should be there.
--
--   To confirm the column took, independently of the app:
--     select count(*) as applications,
--            count(paper_application_file_path) as with_a_paper_file
--       from applications;
--   That query cannot run at all if the column is still missing.
-- =============================================================================

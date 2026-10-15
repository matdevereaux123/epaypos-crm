-- =============================================================================
-- EPAY POS / Envision ATM Control Center — paper application uploads
-- ---------------------------------------------------------------------------
-- Storage policies for the `applications` bucket (created manually in the
-- dashboard — Storage doesn't have a SQL "create bucket" the way tables do).
-- The bucket is private, so these policies are what actually gate who can
-- upload/view files, same fullDashboard check as the applications table's
-- own RLS policy in 04_rls.sql.
-- =============================================================================

alter table applications add column if not exists paper_application_file_path text;

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

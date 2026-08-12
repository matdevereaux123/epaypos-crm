-- =============================================================================
-- EPAY POS / Envision ATM Control Center — lead/account document attachments
-- ---------------------------------------------------------------------------
-- Moves the Leads drawer's "Applications & documents" attachments off
-- localStorage (base64 data URLs stored on leads.documents) onto a real
-- lead_documents table + a private `lead-documents` Storage bucket — same
-- pattern as 07_applications_storage.sql for paper application uploads.
--
-- The `lead-documents` bucket itself has to be created by hand in the
-- Storage dashboard (private, no public access) before running this —
-- Storage doesn't have a SQL "create bucket" the way tables do.
-- =============================================================================

create table lead_documents (
  id           uuid primary key default gen_random_uuid(),
  lead_id      uuid not null references leads(id) on delete cascade,
  name         text not null,
  doc_type     text not null default 'other' check (doc_type in ('paper', 'efiled', 'other')),
  size_bytes   bigint,
  storage_path text not null,
  uploaded_by  text not null,
  uploaded_at  date not null default current_date
);

alter table lead_documents enable row level security;

-- Internal-only, same as applications' paper-upload bucket — this is a
-- back-office file cabinet, not something partner/portal logins touch.
create policy "lead_documents_all" on lead_documents
  for all to authenticated
  using (current_app_has_perm('fullDashboard'))
  with check (current_app_has_perm('fullDashboard'));

create policy "lead_documents_bucket_select" on storage.objects
  for select to authenticated
  using (bucket_id = 'lead-documents' and current_app_has_perm('fullDashboard'));

create policy "lead_documents_bucket_insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'lead-documents' and current_app_has_perm('fullDashboard'));

create policy "lead_documents_bucket_delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'lead-documents' and current_app_has_perm('fullDashboard'));

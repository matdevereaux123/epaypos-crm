/* =========================================================================
   71_uploaded_agreement_documents.sql

   An agreement template can now BE a file — the PDF the lawyer already
   wrote — instead of something retyped into a textarea. Typed templates
   stay exactly as they are; this adds a second kind alongside them.

   Where the files live
     One private bucket, `agreement-documents`, with two areas:

       templates/<template_id>/<file>   the blank contract. Staff only.
       envelopes/<token>/<file>         the copy sent to one signer.

     The envelope copy is a COPY, made at send time, for the same reason
     document_text is a snapshot: replace the template file tomorrow and
     what somebody signed yesterday must not change under them.

     The signer is not logged in, so anon can read under envelopes/ — and
     only there. The token is the folder name, so reading a document still
     requires knowing the link it came in, which is the same secret the
     signing page itself is protected by. Nothing under templates/ is
     readable without a login, and anon cannot write anywhere in the bucket.

   What is NOT here: stamping the signature into the PDF. That happens in
   the browser (pdf-lib) when the signed copy is downloaded, from the
   original file plus the signature and audit trail held in the database —
   so the stored file stays the untouched original and the signed copy is
   reproducible from it rather than being a second source of truth.
   ========================================================================= */

-- --------------------------------------------------------------- templates
alter table agreement_templates add column if not exists source_type text not null default 'typed';
alter table agreement_templates add column if not exists file_path   text;
alter table agreement_templates add column if not exists file_name   text;
alter table agreement_templates add column if not exists file_type   text;
alter table agreement_templates add column if not exists file_size   bigint;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'agreement_templates_source_type_check') then
    alter table agreement_templates
      add constraint agreement_templates_source_type_check
      check (source_type in ('typed', 'file'));
  end if;
end $$;

-- A typed template has to have words in it; an uploaded one has to have a
-- file. Enforced here rather than trusted to the screen, because a template
-- with neither is a send button that produces nothing to sign.
alter table agreement_templates alter column body drop not null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'agreement_templates_has_content_check') then
    alter table agreement_templates
      add constraint agreement_templates_has_content_check
      check (
        (source_type = 'typed' and body is not null and length(btrim(body)) > 0)
        or
        (source_type = 'file' and file_path is not null)
      );
  end if;
end $$;


-- --------------------------------------------------------------- envelopes
alter table signature_requests add column if not exists file_path text;
alter table signature_requests add column if not exists file_name text;
alter table signature_requests add column if not exists file_type text;
alter table signature_requests add column if not exists file_size bigint;

alter table signature_requests alter column document_text drop not null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'signature_requests_has_document_check') then
    alter table signature_requests
      add constraint signature_requests_has_document_check
      check (document_text is not null or file_path is not null);
  end if;
end $$;

comment on column signature_requests.file_path is
  'Copy of the uploaded document made at send time, under envelopes/<token>/. A copy and not a reference to the template, so replacing the template file cannot change what was already signed.';


-- ------------------------------------------------- the signing page's view
-- Same function as in 69, with the file the signer needs to open added.
create or replace function public_open_signature_request(p_token text)
returns json
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  r signature_requests%rowtype;
begin
  select * into r from signature_requests where token = p_token;
  if not found then
    return json_build_object('found', false);
  end if;

  if r.status in ('sent','viewed') and r.expires_at is not null and r.expires_at < now() then
    update signature_requests set status = 'expired' where id = r.id returning * into r;
    insert into signature_events (request_id, event, detail)
      values (r.id, 'expired', 'Link reached its expiry date');
  end if;

  if r.status in ('sent','viewed') then
    update signature_requests
       set status          = case when status = 'sent' then 'viewed' else status end,
           first_viewed_at = coalesce(first_viewed_at, now()),
           last_viewed_at  = now(),
           view_count      = view_count + 1
     where id = r.id
     returning * into r;

    insert into signature_events (request_id, event, detail, actor, ip, user_agent)
      values (r.id, 'viewed', null, r.signer_email, request_client_ip(), request_user_agent());
  end if;

  return json_build_object(
    'found',            true,
    'title',            r.title,
    'document_text',    r.document_text,
    'file_path',        r.file_path,
    'file_name',        r.file_name,
    'file_type',        r.file_type,
    'file_size',        r.file_size,
    'signer_name',      r.signer_name,
    'signer_email',     r.signer_email,
    'signer_title',     r.signer_title,
    'signer_fields',    r.signer_fields,
    'require_initials', r.require_initials,
    'brand',            r.brand,
    'message',          r.message,
    'status',           r.status,
    'sent_by_name',     r.sent_by_name,
    'sent_by_email',    r.sent_by_email,
    'sent_at',          r.sent_at,
    'signed_at',        r.signed_at,
    'expires_at',       r.expires_at,
    'signature_name',   r.signature_name,
    'signature_image',  r.signature_image,
    'signature_style',  r.signature_style,
    'countersigned_at', r.countersigned_at,
    'countersign_name', r.countersign_name,
    'countersign_image',r.countersign_image,
    'decline_reason',   r.decline_reason
  );
end;
$$;

revoke execute on function public_open_signature_request(text) from public;
grant execute on function public_open_signature_request(text) to anon, authenticated;


-- Records that the signer opened the file itself, not just the page. Worth
-- its own event: "they never opened the document" is a different fact from
-- "they never signed it", and it is the one that decides what you say when
-- you chase them.
create or replace function public_log_document_opened(p_token text)
returns boolean
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  r signature_requests%rowtype;
begin
  select * into r from signature_requests where token = p_token;
  if not found then return false; end if;

  insert into signature_events (request_id, event, detail, actor, ip, user_agent)
    values (r.id, 'document_opened', r.file_name, r.signer_email,
            request_client_ip(), request_user_agent());
  return true;
end;
$$;

revoke execute on function public_log_document_opened(text) from public;
grant execute on function public_log_document_opened(text) to anon, authenticated;


-- ------------------------------------------------------------------ storage
-- Created here rather than by hand in the dashboard so re-running this file
-- is enough to rebuild it. Private: `public` is false.
insert into storage.buckets (id, name, public)
values ('agreement-documents', 'agreement-documents', false)
on conflict (id) do nothing;

drop policy if exists "agreement_docs_staff_read"   on storage.objects;
drop policy if exists "agreement_docs_staff_write"  on storage.objects;
drop policy if exists "agreement_docs_staff_update" on storage.objects;
drop policy if exists "agreement_docs_staff_delete" on storage.objects;
drop policy if exists "agreement_docs_anon_read"    on storage.objects;

create policy "agreement_docs_staff_read" on storage.objects
  for select to authenticated
  using (bucket_id = 'agreement-documents' and current_app_has_perm('fullDashboard'));

create policy "agreement_docs_staff_write" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'agreement-documents' and current_app_has_perm('fullDashboard'));

create policy "agreement_docs_staff_update" on storage.objects
  for update to authenticated
  using (bucket_id = 'agreement-documents' and current_app_has_perm('fullDashboard'))
  with check (bucket_id = 'agreement-documents' and current_app_has_perm('fullDashboard'));

create policy "agreement_docs_staff_delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'agreement-documents' and current_app_has_perm('fullDashboard'));

-- The signer's read. Only under envelopes/, never the template library, and
-- read only — anon has no insert, update or delete anywhere in this bucket.
create policy "agreement_docs_anon_read" on storage.objects
  for select to anon
  using (bucket_id = 'agreement-documents' and position('envelopes/' in name) = 1);


-- =============================================================================
-- AFTER RUNNING THIS
--   Storage -> Buckets should show `agreement-documents`, and it must NOT be
--   marked public. The policies above are what let a signer read their own
--   document; a public bucket would let anyone read everyone's.
-- =============================================================================

-- =============================================================================
-- EPAY POS / Envision ATM Control Center — voided check and driver's licence
-- ---------------------------------------------------------------------------
-- Run after 66_convert_visit.sql. Safe to re-run.
--
-- Underwriting needs a voided check and a photo of the owner's licence for
-- every application. They were being chased by email after the fact, which
-- is the slowest possible moment to ask: the applicant has already finished
-- and moved on.
--
-- The application form now takes both at the point of submission. They stay
-- optional on purpose — refusing an application because someone is not at
-- their desk with a chequebook loses the application, not the document. What
-- the form does instead is say plainly, on the confirmation, which ones are
-- still needed, and the CRM shows the same thing so whoever picks it up
-- knows what to ask for.
--
-- ON ANONYMOUS UPLOADS
--
-- The applicant is not logged in, so these are written by `anon`. The policy
-- below grants INSERT only, and only under the public/ prefix of the
-- applications bucket. anon cannot list, read, overwrite or delete anything:
-- a file can be put in, and from there only a signed-in member of staff can
-- ever see it. The bucket is private, so nothing is served publicly.
-- =============================================================================

alter table applications
  add column if not exists voided_check_file_path     text,
  add column if not exists drivers_license_file_path  text;


-- ---------------------------------------------------------------------------
-- Recording the path.
--
-- The applicant cannot update `applications` directly and should not be able
-- to; this takes the one field it is for. It refuses to overwrite a path
-- that is already set, so a replayed call cannot point an application at a
-- different file than the one it was submitted with.
-- ---------------------------------------------------------------------------
create or replace function public_attach_application_file(
  p_application_id uuid,
  p_kind           text,
  p_path           text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated int;
begin
  if p_kind not in ('voided_check', 'drivers_license') then
    raise exception 'Unknown document type';
  end if;
  if nullif(trim(coalesce(p_path, '')), '') is null then
    return false;
  end if;

  -- The path is confined to this application's own folder. Without this a
  -- caller could point one application at another's document.
  if position(('public/' || p_application_id::text || '/') in p_path) <> 1 then
    raise exception 'That file does not belong to this application';
  end if;

  if p_kind = 'voided_check' then
    update applications set voided_check_file_path = p_path
     where id = p_application_id and voided_check_file_path is null;
  else
    update applications set drivers_license_file_path = p_path
     where id = p_application_id and drivers_license_file_path is null;
  end if;

  get diagnostics v_updated = ROW_COUNT;
  return v_updated > 0;
end;
$$;

revoke execute on function public_attach_application_file(uuid, text, text) from public;
grant  execute on function public_attach_application_file(uuid, text, text) to anon, authenticated;


-- ---------------------------------------------------------------------------
-- Storage: anon may put a file in, and nothing else.
--
-- Dropped first so this file can be re-run; Postgres has no
-- "create policy if not exists" and a duplicate aborts the script.
-- ---------------------------------------------------------------------------
drop policy if exists "applications_bucket_anon_insert" on storage.objects;

create policy "applications_bucket_anon_insert" on storage.objects
  for insert to anon
  with check (
    bucket_id = 'applications'
    and position('public/' in name) = 1
  );


-- =============================================================================
-- AFTER RUNNING THIS
--   The `applications` bucket must already exist and be PRIVATE (it is — it
--   holds paper applications). Confirm under Storage that it is not public;
--   these are bank details and a photo ID.
--
--   Then submit a test application with both files and check they arrive:
--     select legal_business_name, voided_check_file_path, drivers_license_file_path
--       from applications order by submitted_at desc limit 1;
-- =============================================================================

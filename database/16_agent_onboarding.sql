-- =============================================================================
-- EPAY POS / Envision ATM Control Center — agent onboarding
-- ---------------------------------------------------------------------------
-- Run after 15_assignment_access.sql.
--
-- The flow this supports:
--   1. Someone internal creates the agent (name, email, type). The partner
--      row lands in onboarding_status = 'pending_packet'.
--   2. They upload the SIGNED partner admit packet. Nothing can be sent
--      until this exists — enforced in can_invite_partner() below, not just
--      hidden in the UI.
--   3. Sending the invite flips them to 'invited' and goes out through the
--      existing invite-user edge function.
--   4. The agent sets a password, lands in the portal, and sees a banner
--      until they complete their application. They have normal portal
--      access throughout.
--   5. Submitting flips them to 'submitted' for internal review; approving
--      flips them to 'active'.
--
-- Sensitive fields are entered by the AGENT, on their own record. That is
-- why the ownership checks below had to be fixed — see section 3.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1. Application fields, mirroring the merchant application on `leads`
--    Plaintext columns only here; SSN / DOB / DL / tax ID are encrypted and
--    handled by the RPCs in section 4.
-- ---------------------------------------------------------------------------
alter table partners
  add column if not exists owner_first_name       text,
  add column if not exists owner_last_name        text,
  add column if not exists drivers_license_state  text,
  add column if not exists legal_business_name    text,
  add column if not exists dba_name               text,
  add column if not exists business_address       text,
  add column if not exists business_phone         text,
  add column if not exists business_email         text,
  add column if not exists business_start_date    date,
  add column if not exists business_type_services text,
  add column if not exists personal_address       text,
  -- encrypted, written only through the RPCs in section 4
  add column if not exists ssn                    bytea,
  add column if not exists dob                    bytea,
  add column if not exists drivers_license        bytea,
  add column if not exists tax_id                 bytea;


-- ---------------------------------------------------------------------------
-- 2. Onboarding state
--
--    pending_packet -> the signed admit packet has not been uploaded yet;
--                      no invite can be sent
--    packet_on_file -> packet uploaded, ready to invite
--    invited        -> invite sent, agent has not finished the form
--    submitted      -> agent completed their application, awaiting review
--    active         -> approved and working
-- ---------------------------------------------------------------------------
alter table partners
  add column if not exists onboarding_status text not null default 'pending_packet'
    check (onboarding_status in ('pending_packet','packet_on_file','invited','submitted','active')),
  add column if not exists onboarding_submitted_at timestamptz,
  add column if not exists onboarding_approved_at  timestamptz,
  add column if not exists onboarding_approved_by  uuid references users(id) on delete set null;

create index if not exists partners_onboarding_status_idx on partners (onboarding_status);

-- Anything that already exists predates onboarding and should not suddenly
-- appear as half-onboarded.
update partners set onboarding_status = 'active'
  where onboarding_status = 'pending_packet' and created_at < now();


-- ---------------------------------------------------------------------------
-- 3. Fix the ownership check in the existing partner RPCs
--
--    reveal_partner_banking and set_partner_banking decided "is this my own
--    record" with `join users u on lower(u.email) = lower(p.email)`, while
--    every RLS policy uses users.linked_partner_id. Those are different
--    notions of identity: an agent whose login email differs from the contact
--    email on their partner record is granted the row by RLS and then refused
--    by the RPC. Self-service onboarding makes that break routine rather than
--    an edge case, since the agent has to write their own sensitive fields.
--
--    Both now prefer linked_partner_id and keep the email match as a fallback
--    for accounts created before linked_partner_id was populated.
-- ---------------------------------------------------------------------------
create or replace function current_partner_is_own(p_partner_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from users u
    left join partners p on p.id = p_partner_id
    where u.auth_id = auth.uid()
      and (
        u.linked_partner_id = p_partner_id
        or (u.linked_partner_id is null
            and p.email is not null
            and lower(u.email) = lower(p.email))
      )
  );
$$;
grant execute on function current_partner_is_own(uuid) to authenticated;

create or replace function reveal_partner_banking(p_partner_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_result text;
  v_view_banking text;
begin
  select (r.perms->>'viewBanking')
    into v_view_banking
    from users u join roles r on r.key = u.role
    where u.auth_id = auth.uid();

  if not (v_view_banking = 'true'
          or (v_view_banking = 'own' and current_partner_is_own(p_partner_id))) then
    raise exception 'Not authorized to view this field';
  end if;

  select decrypt_sensitive(banking) into v_result from partners where id = p_partner_id;
  return v_result;
end;
$$;
grant execute on function reveal_partner_banking(uuid) to authenticated;

create or replace function set_partner_banking(p_partner_id uuid, p_banking text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_edit_banking text;
begin
  select (r.perms->>'editBanking')
    into v_edit_banking
    from users u join roles r on r.key = u.role
    where u.auth_id = auth.uid();

  if not (v_edit_banking = 'true'
          or (v_edit_banking = 'own' and current_partner_is_own(p_partner_id))) then
    raise exception 'Not authorized to edit this field';
  end if;

  update partners set banking = encrypt_sensitive(p_banking) where id = p_partner_id;
end;
$$;
grant execute on function set_partner_banking(uuid, text) to authenticated;


-- ---------------------------------------------------------------------------
-- 4. The agent's own sensitive application fields
--
--    Same shape as the lead SSN/DOB RPCs: an agent may write and read back
--    their OWN, and anyone with the flat viewSensitive/editSensitive
--    permission may act on any. Nothing writes these columns directly.
-- ---------------------------------------------------------------------------
create or replace function set_partner_sensitive(
  p_partner_id uuid,
  p_ssn text,
  p_dob text,
  p_drivers_license text,
  p_tax_id text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_edit text;
begin
  select (r.perms->>'editBanking')
    into v_edit
    from users u join roles r on r.key = u.role
    where u.auth_id = auth.uid();

  if not (v_edit = 'true'
          or (v_edit = 'own' and current_partner_is_own(p_partner_id))) then
    raise exception 'Not authorized to edit this record';
  end if;

  update partners set
    ssn             = case when p_ssn             is null then ssn             else encrypt_sensitive(p_ssn) end,
    dob             = case when p_dob             is null then dob             else encrypt_sensitive(p_dob) end,
    drivers_license = case when p_drivers_license is null then drivers_license else encrypt_sensitive(p_drivers_license) end,
    tax_id          = case when p_tax_id          is null then tax_id          else encrypt_sensitive(p_tax_id) end
  where id = p_partner_id;
end;
$$;
grant execute on function set_partner_sensitive(uuid, text, text, text, text) to authenticated;

create or replace function reveal_partner_sensitive(p_partner_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_view text;
  v_row partners%rowtype;
begin
  select (r.perms->>'viewBanking')
    into v_view
    from users u join roles r on r.key = u.role
    where u.auth_id = auth.uid();

  if not (v_view = 'true'
          or (v_view = 'own' and current_partner_is_own(p_partner_id))) then
    raise exception 'Not authorized to view this record';
  end if;

  select * into v_row from partners where id = p_partner_id;

  return jsonb_build_object(
    'ssn',             decrypt_sensitive(v_row.ssn),
    'dob',             decrypt_sensitive(v_row.dob),
    'drivers_license', decrypt_sensitive(v_row.drivers_license),
    'tax_id',          decrypt_sensitive(v_row.tax_id)
  );
end;
$$;
grant execute on function reveal_partner_sensitive(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 5. Partner documents — the signed admit packet and anything else on file
--    Mirrors lead_documents, including the '<partner_id>/<file>' path
--    convention the bucket policies depend on.
-- ---------------------------------------------------------------------------
create table if not exists partner_documents (
  id           uuid primary key default gen_random_uuid(),
  partner_id   uuid not null references partners(id) on delete cascade,
  name         text not null,
  doc_type     text not null default 'other'
                 check (doc_type in ('admit_packet','w9','voided_check','id','other')),
  size_bytes   bigint,
  storage_path text not null,
  uploaded_by  text not null,
  uploaded_at  timestamptz not null default now()
);
create index if not exists partner_documents_partner_id_idx on partner_documents (partner_id);
create index if not exists partner_documents_doc_type_idx   on partner_documents (doc_type);

alter table partner_documents enable row level security;

-- The agent can see what is on file against them; only internal staff can
-- add or remove it. The admit packet is your countersigned agreement — an
-- agent must not be able to replace or delete it.
create policy "partner_documents_select" on partner_documents
  for select to authenticated
  using (
    current_app_has_perm('viewAllPartners')
    or partner_id = current_app_linked_partner_id()
  );

create policy "partner_documents_insert" on partner_documents
  for insert to authenticated
  with check (current_app_has_perm('editPartners'));

create policy "partner_documents_update" on partner_documents
  for update to authenticated
  using (current_app_has_perm('editPartners'))
  with check (current_app_has_perm('editPartners'));

create policy "partner_documents_delete" on partner_documents
  for delete to authenticated
  using (current_app_has_perm('editPartners'));

-- Bucket policies mirror the table, keyed off the first path segment.
create policy "partner_documents_bucket_select" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'partner-documents'
    and (
      current_app_has_perm('viewAllPartners')
      or split_part(storage.objects.name, '/', 1) = current_app_linked_partner_id()::text
    )
  );

create policy "partner_documents_bucket_insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'partner-documents'
    and current_app_has_perm('editPartners')
  );

create policy "partner_documents_bucket_delete" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'partner-documents'
    and current_app_has_perm('editPartners')
  );


-- ---------------------------------------------------------------------------
-- 6. The invite gate
--    "Required before the invite" enforced in the database, so it holds even
--    if the button is ever enabled by mistake.
-- ---------------------------------------------------------------------------
create or replace function can_invite_partner(p_partner_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from partner_documents d
    where d.partner_id = p_partner_id
      and d.doc_type = 'admit_packet'
  );
$$;
grant execute on function can_invite_partner(uuid) to authenticated;

-- Moving a partner past 'pending_packet' requires the packet to exist.
create or replace function mark_partner_invited(p_partner_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not current_app_has_perm('editPartners') then
    raise exception 'Not authorized';
  end if;

  if not can_invite_partner(p_partner_id) then
    raise exception 'The signed partner admit packet must be uploaded before an invite can be sent';
  end if;

  update partners
     set onboarding_status = 'invited'
   where id = p_partner_id
     and onboarding_status in ('pending_packet','packet_on_file');
end;
$$;
grant execute on function mark_partner_invited(uuid) to authenticated;


-- =============================================================================
-- AFTER RUNNING THIS
--   1. Create the storage bucket 'partner-documents' (private) in the
--      Supabase dashboard — the policies above assume it exists.
--   2. Confirm partners and partner_documents both show RLS enabled.
--   3. The real test is Phase 7: invite a test agent, complete the form as
--      them, and confirm they can read back their own sensitive fields and
--      cannot see any other partner's.
-- =============================================================================

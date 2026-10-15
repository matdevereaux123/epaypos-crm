/* =========================================================================
   69_esignature.sql — e-signature (DocuSign / Adobe Sign style)

   Three tables:

     agreement_templates  the contracts we write once, in the Agreements tab.
                          Body is plain text with {{merge_fields}} and a
                          light markdown (## heading, **bold**, - bullet).
                          Never rendered as raw HTML anywhere.

     signature_requests   one envelope — a template rendered for one signer,
                          at one moment, attached to one record. document_text
                          is a SNAPSHOT: editing the template afterwards must
                          not change what somebody already signed, which is
                          the whole point of keeping a copy per envelope.

     signature_events     the audit trail, append-only. Created/sent/viewed/
                          signed/declined/voided, each with IP and user agent,
                          because a signature nobody can prove the origin of
                          is not worth collecting.

   The signer is not logged in, so the three public_* functions at the bottom
   are SECURITY DEFINER and granted to anon — the same shape as
   12_public_referral.sql, 28_application_links.sql and 53_booking_links.sql.
   The only key is the token in the emailed link, so it is generated in the
   database (18 random bytes) and never chosen by the client.
   ========================================================================= */

-- ---------------------------------------------------------------- templates
create table if not exists agreement_templates (
  id               uuid primary key default gen_random_uuid(),
  name             text not null,
  description      text,
  brand            text not null default 'epay' check (brand in ('epay','atm','both')),
  category         text not null default 'agreement'
                     check (category in ('agreement','addendum','disclosure','authorization','nda','other')),
  -- Defaults for the email that carries the link. Overridable per send.
  email_subject    text,
  email_message    text,
  body             text not null,
  -- Extra things the signer must supply on the signing page, beyond their
  -- signature: [{key,label,type,required}]. Kept as data so a new field type
  -- does not need a migration.
  signer_fields    jsonb not null default '[]'::jsonb,
  require_initials boolean not null default false,
  -- Whether we sign it too. A merchant agreement usually needs both.
  require_countersign boolean not null default false,
  active           boolean not null default true,
  created_by       uuid references users(id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create index if not exists agreement_templates_active_idx on agreement_templates (active, name);

-- ---------------------------------------------------------------- envelopes
create table if not exists signature_requests (
  id              uuid primary key default gen_random_uuid(),
  token           text unique not null default encode(extensions.gen_random_bytes(18), 'hex'),
  template_id     uuid references agreement_templates(id) on delete set null,
  title           text not null,
  -- The snapshot, merge fields already filled in.
  document_text   text not null,
  signer_fields   jsonb not null default '[]'::jsonb,
  require_initials boolean not null default false,
  require_countersign boolean not null default false,
  brand           text not null default 'epay' check (brand in ('epay','atm','both')),

  -- What it is attached to. Loose reference on purpose: the same envelope
  -- shape has to serve leads, accounts, partners, cold leads and lending
  -- leads, and five nullable FKs would be worse than one pair of columns.
  record_type     text check (record_type in ('lead','account','partner','cold_lead','lending_lead','iso_lead','contact')),
  record_id       uuid,
  record_label    text,

  signer_name     text not null,
  signer_email    text not null,
  signer_title    text,
  cc_emails       text[],
  message         text,

  status          text not null default 'draft'
                    check (status in ('draft','sent','viewed','signed','declined','voided','expired')),
  sent_at         timestamptz,
  first_viewed_at timestamptz,
  last_viewed_at  timestamptz,
  view_count      integer not null default 0,
  signed_at       timestamptz,
  declined_at     timestamptz,
  voided_at       timestamptz,
  expires_at      timestamptz,
  reminder_sent_at timestamptz,
  decline_reason  text,

  -- What the signer actually did. The drawn signature is a small PNG data
  -- URL rather than a storage object: it is a few KB, it belongs to exactly
  -- one row, and keeping it here means no anon write path into a bucket.
  signature_name       text,
  signature_style      text,
  signature_image      text,
  initials_image       text,
  signer_field_values  jsonb,
  consent_agreed       boolean,
  signed_ip            text,
  signed_user_agent    text,

  -- Our side, when the template calls for it.
  countersigned_at        timestamptz,
  countersign_name        text,
  countersign_title       text,
  countersign_image       text,
  countersign_ip          text,
  countersigned_by        uuid references users(id) on delete set null,

  sent_by         uuid references users(id) on delete set null,
  sent_by_name    text,
  sent_by_email   text,
  created_at      timestamptz not null default now()
);

create index if not exists signature_requests_record_idx on signature_requests (record_type, record_id);
create index if not exists signature_requests_status_idx on signature_requests (status, created_at desc);
create index if not exists signature_requests_sent_by_idx on signature_requests (sent_by);

-- ------------------------------------------------------------- audit trail
create table if not exists signature_events (
  id          uuid primary key default gen_random_uuid(),
  request_id  uuid not null references signature_requests(id) on delete cascade,
  event       text not null,
  detail      text,
  actor       text,
  ip          text,
  user_agent  text,
  at          timestamptz not null default now()
);

create index if not exists signature_events_request_idx on signature_events (request_id, at);

-- ---------------------------------------------------------------------- RLS
alter table agreement_templates enable row level security;
alter table signature_requests  enable row level security;
alter table signature_events    enable row level security;

drop policy if exists "agreement_templates_select" on agreement_templates;
drop policy if exists "agreement_templates_write"  on agreement_templates;
drop policy if exists "agreement_templates_update" on agreement_templates;
drop policy if exists "agreement_templates_delete" on agreement_templates;

-- Every logged-in user may read the library: a blank contract carries no
-- customer data, and an agent who cannot see the list cannot send one.
create policy "agreement_templates_select" on agreement_templates
  for select to authenticated using (true);

-- Writing them is staff only. These are the legal documents we send out.
create policy "agreement_templates_write" on agreement_templates
  for insert to authenticated
  with check (current_app_has_perm('fullDashboard'));

create policy "agreement_templates_update" on agreement_templates
  for update to authenticated
  using (current_app_has_perm('fullDashboard'))
  with check (current_app_has_perm('fullDashboard'));

create policy "agreement_templates_delete" on agreement_templates
  for delete to authenticated
  using (current_app_has_perm('fullDashboard'));

drop policy if exists "signature_requests_select" on signature_requests;
drop policy if exists "signature_requests_insert" on signature_requests;
drop policy if exists "signature_requests_update" on signature_requests;
drop policy if exists "signature_requests_delete" on signature_requests;

-- An envelope carries the customer's name, email and signed contract, so it
-- follows the same rule as the records it attaches to: staff see everything,
-- everyone else sees only what they sent themselves.
create policy "signature_requests_select" on signature_requests
  for select to authenticated
  using (
    current_app_has_perm('fullDashboard')
    or sent_by = current_app_user_id()
  );

create policy "signature_requests_insert" on signature_requests
  for insert to authenticated
  with check (
    current_app_has_perm('fullDashboard')
    or sent_by = current_app_user_id()
  );

create policy "signature_requests_update" on signature_requests
  for update to authenticated
  using (
    current_app_has_perm('fullDashboard')
    or sent_by = current_app_user_id()
  )
  with check (
    current_app_has_perm('fullDashboard')
    or sent_by = current_app_user_id()
  );

create policy "signature_requests_delete" on signature_requests
  for delete to authenticated
  using (current_app_has_perm('fullDashboard'));

drop policy if exists "signature_events_select" on signature_events;
drop policy if exists "signature_events_insert" on signature_events;

create policy "signature_events_select" on signature_events
  for select to authenticated
  using (exists (
    select 1 from signature_requests r
    where r.id = signature_events.request_id
      and (current_app_has_perm('fullDashboard') or r.sent_by = current_app_user_id())
  ));

-- Insert, but never update or delete: an audit trail you can edit is not one.
create policy "signature_events_insert" on signature_events
  for insert to authenticated
  with check (exists (
    select 1 from signature_requests r
    where r.id = signature_events.request_id
      and (current_app_has_perm('fullDashboard') or r.sent_by = current_app_user_id())
  ));


/* -------------------------------------------------------------------------
   PUBLIC SIGNING
   Three functions the signer's browser calls with the anon key and nothing
   else. Each one takes the token and refuses to say anything useful about a
   token it does not recognise.
   ------------------------------------------------------------------------- */

-- Opening the link. Records the view (that is evidence too) and returns
-- everything the signing page needs — deliberately NOT the internal ids,
-- the record it is attached to, or who else it was cc'd to.
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

  -- An envelope past its date is dead whether or not anything has run to
  -- mark it so; check on read rather than trusting a sweep to have happened.
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


-- Signing. The IP and user agent are read from the request headers here,
-- server-side — a signature page that posted its own idea of the signer's IP
-- would be recording whatever the signer felt like claiming.
create or replace function public_sign_signature_request(
  p_token           text,
  p_signature_name  text,
  p_signature_image text,
  p_signature_style text,
  p_signer_title    text,
  p_field_values    jsonb,
  p_initials_image  text,
  p_consent         boolean
)
returns json
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  r signature_requests%rowtype;
  v_ip text := request_client_ip();
begin
  select * into r from signature_requests where token = p_token for update;
  if not found then
    return json_build_object('ok', false, 'error', 'This signing link is not valid.');
  end if;
  if r.status = 'signed' then
    return json_build_object('ok', false, 'error', 'This document has already been signed.');
  end if;
  if r.status = 'declined' then
    return json_build_object('ok', false, 'error', 'This document was declined.');
  end if;
  if r.status = 'voided' then
    return json_build_object('ok', false, 'error', 'This document was cancelled by the sender.');
  end if;
  if r.status = 'expired' or (r.expires_at is not null and r.expires_at < now()) then
    return json_build_object('ok', false, 'error', 'This signing link has expired. Ask your rep to send a new one.');
  end if;
  if coalesce(p_consent, false) is not true then
    return json_build_object('ok', false, 'error', 'You must agree to sign electronically.');
  end if;
  if coalesce(trim(p_signature_name), '') = '' then
    return json_build_object('ok', false, 'error', 'A signature is required.');
  end if;

  update signature_requests
     set status              = 'signed',
         signed_at           = now(),
         signature_name      = trim(p_signature_name),
         signature_image     = p_signature_image,
         signature_style     = p_signature_style,
         initials_image      = p_initials_image,
         signer_title        = coalesce(nullif(trim(coalesce(p_signer_title,'')), ''), signer_title),
         signer_field_values = p_field_values,
         consent_agreed      = true,
         signed_ip           = v_ip,
         signed_user_agent   = request_user_agent()
   where id = r.id;

  insert into signature_events (request_id, event, detail, actor, ip, user_agent)
    values (r.id, 'signed', 'Signed as ' || trim(p_signature_name), r.signer_email, v_ip, request_user_agent());

  -- Tell whoever sent it. A signature that comes back at 9pm is otherwise
  -- invisible until somebody happens to open the Agreements tab.
  if r.sent_by is not null then
    insert into notifications (user_id, type, title, body, link_view, link_id)
      values (r.sent_by, 'signature_signed',
              r.signer_name || ' signed ' || r.title,
              coalesce(r.record_label || ' — ', '') || 'Signed ' || to_char(now(), 'Mon DD at HH12:MI AM'),
              'esign', r.id);
  end if;

  return json_build_object('ok', true, 'signed_at', now(), 'ip', v_ip);
end;
$$;

revoke execute on function public_sign_signature_request(text, text, text, text, text, jsonb, text, boolean) from public;
grant execute on function public_sign_signature_request(text, text, text, text, text, jsonb, text, boolean) to anon, authenticated;


-- Declining. Worth its own path: "never signed" and "refused, and said why"
-- are different facts, and the second one is the useful one for the rep.
create or replace function public_decline_signature_request(p_token text, p_reason text)
returns json
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  r signature_requests%rowtype;
begin
  select * into r from signature_requests where token = p_token for update;
  if not found then
    return json_build_object('ok', false, 'error', 'This signing link is not valid.');
  end if;
  if r.status in ('signed','voided','declined') then
    return json_build_object('ok', false, 'error', 'This document is no longer open.');
  end if;

  update signature_requests
     set status         = 'declined',
         declined_at    = now(),
         decline_reason = nullif(trim(coalesce(p_reason, '')), '')
   where id = r.id;

  insert into signature_events (request_id, event, detail, actor, ip, user_agent)
    values (r.id, 'declined', nullif(trim(coalesce(p_reason, '')), ''), r.signer_email,
            request_client_ip(), request_user_agent());

  if r.sent_by is not null then
    insert into notifications (user_id, type, title, body, link_view, link_id)
      values (r.sent_by, 'signature_declined',
              r.signer_name || ' declined ' || r.title,
              nullif(trim(coalesce(p_reason, '')), ''),
              'esign', r.id);
  end if;

  return json_build_object('ok', true);
end;
$$;

revoke execute on function public_decline_signature_request(text, text) from public;
grant execute on function public_decline_signature_request(text, text) to anon, authenticated;


/* -------------------------------------------------------------------------
   OUR SIDE
   Countersigning runs through a function for the same reason signing does:
   so the IP on the record is the one the request actually came from.
   ------------------------------------------------------------------------- */
create or replace function countersign_signature_request(
  p_request_id uuid,
  p_name       text,
  p_title      text,
  p_image      text
)
returns json
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  r signature_requests%rowtype;
  v_me uuid := current_app_user_id();
begin
  if not coalesce(current_app_has_perm('fullDashboard'), false) then
    return json_build_object('ok', false, 'error', 'Not allowed to countersign.');
  end if;

  select * into r from signature_requests where id = p_request_id for update;
  if not found then
    return json_build_object('ok', false, 'error', 'No such document.');
  end if;
  if r.status <> 'signed' then
    return json_build_object('ok', false, 'error', 'The client has not signed this yet.');
  end if;
  if r.countersigned_at is not null then
    return json_build_object('ok', false, 'error', 'Already countersigned.');
  end if;
  if coalesce(trim(coalesce(p_name, '')), '') = '' then
    return json_build_object('ok', false, 'error', 'A name is required.');
  end if;

  update signature_requests
     set countersigned_at  = now(),
         countersign_name  = trim(p_name),
         countersign_title = nullif(trim(coalesce(p_title, '')), ''),
         countersign_image = p_image,
         countersign_ip    = request_client_ip(),
         countersigned_by  = v_me
   where id = r.id;

  insert into signature_events (request_id, event, detail, actor, ip, user_agent)
    values (r.id, 'countersigned', 'Countersigned by ' || trim(p_name),
            (select email from users where id = v_me),
            request_client_ip(), request_user_agent());

  return json_build_object('ok', true);
end;
$$;

revoke execute on function countersign_signature_request(uuid, text, text, text) from public;
revoke execute on function countersign_signature_request(uuid, text, text, text) from anon;
grant execute on function countersign_signature_request(uuid, text, text, text) to authenticated;


comment on table agreement_templates is 'Contract templates written once and sent many times (Agreements tab).';
comment on table signature_requests  is 'One e-signature envelope: a template snapshot sent to one signer for one record.';
comment on table signature_events    is 'Append-only audit trail for each envelope — created/sent/viewed/signed/declined/voided, with IP.';
comment on column signature_requests.document_text is 'Snapshot of the rendered template at send time. Never re-derived from the template, so later template edits cannot change what was signed.';

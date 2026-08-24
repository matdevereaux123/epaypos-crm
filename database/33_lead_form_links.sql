-- =============================================================================
-- EPAY POS / Envision ATM Control Center — shareable lead forms
-- ---------------------------------------------------------------------------
-- Run after 32_full_application_submit.sql.
--
-- The application link asks a prospect for the whole merchant application —
-- SSN, banking, the lot. That is a lot to put in front of someone who has not
-- decided anything yet. This is the short version: name, business, how to
-- reach them, roughly what they process. It creates a LEAD in the pipeline
-- rather than an application.
--
-- Reuses application_link_tokens with a `kind` column rather than a second
-- table — the two are the same object with different questions, and one table
-- means one lookup, one slug space and one place to retire a link.
--
-- Nothing sensitive is collected here, so unlike public_submit_application
-- there is no encryption to do. That is deliberate: if a lead form ever grows
-- an SSN field, it needs the same treatment applications got.
-- =============================================================================

alter table application_link_tokens
  add column if not exists kind text not null default 'application'
    check (kind in ('application', 'lead'));

create index if not exists application_link_tokens_kind_idx on application_link_tokens (kind);


-- The lookup has to say which form to render.
create or replace function public_lookup_application_link(p_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_row application_link_tokens%rowtype;
  v_partner_name text;
begin
  select * into v_row from application_link_tokens
   where slug = p_slug and is_active = true;

  if not found then
    return null;
  end if;

  if v_row.partner_id is not null then
    select name into v_partner_name from partners where id = v_row.partner_id;
  end if;

  return jsonb_build_object(
    'brand',        v_row.brand,
    'label',        v_row.label,
    'kind',         v_row.kind,
    'partner_name', v_partner_name
  );
end;
$$;

grant execute on function public_lookup_application_link(text) to anon, authenticated;


-- ---------------------------------------------------------------------------
-- The submission. Creates a lead at the front of the pipeline, credited to
-- whichever link brought it in so the reporting on where deals come from
-- stays honest.
-- ---------------------------------------------------------------------------
create or replace function public_submit_lead_form(
  p_slug             text,
  p_business_name    text,
  p_contact_name     text,
  p_email            text,
  p_phone            text,
  p_business_address text,
  p_business_type    text,
  p_est_volume       text,
  p_notes            text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_token application_link_tokens%rowtype;
  v_lead_id uuid;
  v_brand text;
begin
  select * into v_token from application_link_tokens
   where slug = p_slug and is_active = true and kind = 'lead';

  if not found then
    raise exception 'This form is no longer active';
  end if;

  if p_business_name is null or trim(p_business_name) = ''
     or p_contact_name is null or trim(p_contact_name) = '' then
    raise exception 'Business name and your name are required';
  end if;

  v_brand := case when v_token.brand = 'atm' then 'atm' else 'epay' end;

  insert into leads (
    brand, business_name, contact_name, phone, email,
    business_address, est_volume, business_type_services,
    stage, lead_source, linked_partner_id, general_follow_up_note
  ) values (
    v_brand,
    trim(p_business_name),
    trim(p_contact_name),
    coalesce(nullif(trim(coalesce(p_phone, '')), ''), '—'),
    coalesce(nullif(trim(coalesce(p_email, '')), ''), '—'),
    nullif(trim(coalesce(p_business_address, '')), ''),
    nullif(trim(coalesce(p_est_volume, '')), ''),
    nullif(trim(coalesce(p_business_type, '')), ''),
    'inbound_lead',
    -- Matches how the referral links label their source, so the two read the
    -- same way in reporting.
    'Lead form — ' || v_token.label,
    v_token.partner_id,
    nullif(trim(coalesce(p_notes, '')), '')
  )
  returning id into v_lead_id;

  update application_link_tokens
     set submissions = submissions + 1
   where id = v_token.id;

  return v_lead_id;
end;
$$;

grant execute on function public_submit_lead_form(
  text, text, text, text, text, text, text, text, text
) to anon, authenticated;


-- =============================================================================
-- AFTER RUNNING THIS
--   Existing links keep kind = 'application' by default, so nothing already
--   sent out changes behaviour. Create a lead form from the Leads tab, open
--   it, submit, and confirm a lead lands at Inbound Lead with its source
--   naming the link.
-- =============================================================================

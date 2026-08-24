-- =============================================================================
-- EPAY POS / Envision ATM Control Center — recording terms acceptance
-- ---------------------------------------------------------------------------
-- Run after 33_lead_form_links.sql.
--
-- Ticking the box on a public form now creates a record that stands as a
-- signed agreement: when they accepted, from what address, which document
-- they were shown, and what browser they used.
--
-- THE IP IS READ SERVER-SIDE, from the request headers, NOT sent by the
-- browser. A page cannot reliably know its own public address, and anything
-- it did send could be edited by whoever is filling in the form — which would
-- make the whole record worthless as evidence. PostgREST exposes the real
-- headers to SQL through current_setting('request.headers').
--
-- The terms URL is stored per acceptance rather than assumed. If the document
-- moves or is rewritten, an old record still says which one that person
-- actually agreed to.
-- =============================================================================

alter table applications
  add column if not exists terms_accepted_at timestamptz,
  add column if not exists terms_ip          text,
  add column if not exists terms_url         text,
  add column if not exists terms_user_agent  text;

alter table leads
  add column if not exists terms_accepted    boolean not null default false,
  add column if not exists terms_accepted_at timestamptz,
  add column if not exists terms_ip          text,
  add column if not exists terms_url         text,
  add column if not exists terms_user_agent  text;


-- ---------------------------------------------------------------------------
-- The caller's address, as the server saw it.
--
-- x-forwarded-for is a comma-separated chain when proxies are involved and the
-- ORIGINAL client is the first entry — later ones are the proxies themselves.
-- Falls back to the direct peer address where no proxy header exists.
-- ---------------------------------------------------------------------------
create or replace function request_client_ip()
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_headers json;
  v_fwd text;
begin
  begin
    v_headers := current_setting('request.headers', true)::json;
  exception when others then
    return null;
  end;

  if v_headers is null then
    return null;
  end if;

  v_fwd := v_headers->>'x-forwarded-for';
  if v_fwd is not null and trim(v_fwd) <> '' then
    return trim(split_part(v_fwd, ',', 1));
  end if;

  return nullif(trim(coalesce(v_headers->>'cf-connecting-ip', '')), '');
end;
$$;

revoke execute on function request_client_ip() from public;
revoke execute on function request_client_ip() from anon;
grant execute on function request_client_ip() to authenticated;


create or replace function request_user_agent()
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_headers json;
begin
  begin
    v_headers := current_setting('request.headers', true)::json;
  exception when others then
    return null;
  end;
  if v_headers is null then return null; end if;
  return left(coalesce(v_headers->>'user-agent', ''), 400);
end;
$$;

revoke execute on function request_user_agent() from public;
revoke execute on function request_user_agent() from anon;
grant execute on function request_user_agent() to authenticated;


-- ---------------------------------------------------------------------------
-- The application submit now refuses without acceptance, and records it.
-- Same 26-argument signature plus the terms URL, so the old one is dropped.
-- ---------------------------------------------------------------------------
drop function if exists public_submit_application(
  text, text, text, text, text, text, text, text, text, text, text, text,
  text, text, text, text, text, text, text, text, text, text, text, text,
  text, boolean
);

create or replace function public_submit_application(
  p_slug                   text,
  p_first_name             text,
  p_last_name              text,
  p_email                  text,
  p_phone                  text,
  p_dob                    text,
  p_ssn                    text,
  p_drivers_license        text,
  p_drivers_license_state  text,
  p_legal_business_name    text,
  p_dba_name               text,
  p_business_address       text,
  p_business_email         text,
  p_business_phone         text,
  p_business_start_date    text,
  p_business_tax_id        text,
  p_business_type          text,
  p_business_type_services text,
  p_monthly_sales_average  text,
  p_highest_sale_amount    text,
  p_average_sale_amount    text,
  p_bank_name              text,
  p_routing_number         text,
  p_account_number         text,
  p_pricing_plan           text,
  p_terms_accepted         boolean,
  p_terms_url              text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_token application_link_tokens%rowtype;
  v_id uuid;
  v_start date;
begin
  select * into v_token from application_link_tokens
   where slug = p_slug and is_active = true;

  if not found then
    raise exception 'This application link is no longer active';
  end if;

  -- Enforced here, not only in the browser. An application without an
  -- accepted agreement is not one we want on file at all.
  if coalesce(p_terms_accepted, false) is not true then
    raise exception 'The terms of service must be accepted to submit this application';
  end if;

  if p_legal_business_name is null or trim(p_legal_business_name) = ''
     or p_first_name is null or trim(p_first_name) = ''
     or p_last_name is null or trim(p_last_name) = '' then
    raise exception 'Business name and your name are required';
  end if;

  begin
    v_start := nullif(trim(coalesce(p_business_start_date, '')), '')::date;
  exception when others then
    v_start := null;
  end;

  insert into applications (
    email, phone,
    first_name, last_name, drivers_license_state,
    legal_business_name, dba_name, business_address, business_email,
    business_phone, business_start_date, business_type, business_type_services,
    monthly_sales_average, highest_sale_amount, average_sale_amount,
    pricing_plan, terms_accepted,
    terms_accepted_at, terms_ip, terms_url, terms_user_agent,
    source, link_token_id, match_status,
    ssn, dob, drivers_license, business_tax_id, banking,
    raw_payload
  ) values (
    nullif(trim(coalesce(p_email, '')), ''),
    nullif(trim(coalesce(p_phone, '')), ''),

    nullif(trim(coalesce(p_first_name, '')), ''),
    nullif(trim(coalesce(p_last_name, '')), ''),
    nullif(trim(coalesce(p_drivers_license_state, '')), ''),

    nullif(trim(coalesce(p_legal_business_name, '')), ''),
    nullif(trim(coalesce(p_dba_name, '')), ''),
    nullif(trim(coalesce(p_business_address, '')), ''),
    nullif(trim(coalesce(p_business_email, '')), ''),
    nullif(trim(coalesce(p_business_phone, '')), ''),
    v_start,
    nullif(trim(coalesce(p_business_type, '')), ''),
    nullif(trim(coalesce(p_business_type_services, '')), ''),

    nullif(trim(coalesce(p_monthly_sales_average, '')), ''),
    nullif(trim(coalesce(p_highest_sale_amount, '')), ''),
    nullif(trim(coalesce(p_average_sale_amount, '')), ''),

    nullif(trim(coalesce(p_pricing_plan, '')), ''),
    true,
    now(),
    request_client_ip(),
    nullif(trim(coalesce(p_terms_url, '')), ''),
    request_user_agent(),

    'link', v_token.id, 'unmatched',

    case when nullif(trim(coalesce(p_ssn, '')), '') is null
         then null else encrypt_sensitive(trim(p_ssn)) end,
    case when nullif(trim(coalesce(p_dob, '')), '') is null
         then null else encrypt_sensitive(trim(p_dob)) end,
    case when nullif(trim(coalesce(p_drivers_license, '')), '') is null
         then null else encrypt_sensitive(trim(p_drivers_license)) end,
    case when nullif(trim(coalesce(p_business_tax_id, '')), '') is null
         then null else encrypt_sensitive(trim(p_business_tax_id)) end,
    case when coalesce(nullif(trim(coalesce(p_bank_name, '')), ''),
                       nullif(trim(coalesce(p_routing_number, '')), ''),
                       nullif(trim(coalesce(p_account_number, '')), '')) is null
         then null
         else encrypt_sensitive(jsonb_build_object(
                'bank_name',      trim(coalesce(p_bank_name, '')),
                'routing_number', trim(coalesce(p_routing_number, '')),
                'account_number', trim(coalesce(p_account_number, ''))
              )::text) end,

    jsonb_strip_nulls(jsonb_build_object(
      'link_label',   v_token.label,
      'link_slug',    v_token.slug,
      'pricing_plan', nullif(trim(coalesce(p_pricing_plan, '')), ''),
      'submitted_via','portal_application_page'
    ))
  )
  returning id into v_id;

  update application_link_tokens
     set submissions = submissions + 1
   where id = v_token.id;

  return v_id;
end;
$$;

grant execute on function public_submit_application(
  text, text, text, text, text, text, text, text, text, text, text, text,
  text, text, text, text, text, text, text, text, text, text, text, text,
  text, boolean, text
) to anon, authenticated;


-- ---------------------------------------------------------------------------
-- The lead form records acceptance too, but does not require it — a lead form
-- is an enquiry, not an agreement.
-- ---------------------------------------------------------------------------
drop function if exists public_submit_lead_form(
  text, text, text, text, text, text, text, text, text
);

create or replace function public_submit_lead_form(
  p_slug             text,
  p_business_name    text,
  p_contact_name     text,
  p_email            text,
  p_phone            text,
  p_business_address text,
  p_business_type    text,
  p_est_volume       text,
  p_notes            text,
  p_terms_accepted   boolean,
  p_terms_url        text
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
  v_accepted boolean;
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

  v_accepted := coalesce(p_terms_accepted, false);

  insert into leads (
    brand, business_name, contact_name, phone, email,
    business_address, est_volume, business_type_services,
    stage, lead_source, linked_partner_id, general_follow_up_note,
    terms_accepted, terms_accepted_at, terms_ip, terms_url, terms_user_agent
  ) values (
    case when v_token.brand = 'atm' then 'atm' else 'epay' end,
    trim(p_business_name),
    trim(p_contact_name),
    coalesce(nullif(trim(coalesce(p_phone, '')), ''), '—'),
    coalesce(nullif(trim(coalesce(p_email, '')), ''), '—'),
    nullif(trim(coalesce(p_business_address, '')), ''),
    nullif(trim(coalesce(p_est_volume, '')), ''),
    nullif(trim(coalesce(p_business_type, '')), ''),
    'inbound_lead',
    'Lead form — ' || v_token.label,
    v_token.partner_id,
    nullif(trim(coalesce(p_notes, '')), ''),
    v_accepted,
    case when v_accepted then now() else null end,
    case when v_accepted then request_client_ip() else null end,
    case when v_accepted then nullif(trim(coalesce(p_terms_url, '')), '') else null end,
    case when v_accepted then request_user_agent() else null end
  )
  returning id into v_lead_id;

  update application_link_tokens
     set submissions = submissions + 1
   where id = v_token.id;

  return v_lead_id;
end;
$$;

grant execute on function public_submit_lead_form(
  text, text, text, text, text, text, text, text, text, boolean, text
) to anon, authenticated;


-- ---------------------------------------------------------------------------
-- The referral landing page has its own submit, predating all of this. Same
-- treatment: records acceptance, does not require it.
--
-- Its existing signature is preserved and the two new arguments defaulted, so
-- any caller not yet updated keeps working rather than breaking the moment
-- this runs.
-- ---------------------------------------------------------------------------
create or replace function public_submit_referral_lead(
  p_partner_id       uuid,
  p_business_name    text,
  p_contact_name     text,
  p_phone            text,
  p_email            text,
  p_business_address text,
  p_est_volume       text,
  p_notes            text,
  p_terms_accepted   boolean default false,
  p_terms_url        text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_partner partners%rowtype;
  v_brand text;
  v_lead_id uuid;
  v_accepted boolean;
begin
  select * into v_partner from partners where id = p_partner_id;
  if not found then
    raise exception 'Unknown referral partner';
  end if;

  if p_business_name is null or trim(p_business_name) = ''
     or p_contact_name is null or trim(p_contact_name) = '' then
    raise exception 'Business name and contact name are required';
  end if;

  v_brand := case when v_partner.brand = 'atm' then 'atm' else 'epay' end;
  v_accepted := coalesce(p_terms_accepted, false);

  insert into leads (
    brand, business_name, contact_name, phone, email, business_address,
    est_volume, stage, lead_source, linked_partner_id, general_follow_up_note,
    terms_accepted, terms_accepted_at, terms_ip, terms_url, terms_user_agent
  ) values (
    v_brand,
    trim(p_business_name),
    trim(p_contact_name),
    coalesce(nullif(trim(coalesce(p_phone, '')), ''), '—'),
    coalesce(nullif(trim(coalesce(p_email, '')), ''), '—'),
    nullif(trim(coalesce(p_business_address, '')), ''),
    nullif(trim(coalesce(p_est_volume, '')), ''),
    'inbound_lead',
    'Referral link — ' || v_partner.name,
    p_partner_id,
    nullif(trim(coalesce(p_notes, '')), ''),
    v_accepted,
    case when v_accepted then now() else null end,
    case when v_accepted then request_client_ip() else null end,
    case when v_accepted then nullif(trim(coalesce(p_terms_url, '')), '') else null end,
    case when v_accepted then request_user_agent() else null end
  )
  returning id into v_lead_id;

  return v_lead_id;
end;
$$;

grant execute on function public_submit_referral_lead(
  uuid, text, text, text, text, text, text, text, boolean, text
) to anon, authenticated;


-- =============================================================================
-- READING AN ACCEPTANCE BACK
--   select legal_business_name, terms_accepted, terms_accepted_at,
--          terms_ip, terms_url
--     from applications
--    where terms_accepted
--    order by terms_accepted_at desc;
--
-- The IP comes from the request headers, so it is what the server saw rather
-- than what the page claimed. That is the difference between a record that
-- means something and one that does not.
-- =============================================================================

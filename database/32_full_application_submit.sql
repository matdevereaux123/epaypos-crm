-- =============================================================================
-- EPAY POS / Envision ATM Control Center — the full merchant application
-- ---------------------------------------------------------------------------
-- Run after 31_fix_application_submit.sql.
--
-- The landing page collected a handful of fields; the real form at
-- epaypos.net/copy-of-free-processing asks for the whole merchant
-- application. This takes all of it.
--
-- THE PART THAT MATTERS: that form collects a social security number, a date
-- of birth, a driver's licence and a bank account. This function is callable
-- by `anon` — it has to be, the applicant is not logged in — so those values
-- go through encrypt_sensitive() into the bytea columns, exactly like every
-- other sensitive field in this system. They are NEVER written to
-- raw_payload, which is plain jsonb and readable by anyone who can read the
-- table.
--
-- raw_payload keeps only the non-sensitive answers, as an audit of what was
-- actually submitted.
-- =============================================================================

-- Different argument list means a new overload rather than a replacement, so
-- the old signatures have to go or PostgREST cannot choose between them.
drop function if exists public_submit_application(
  text, text, text, text, text, text, text, text, text, text, text
);

create or replace function public_submit_application(
  p_slug                   text,
  -- applicant
  p_first_name             text,
  p_last_name              text,
  p_email                  text,
  p_phone                  text,
  p_dob                    text,
  p_ssn                    text,
  p_drivers_license        text,
  p_drivers_license_state  text,
  -- business
  p_legal_business_name    text,
  p_dba_name               text,
  p_business_address       text,
  p_business_email         text,
  p_business_phone         text,
  p_business_start_date    text,
  p_business_tax_id        text,
  p_business_type          text,
  p_business_type_services text,
  -- volumes
  p_monthly_sales_average  text,
  p_highest_sale_amount    text,
  p_average_sale_amount    text,
  -- banking
  p_bank_name              text,
  p_routing_number         text,
  p_account_number         text,
  -- terms
  p_pricing_plan           text,
  p_terms_accepted         boolean
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

  if p_legal_business_name is null or trim(p_legal_business_name) = ''
     or p_first_name is null or trim(p_first_name) = ''
     or p_last_name is null or trim(p_last_name) = '' then
    raise exception 'Business name and your name are required';
  end if;

  -- A browser date input gives yyyy-mm-dd; anything else is left null rather
  -- than failing the whole submission over a formatting difference.
  begin
    v_start := nullif(trim(coalesce(p_business_start_date, '')), '')::date;
  exception when others then
    v_start := null;
  end;

  insert into applications (
    -- legacy display columns the Applications list reads
    business_name, contact_name, email, phone,
    -- applicant
    first_name, last_name, drivers_license_state,
    -- business
    legal_business_name, dba_name, business_address, business_email,
    business_phone, business_start_date, business_type, business_type_services,
    -- volumes
    monthly_sales_average, highest_sale_amount, average_sale_amount,
    -- terms
    pricing_plan, terms_accepted,
    -- provenance
    source, link_token_id, match_status,
    -- encrypted
    ssn, dob, drivers_license, business_tax_id, banking,
    raw_payload
  ) values (
    trim(p_legal_business_name),
    trim(p_first_name) || ' ' || trim(p_last_name),
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
    coalesce(p_terms_accepted, false),

    'link', v_token.id, 'unmatched',

    -- Encrypted, never plain. A blank answer stays null rather than storing
    -- ciphertext of an empty string, so "nothing on file" reads as null.
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

    -- Non-sensitive answers only. SSN, DOB, licence, tax ID and banking are
    -- deliberately absent — raw_payload is plain jsonb.
    jsonb_strip_nulls(jsonb_build_object(
      'link_label',  v_token.label,
      'link_slug',   v_token.slug,
      'pricing_plan', nullif(trim(coalesce(p_pricing_plan, '')), ''),
      'submitted_via', 'portal_application_page'
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
  text, boolean
) to anon, authenticated;


-- =============================================================================
-- AFTER RUNNING THIS
--   Submit the form once and confirm in the Applications tab that the record
--   arrives with the business and contact details filled in. Then check that
--   ssn, dob, drivers_license, business_tax_id and banking are bytea and that
--   raw_payload contains none of them:
--
--     select raw_payload, ssn is not null as has_ssn
--       from applications order by submitted_at desc limit 1;
-- =============================================================================

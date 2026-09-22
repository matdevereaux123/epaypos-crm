-- =============================================================================
-- EPAY POS / Envision ATM Control Center — auto-assign applications
-- ---------------------------------------------------------------------------
-- Run after 58_inhouse_sees_form_leads_and_merge_reseller.sql.
--
-- applications.assigned_to and its RLS (applications_select/update, scoped
-- to assigned_to = you) have existed since 15_assignment_access.sql — an
-- agent or ISO could already be handed an application and see it in their
-- portal. What was missing: nothing ever set assigned_to automatically, and
-- the app's own applications SELECT never even asked Supabase for the
-- column, so the field was invisible even when a staff member set it by
-- hand (fixed in app/index.html alongside this file).
--
-- This covers the "automatically" half of the request:
--
--   created the application link      assigned_to = that link's creator,
--                                      when the creator is a portal user
--                                      (agent, ISO, referral partner) —
--                                      never a staff member, so a generic
--                                      staff-made link does not quietly
--                                      "belong" to whichever employee
--                                      happened to set it up
--
--   entered it by hand                already possible: the "New
--                                      application" / "Upload paper
--                                      application" forms now have their
--                                      own Assign to field (app/index.html)
-- =============================================================================

drop function if exists public_submit_application(
  text, text, text, text, text, text, text, text, text, text, text, text,
  text, text, text, text, text, text, text, text, text, text, text, text,
  text, boolean, text
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
  v_assigned_to uuid;
begin
  select * into v_token from application_link_tokens
   where slug = p_slug and is_active = true;

  if not found then
    raise exception 'This application link is no longer active';
  end if;

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

  -- Credit the link's creator only if they are a portal user (agent, ISO,
  -- referral partner) — a link a staff member set up for general use is not
  -- "theirs" just because they clicked Create.
  if v_token.created_by is not null then
    select v_token.created_by into v_assigned_to
      from users u
      join roles r on r.key = u.role
     where u.id = v_token.created_by
       and r.portal_scope = 'own';
  end if;

  insert into applications (
    email, phone,
    first_name, last_name, drivers_license_state,
    legal_business_name, dba_name, business_address, business_email,
    business_phone, business_start_date, business_type, business_type_services,
    monthly_sales_average, highest_sale_amount, average_sale_amount,
    pricing_plan, terms_accepted,
    terms_accepted_at, terms_ip, terms_url, terms_user_agent,
    source, link_token_id, match_status, assigned_to,
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

    'link', v_token.id, 'unmatched', v_assigned_to,

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

-- =============================================================================
-- AFTER RUNNING THIS
--   As an agent, create an application link for yourself (or have staff
--   create one and set its creator to you), submit a test application
--   through it, and confirm it shows up under that agent's own
--   Applications tab — and nobody else's.
--
--   For the "did it by hand" half: as staff, use New Application (or
--   Upload Paper Application), pick an agent under "Assign to", save, and
--   confirm the same thing from that agent's side.
-- =============================================================================

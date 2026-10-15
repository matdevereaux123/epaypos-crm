-- =============================================================================
-- EPAY POS / Envision ATM Control Center — fix public_submit_application
-- ---------------------------------------------------------------------------
-- Run after 30_encrypt_lead_dob.sql. Safe to run twice.
--
-- BUG: public_submit_application (28_application_links.sql) inserts into
-- applications.business_name and applications.contact_name. Migration 06
-- dropped both of those columns and replaced them with legal_business_name,
-- first_name and last_name. So every real submission through an application
-- link would have failed on insert.
--
-- It was not caught earlier because the only test used a slug that does not
-- exist, and the function raises "This application link is no longer active"
-- before it ever reaches the insert. The happy path was never exercised.
--
-- Also splits the contact into first and last name, which is the shape the
-- Applications table and its drawer already use.
-- =============================================================================

create or replace function public_submit_application(
  p_slug              text,
  p_business_name     text,
  p_contact_name      text,
  p_email             text,
  p_phone             text,
  p_business_address  text,
  p_business_type     text,
  p_monthly_volume    text,
  p_average_ticket    text,
  p_current_processor text,
  p_notes             text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_token application_link_tokens%rowtype;
  v_id uuid;
  v_contact text;
  v_first text;
  v_last text;
begin
  select * into v_token from application_link_tokens
   where slug = p_slug and is_active = true;

  if not found then
    raise exception 'This application link is no longer active';
  end if;

  if p_business_name is null or trim(p_business_name) = ''
     or p_contact_name is null or trim(p_contact_name) = '' then
    raise exception 'Business name and contact name are required';
  end if;

  -- The form asks for one name; the table stores two. Everything before the
  -- first space is the first name, the remainder is the last — and a
  -- single-word answer lands entirely in first_name rather than producing an
  -- empty last name that reads as missing data.
  v_contact := trim(p_contact_name);
  if position(' ' in v_contact) > 0 then
    v_first := split_part(v_contact, ' ', 1);
    v_last  := trim(substring(v_contact from position(' ' in v_contact) + 1));
  else
    v_first := v_contact;
    v_last  := null;
  end if;

  insert into applications (
    first_name, last_name, legal_business_name,
    email, phone, business_address,
    business_type_services,
    source, link_token_id, raw_payload
  ) values (
    v_first,
    v_last,
    trim(p_business_name),
    nullif(trim(coalesce(p_email, '')), ''),
    nullif(trim(coalesce(p_phone, '')), ''),
    nullif(trim(coalesce(p_business_address, '')), ''),
    nullif(trim(coalesce(p_business_type, '')), ''),
    'link',
    v_token.id,
    -- Everything is kept here as well, the way the Wix intake does it, so a
    -- later change to the form loses nothing that was already collected.
    jsonb_strip_nulls(jsonb_build_object(
      'business_name',     trim(p_business_name),
      'contact_name',      v_contact,
      'business_address',  nullif(trim(coalesce(p_business_address, '')), ''),
      'business_type',     nullif(trim(coalesce(p_business_type, '')), ''),
      'monthly_volume',    nullif(trim(coalesce(p_monthly_volume, '')), ''),
      'average_ticket',    nullif(trim(coalesce(p_average_ticket, '')), ''),
      'current_processor', nullif(trim(coalesce(p_current_processor, '')), ''),
      'notes',             nullif(trim(coalesce(p_notes, '')), ''),
      'link_label',        v_token.label,
      'link_slug',         v_token.slug
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
  text, text, text, text, text, text, text, text, text, text, text
) to anon, authenticated;


-- =============================================================================
-- AFTER RUNNING THIS
--   Create a link in the CRM, open it, and actually submit the form. The row
--   must appear under Applications with the business and contact names filled
--   in. That is the path that was broken, and only a real submission proves
--   it works — an invalid slug fails earlier and tells you nothing.
-- =============================================================================

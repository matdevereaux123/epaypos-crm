-- =============================================================================
-- EPAY POS / Envision ATM Control Center — taxpayer ID choice + 1099 address
-- ---------------------------------------------------------------------------
-- Run after 22_users_office.sql.
--
-- Two things the onboarding form needs for 1099 reporting:
--
-- 1. An agent files under EITHER an SSN or an EIN, not both — a sole
--    proprietor uses their SSN, an LLC or corporation uses its EIN. The
--    columns for both already exist; what was missing is a record of which
--    one is the taxpayer ID, so nothing downstream has to guess by checking
--    which column happens to be populated.
--
-- 2. A mailing address, which is frequently neither the home address nor the
--    business address — a PO box or an accountant's office is common. The
--    1099 goes here.
-- =============================================================================

alter table partners
  add column if not exists tax_id_type text check (tax_id_type in ('ssn', 'ein')),
  add column if not exists mailing_address text;


-- ---------------------------------------------------------------------------
-- submit_partner_onboarding gains two parameters. Postgres treats a different
-- argument list as a separate overload rather than a replacement, so the old
-- signature is dropped first — otherwise both would exist and PostgREST would
-- have to pick one.
-- ---------------------------------------------------------------------------
drop function if exists submit_partner_onboarding(
  uuid, text, text, text, text, text, text, text, text, date, text, text, text, text, text, text, text, text
);

create or replace function submit_partner_onboarding(
  p_partner_id             uuid,
  p_owner_first_name       text,
  p_owner_last_name        text,
  p_drivers_license_state  text,
  p_legal_business_name    text,
  p_dba_name               text,
  p_business_address       text,
  p_business_phone         text,
  p_business_email         text,
  p_business_start_date    date,
  p_business_type_services text,
  p_personal_address       text,
  p_mailing_address        text,
  p_tax_id_type            text,
  p_phone                  text,
  p_website                text,
  p_address                text,
  p_city                   text,
  p_state                  text,
  p_zip                    text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
begin
  if not coalesce(
       current_partner_is_own(p_partner_id)
       or current_app_has_perm('editPartners'),
       false
     ) then
    raise exception 'Not authorized to submit this application';
  end if;

  if p_tax_id_type is not null and p_tax_id_type not in ('ssn','ein') then
    raise exception 'Taxpayer ID type must be ssn or ein';
  end if;

  select onboarding_status into v_status from partners where id = p_partner_id;
  if v_status is null then
    raise exception 'No such partner';
  end if;

  if v_status not in ('invited','submitted') and not current_app_has_perm('editPartners') then
    raise exception 'This application is not open for editing';
  end if;

  update partners set
    owner_first_name       = p_owner_first_name,
    owner_last_name        = p_owner_last_name,
    drivers_license_state  = p_drivers_license_state,
    legal_business_name    = p_legal_business_name,
    dba_name               = p_dba_name,
    business_address       = p_business_address,
    business_phone         = p_business_phone,
    business_email         = p_business_email,
    business_start_date    = p_business_start_date,
    business_type_services = p_business_type_services,
    personal_address       = p_personal_address,
    mailing_address        = p_mailing_address,
    tax_id_type            = coalesce(p_tax_id_type, tax_id_type),
    phone                  = coalesce(p_phone, phone),
    website                = coalesce(p_website, website),
    address                = coalesce(p_address, address),
    city                   = coalesce(p_city, city),
    state                  = coalesce(p_state, state),
    zip                    = coalesce(p_zip, zip),
    onboarding_status      = 'submitted',
    onboarding_submitted_at = coalesce(onboarding_submitted_at, now())
  where id = p_partner_id;
end;
$$;

revoke execute on function submit_partner_onboarding(
  uuid, text, text, text, text, text, text, text, text, date, text, text, text, text, text, text, text, text, text, text
) from public;
revoke execute on function submit_partner_onboarding(
  uuid, text, text, text, text, text, text, text, text, date, text, text, text, text, text, text, text, text, text, text
) from anon;
grant execute on function submit_partner_onboarding(
  uuid, text, text, text, text, text, text, text, text, date, text, text, text, text, text, text, text, text, text, text
) to authenticated;

-- =============================================================================
-- AFTER RUNNING THIS
--   Called with only the anon key, submit_partner_onboarding must return 401.
--   Anything else means the revokes did not take — see 20_revoke_anon_onboarding
--   for why revoking from public alone is not enough on Supabase.
-- =============================================================================

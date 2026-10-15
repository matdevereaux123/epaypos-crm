-- =============================================================================
-- EPAY POS / Envision ATM Control Center — agent submits their own onboarding
-- ---------------------------------------------------------------------------
-- Run after 18_revoke_public_execute.sql.
--
-- Why this needs an RPC at all: the partners_write policy in 04_rls.sql
-- requires editPartners, which no portal role has. An agent therefore cannot
-- update their own partner row at all — correct as a default, but it leaves
-- self-service onboarding with no way to save.
--
-- Widening partners_write for portal roles would be the wrong fix: it would
-- also let an agent edit their own residual_percentage, status, type,
-- parent_partner_id and referral slug. This function writes an explicit list
-- of application columns and nothing else, so the set of fields an agent can
-- change is visible here rather than implied by a policy.
--
-- Sensitive fields are NOT handled here — SSN, DOB, driver's licence and tax
-- ID go through set_partner_sensitive(), and payout banking through
-- set_partner_banking(), both already fixed to fail closed in 17.
-- =============================================================================

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
  -- Either the record's own portal login, or someone internal filling it in
  -- on their behalf.
  if not coalesce(
       current_partner_is_own(p_partner_id)
       or current_app_has_perm('editPartners'),
       false
     ) then
    raise exception 'Not authorized to submit this application';
  end if;

  select onboarding_status into v_status from partners where id = p_partner_id;

  if v_status is null then
    raise exception 'No such partner';
  end if;

  -- An agent may fill the form in while invited, and may correct it while it
  -- is still awaiting review. Once approved it is closed to them; changes
  -- after that go through someone internal.
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
  uuid, text, text, text, text, text, text, text, text, date, text, text, text, text, text, text, text, text
) from public;

grant execute on function submit_partner_onboarding(
  uuid, text, text, text, text, text, text, text, text, date, text, text, text, text, text, text, text, text
) to authenticated;


-- ---------------------------------------------------------------------------
-- What the portal needs to read to decide whether to show the banner.
-- The agent can already select their own partners row under 04_rls.sql, so
-- this exists purely so the app can ask the question in one call without
-- pulling the whole record.
-- ---------------------------------------------------------------------------
create or replace function my_onboarding_status()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select jsonb_build_object(
       'partner_id', p.id,
       'status',     p.onboarding_status,
       'name',       p.name
     )
     from users u
     join partners p on p.id = u.linked_partner_id
     where u.auth_id = auth.uid()),
    '{}'::jsonb
  );
$$;

revoke execute on function my_onboarding_status() from public;
grant execute on function my_onboarding_status() to authenticated;


-- =============================================================================
-- AFTER RUNNING THIS
--   Called with only the anon key, both functions must come back 401.
--   The real test is Phase 7: log in as an invited agent, complete the form,
--   and confirm the row moves to 'submitted' while residual_percentage,
--   status and parent_partner_id are all untouched.
-- =============================================================================

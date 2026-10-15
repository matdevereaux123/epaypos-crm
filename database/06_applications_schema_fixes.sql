-- =============================================================================
-- EPAY POS / Envision ATM Control Center — applications schema alignment
-- ---------------------------------------------------------------------------
-- Found while converting the Applications collection to real Supabase calls
-- (Phase 4): 01_schema.sql's `applications` table was built as a minimal
-- generic shape (business_name/contact_name + a catch-all raw_payload jsonb
-- for "whatever Wix sends"), but the app's actual application form collects
-- ~20 specific fields — including the same sensitive ones as leads (SSN,
-- drivers license, tax ID, banking). This adds real columns matching the
-- app, and encrypts the sensitive ones the same way leads/partners already
-- are. `business_name`/`contact_name` are dropped since the app never used
-- them (legal_business_name/dba_name and first_name/last_name cover the
-- same ground more precisely). `raw_payload` is left alone — still useful
-- later for the real Wix webhook integration (Phase 6).
-- =============================================================================

alter table applications
  drop column if exists business_name,
  drop column if exists contact_name,
  add column if not exists first_name text,
  add column if not exists last_name text,
  add column if not exists business_type text,
  add column if not exists pricing_plan text,
  add column if not exists dob date,
  add column if not exists drivers_license_state text,
  add column if not exists legal_business_name text,
  add column if not exists dba_name text,
  add column if not exists business_address text,
  add column if not exists business_email text,
  add column if not exists business_phone text,
  add column if not exists business_start_date date,
  add column if not exists business_type_services text,
  add column if not exists highest_sale_amount text,
  add column if not exists average_sale_amount text,
  add column if not exists monthly_sales_average text,
  add column if not exists terms_accepted boolean not null default false,
  add column if not exists match_status text,
  add column if not exists ssn bytea,
  add column if not exists drivers_license bytea,
  add column if not exists business_tax_id bytea,
  add column if not exists banking bytea;

-- ---------------------------------------------------------------------------
-- Same reveal/set RPC pattern as database/02_encryption.sql — see that
-- file's comments for the full explanation of why these exist as functions
-- rather than direct column access.
-- ---------------------------------------------------------------------------
create or replace function reveal_application_ssn(p_application_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result text;
begin
  if not current_user_can_view_sensitive() then
    raise exception 'Not authorized to view this field';
  end if;
  select decrypt_sensitive(ssn) into v_result from applications where id = p_application_id;
  return v_result;
end;
$$;

create or replace function reveal_application_drivers_license(p_application_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result text;
begin
  if not current_user_can_view_sensitive() then
    raise exception 'Not authorized to view this field';
  end if;
  select decrypt_sensitive(drivers_license) into v_result from applications where id = p_application_id;
  return v_result;
end;
$$;

create or replace function reveal_application_tax_id(p_application_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result text;
begin
  if not current_user_can_view_sensitive() then
    raise exception 'Not authorized to view this field';
  end if;
  select decrypt_sensitive(business_tax_id) into v_result from applications where id = p_application_id;
  return v_result;
end;
$$;

create or replace function reveal_application_banking(p_application_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result text;
begin
  if not current_user_can_view_sensitive() then
    raise exception 'Not authorized to view this field';
  end if;
  select decrypt_sensitive(banking) into v_result from applications where id = p_application_id;
  return v_result;
end;
$$;

grant execute on function reveal_application_ssn(uuid) to authenticated;
grant execute on function reveal_application_drivers_license(uuid) to authenticated;
grant execute on function reveal_application_tax_id(uuid) to authenticated;
grant execute on function reveal_application_banking(uuid) to authenticated;

create or replace function set_application_ssn(p_application_id uuid, p_value text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce((select (r.perms->>'editBanking')::boolean
               from users u join roles r on r.key = u.role
               where u.auth_id = auth.uid()), false) is not true then
    raise exception 'Not authorized to edit this field';
  end if;
  update applications set ssn = encrypt_sensitive(p_value) where id = p_application_id;
end;
$$;

create or replace function set_application_drivers_license(p_application_id uuid, p_value text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce((select (r.perms->>'editBanking')::boolean
               from users u join roles r on r.key = u.role
               where u.auth_id = auth.uid()), false) is not true then
    raise exception 'Not authorized to edit this field';
  end if;
  update applications set drivers_license = encrypt_sensitive(p_value) where id = p_application_id;
end;
$$;

create or replace function set_application_tax_id(p_application_id uuid, p_value text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce((select (r.perms->>'editBanking')::boolean
               from users u join roles r on r.key = u.role
               where u.auth_id = auth.uid()), false) is not true then
    raise exception 'Not authorized to edit this field';
  end if;
  update applications set business_tax_id = encrypt_sensitive(p_value) where id = p_application_id;
end;
$$;

create or replace function set_application_banking(p_application_id uuid, p_banking text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce((select (r.perms->>'editBanking')::boolean
               from users u join roles r on r.key = u.role
               where u.auth_id = auth.uid()), false) is not true then
    raise exception 'Not authorized to edit this field';
  end if;
  update applications set banking = encrypt_sensitive(p_banking) where id = p_application_id;
end;
$$;

grant execute on function set_application_ssn(uuid, text) to authenticated;
grant execute on function set_application_drivers_license(uuid, text) to authenticated;
grant execute on function set_application_tax_id(uuid, text) to authenticated;
grant execute on function set_application_banking(uuid, text) to authenticated;

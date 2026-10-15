-- =============================================================================
-- EPAY POS / Envision ATM Control Center — encrypt the remaining dates of birth
-- ---------------------------------------------------------------------------
-- Run after 29_outbound_email.sql. Safe to run twice.
--
-- TWO plaintext columns, not one: leads.dob and applications.dob. The
-- applications table has its own sensitive set/reveal RPCs from
-- 06_applications_schema_fixes.sql and the same omission — dob was declared
-- `date` while ssn, drivers_license, business_tax_id and banking were all
-- bytea.
--
-- 25 converted leads.ssn,
-- drivers_license and business_tax_id but deliberately left dob alone,
-- because unlike those three it had no set_/reveal_ RPC and the app wrote it
-- straight onto the row — converting it then would have broken saving a lead
-- with nothing to replace the write path.
--
-- This adds the missing pair first, then converts, in that order, so the
-- column is never unwritable.
--
-- partners.dob has been encrypted since 16_agent_onboarding.sql created it as
-- bytea, so after this the two tables finally agree.
--
-- Note the type change: dob was a `date`, not text like the others, so
-- existing values are cast to text before encrypting. They come back out of
-- reveal_lead_dob() as 'YYYY-MM-DD' strings, which is what the date input in
-- the drawer expects.
-- =============================================================================


create or replace function reveal_lead_dob(p_lead_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_result text;
begin
  if not current_user_can_view_sensitive() then
    raise exception 'Not authorized to view this field';
  end if;
  select decrypt_sensitive(dob) into v_result from leads where id = p_lead_id;
  return v_result;
end;
$$;

revoke execute on function reveal_lead_dob(uuid) from public;
revoke execute on function reveal_lead_dob(uuid) from anon;
grant execute on function reveal_lead_dob(uuid) to authenticated;


create or replace function set_lead_dob(p_lead_id uuid, p_value text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Same guard the other lead setters use. current_user_can_edit_sensitive()
  -- does not exist — only the view-side helper does — so this matches
  -- set_lead_ssn rather than inventing a helper.
  if coalesce((select (r.perms->>'editBanking')::boolean
               from users u join roles r on r.key = u.role
               where u.auth_id = auth.uid()), false) is not true then
    raise exception 'Not authorized to edit this field';
  end if;
  -- Empty means "clear it" rather than "store an empty string", so a lead
  -- whose date of birth is removed ends up null and reads as not-on-file.
  update leads
     set dob = case when p_value is null or trim(p_value) = ''
                    then null
                    else encrypt_sensitive(p_value) end
   where id = p_lead_id;
end;
$$;

revoke execute on function set_lead_dob(uuid, text) from public;
revoke execute on function set_lead_dob(uuid, text) from anon;
grant execute on function set_lead_dob(uuid, text) to authenticated;


create or replace function reveal_application_dob(p_application_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_result text;
begin
  if not current_user_can_view_sensitive() then
    raise exception 'Not authorized to view this field';
  end if;
  select decrypt_sensitive(dob) into v_result from applications where id = p_application_id;
  return v_result;
end;
$$;

revoke execute on function reveal_application_dob(uuid) from public;
revoke execute on function reveal_application_dob(uuid) from anon;
grant execute on function reveal_application_dob(uuid) to authenticated;


create or replace function set_application_dob(p_application_id uuid, p_value text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Matches the guard on set_application_ssn in 06.
  if coalesce((select (r.perms->>'editBanking')::boolean
               from users u join roles r on r.key = u.role
               where u.auth_id = auth.uid()), false) is not true then
    raise exception 'Not authorized to edit this field';
  end if;
  update applications
     set dob = case when p_value is null or trim(p_value) = ''
                    then null
                    else encrypt_sensitive(p_value) end
   where id = p_application_id;
end;
$$;

revoke execute on function set_application_dob(uuid, text) from public;
revoke execute on function set_application_dob(uuid, text) from anon;
grant execute on function set_application_dob(uuid, text) to authenticated;


-- ---------------------------------------------------------------------------
-- Now the column, once the functions that maintain it exist.
-- ---------------------------------------------------------------------------
do $$
declare
  v_type text;
  v_count integer;
begin
  select data_type into v_type
    from information_schema.columns
   where table_schema = 'public' and table_name = 'leads' and column_name = 'dob';

  if v_type is null then
    raise notice 'leads.dob does not exist — nothing to do';
  elsif v_type = 'bytea' then
    raise notice 'leads.dob is already bytea — nothing to do';
  else
    raise notice 'leads.dob is % — converting to bytea', v_type;

    alter table leads add column if not exists dob_enc bytea;
    -- ::text on a date gives YYYY-MM-DD, which is what the drawer's date
    -- input reads back.
    update leads set dob_enc = encrypt_sensitive(dob::text) where dob is not null;
    get diagnostics v_count = row_count;
    raise notice '  encrypted % existing date(s) of birth', v_count;

    alter table leads drop column dob;
    alter table leads rename column dob_enc to dob;
    raise notice '  leads.dob is now bytea';
  end if;

  -- ---------------- applications.dob ----------------
  select data_type into v_type
    from information_schema.columns
   where table_schema = 'public' and table_name = 'applications' and column_name = 'dob';

  if v_type is null then
    raise notice 'applications.dob does not exist — nothing to do';
  elsif v_type = 'bytea' then
    raise notice 'applications.dob is already bytea — nothing to do';
  else
    raise notice 'applications.dob is % — converting to bytea', v_type;

    alter table applications add column if not exists dob_enc bytea;
    update applications set dob_enc = encrypt_sensitive(dob::text) where dob is not null;
    get diagnostics v_count = row_count;
    raise notice '  encrypted % existing date(s) of birth', v_count;

    alter table applications drop column dob;
    alter table applications rename column dob_enc to dob;
    raise notice '  applications.dob is now bytea';
  end if;
end $$;


-- =============================================================================
-- REPORT — every sensitive column across both tables. All should now read
-- ENCRYPTED.
-- =============================================================================
select
  table_name,
  column_name,
  data_type,
  case when data_type = 'bytea' then 'ENCRYPTED' else 'PLAINTEXT' end as status
from information_schema.columns
where table_schema = 'public'
  and (
    (table_name = 'leads'        and column_name in ('ssn','dob','drivers_license','business_tax_id','banking'))
    or (table_name = 'partners'     and column_name in ('ssn','dob','drivers_license','tax_id','banking'))
    or (table_name = 'applications' and column_name in ('ssn','dob','drivers_license','business_tax_id','banking'))
  )
order by
  case when data_type = 'bytea' then 1 else 0 end,
  table_name, column_name;

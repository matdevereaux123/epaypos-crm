-- =============================================================================
-- EPAY POS / Envision ATM Control Center — encrypt the lead sensitive columns
-- ---------------------------------------------------------------------------
-- Run after 24_fix_banking_encryption.sql.
--
-- 24's report showed leads.ssn and leads.drivers_license still holding text,
-- and leads.business_tax_id is in the same state (24's report did not name it,
-- because the column is business_tax_id rather than tax_id). These are the
-- merchant SSNs — the most sensitive data in the system — sitting in plaintext.
--
-- Why 02_encryption.sql did not achieve this: its Step 2 DROPS and re-adds
-- those columns, which is fine on a fresh database and destroys data on one
-- already in use. This file converts in place and encrypts what is there.
--
-- The app already reads and writes all three through RPCs — set_lead_ssn,
-- set_lead_drivers_license, set_lead_tax_id and their reveal_ counterparts —
-- so nothing in the UI needs changing. Reading the raw column returns base64
-- rather than a value, which the "something is on file" checks still treat as
-- present.
--
-- DELIBERATELY NOT TOUCHING leads.dob. It has no set_/reveal_ RPC, the app
-- writes it directly (fields.dob = dobInput.value), and 02's ALTER never
-- included it despite its comment mentioning DOB. Converting it here would
-- break saving a lead with no code to replace it. See the note at the end.
-- =============================================================================

do $$
declare
  v_type  text;
  v_count integer;
  c       text;
begin
  foreach c in array array['ssn','drivers_license','business_tax_id']
  loop
    select data_type into v_type
      from information_schema.columns
     where table_schema = 'public' and table_name = 'leads' and column_name = c;

    if v_type is null then
      raise notice 'leads.% does not exist — skipping', c;
    elsif v_type = 'bytea' then
      raise notice 'leads.% is already bytea — skipping', c;
    else
      raise notice 'leads.% is % — converting to bytea', c, v_type;

      execute format('alter table leads add column if not exists %I_enc bytea', c);
      execute format(
        'update leads set %I_enc = encrypt_sensitive(%I::text) where %I is not null', c, c, c);
      get diagnostics v_count = row_count;
      raise notice '  encrypted % existing value(s)', v_count;

      execute format('alter table leads drop column %I', c);
      execute format('alter table leads rename column %I_enc to %I', c, c);
      raise notice '  leads.% is now bytea', c;
    end if;
  end loop;
end $$;


-- =============================================================================
-- REPORT — anything not bytea is still readable in the database.
-- =============================================================================
select
  table_name,
  column_name,
  data_type,
  case when data_type = 'bytea' then 'ENCRYPTED' else 'PLAINTEXT' end as status
from information_schema.columns
where table_schema = 'public'
  and (
    (table_name = 'leads'    and column_name in ('ssn','dob','drivers_license','business_tax_id','banking'))
    or (table_name = 'partners' and column_name in ('ssn','dob','drivers_license','tax_id','banking'))
  )
order by
  case when data_type = 'bytea' then 1 else 0 end,
  table_name, column_name;


-- =============================================================================
-- ABOUT leads.dob
--
-- It will still show as PLAINTEXT above, and that is deliberate rather than an
-- oversight. Encrypting it needs three things that do not exist yet:
--
--   1. set_lead_dob() / reveal_lead_dob() RPCs, matching the other three
--   2. the app changed to call them instead of writing fields.dob directly
--   3. this same in-place conversion for the column
--
-- partners.dob IS encrypted, because 16_agent_onboarding.sql created it as
-- bytea and the onboarding form writes it through set_partner_sensitive().
-- So the two tables genuinely differ today.
--
-- A date of birth on its own is less exposing than an SSN, which is why this
-- is worth doing deliberately rather than rushing. Say the word and it is a
-- short follow-up.
-- =============================================================================

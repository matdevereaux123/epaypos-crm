-- =============================================================================
-- EPAY POS / Envision ATM Control Center — finish the banking encryption
-- ---------------------------------------------------------------------------
-- Run after 23_taxid_and_mailing.sql.
--
-- 02_encryption.sql contains the right statements:
--
--   alter table leads    alter column banking type bytea using null;
--   alter table partners alter column banking type bytea using null;
--
-- but they never took effect on this database. partners.banking is still
-- jsonb, which surfaced when an agent submitted their onboarding application:
--
--   column "banking" is of type jsonb but expression is of type bytea
--
-- set_partner_banking() encrypts to bytea and assigns it to the column, so
-- against a jsonb column every write fails. Two consequences worth being
-- clear about: partner payout banking has never been encrypted, and nobody
-- has been able to save it through the RPC either.
--
-- This file checks the live type of each column rather than assuming, so it
-- is safe to run whatever state the database is actually in, and safe to run
-- twice.
--
-- Existing values are ENCRYPTED IN PLACE rather than dropped — 02 used
-- `using null`, which would have discarded them. Anything already stored is
-- carried across as ciphertext.
-- =============================================================================

do $$
declare
  v_type text;
  v_count integer;
begin
  -- ---------------- partners.banking ----------------
  select data_type into v_type
    from information_schema.columns
   where table_schema = 'public' and table_name = 'partners' and column_name = 'banking';

  if v_type is null then
    raise notice 'partners.banking does not exist — nothing to do';
  elsif v_type = 'bytea' then
    raise notice 'partners.banking is already bytea — nothing to do';
  else
    raise notice 'partners.banking is % — converting to bytea', v_type;

    alter table partners add column if not exists banking_enc bytea;

    -- Carry existing values across as ciphertext instead of discarding them.
    execute 'update partners set banking_enc = encrypt_sensitive(banking::text) where banking is not null';
    get diagnostics v_count = row_count;
    raise notice '  encrypted % existing partner banking value(s)', v_count;

    alter table partners drop column banking;
    alter table partners rename column banking_enc to banking;
    raise notice '  partners.banking is now bytea';
  end if;

  -- ---------------- leads.banking ----------------
  select data_type into v_type
    from information_schema.columns
   where table_schema = 'public' and table_name = 'leads' and column_name = 'banking';

  if v_type is null then
    raise notice 'leads.banking does not exist — nothing to do';
  elsif v_type = 'bytea' then
    raise notice 'leads.banking is already bytea — nothing to do';
  else
    raise notice 'leads.banking is % — converting to bytea', v_type;

    alter table leads add column if not exists banking_enc bytea;
    execute 'update leads set banking_enc = encrypt_sensitive(banking::text) where banking is not null';
    get diagnostics v_count = row_count;
    raise notice '  encrypted % existing lead banking value(s)', v_count;

    alter table leads drop column banking;
    alter table leads rename column banking_enc to banking;
    raise notice '  leads.banking is now bytea';
  end if;
end $$;


-- =============================================================================
-- REPORT: every sensitive column and whether it is actually encrypted.
-- Read this output. Anything that is not bytea is sitting in plaintext.
-- =============================================================================
select
  table_name,
  column_name,
  data_type,
  case when data_type = 'bytea' then 'ENCRYPTED' else 'PLAINTEXT — NEEDS FIXING' end as status
from information_schema.columns
where table_schema = 'public'
  and table_name in ('partners','leads')
  and column_name in ('banking','ssn','dob','drivers_license','tax_id')
order by
  case when data_type = 'bytea' then 1 else 0 end,
  table_name, column_name;

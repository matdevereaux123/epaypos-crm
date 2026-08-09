-- =============================================================================
-- EPAY POS / Envision ATM Control Center — sensitive data encryption
-- ---------------------------------------------------------------------------
-- This is an addendum to epaypos_crm_schema.sql, covering SSN, date of
-- birth, driver's license, business tax ID, and bank routing/account
-- numbers on both `leads` and `partners`.
--
-- Apply this BEFORE any real merchant data goes into the database. If
-- you've already run the base schema with no real data in it yet, run
-- this file next — no data migration needed. If real data somehow already
-- exists in plain text, stop and handle that migration separately rather
-- than running this as-is.
--
-- How it works, in plain terms:
--   - Sensitive columns are stored as `bytea` (encrypted bytes), not `text`.
--   - The encryption key lives in Supabase Vault — a secrets store built
--     into Supabase — never in application code, never in a config file
--     that could end up in version control.
--   - The app never talks to these columns directly. It calls a Postgres
--     function (an "RPC") that checks the logged-in user's role
--     permissions FIRST, and only decrypts and returns the value if
--     they're actually allowed to see it. This is what makes the eye-icon
--     reveal in the app real security instead of just a UI trick — the
--     enforcement happens on the server, where it can't be bypassed by
--     opening dev tools or editing the page.
-- =============================================================================

create extension if not exists pgcrypto;
-- Supabase Vault ships enabled on every project — this is just a safety net.
create extension if not exists supabase_vault;

-- ---------------------------------------------------------------------------
-- STEP 1 — Generate the key and store it in Vault. Run this once.
-- Generate a real secret locally first (don't use the placeholder below):
--   openssl rand -base64 32
-- Then run, with your real generated value pasted in:
-- ---------------------------------------------------------------------------
select vault.create_secret(
  'REPLACE_WITH_YOUR_OWN_GENERATED_SECRET',
  'crm_sensitive_data_key',
  'Symmetric key for encrypting SSN/DOB/DL/tax ID/bank fields on leads and partners'
);

-- ---------------------------------------------------------------------------
-- STEP 2 — Convert the sensitive columns to encrypted bytea. If you're
-- setting these tables up fresh (no data yet), drop and redefine the
-- columns directly:
-- ---------------------------------------------------------------------------
alter table leads
  drop column if exists ssn,
  drop column if exists drivers_license,
  drop column if exists business_tax_id,
  add column ssn                bytea,
  add column drivers_license    bytea,
  add column business_tax_id    bytea;

alter table leads
  alter column banking type bytea using null; -- see note below on banking

alter table partners
  alter column banking type bytea using null;

-- Banking info (bank_name, account_type, routing_number, account_number)
-- was a single JSONB column in the base schema. Two reasonable options:
--   (a) Encrypt the whole JSONB blob as one bytea value (simpler — what
--       this file does below), or
--   (b) Split routing_number/account_number out into their own bytea
--       columns and leave bank_name/account_type as plain JSONB, since
--       those two aren't sensitive on their own.
-- Option (a) is simpler to reason about and is what the encrypt/decrypt
-- functions below assume. If banking info needs to be queried/filtered on
-- (e.g. "show me all accounts at Comerica Bank"), switch to (b) instead.

-- ---------------------------------------------------------------------------
-- STEP 3 — Encrypt/decrypt helpers. SECURITY DEFINER means these run with
-- elevated privilege to read the Vault secret, regardless of who calls
-- them — which is exactly why the permission check inside matters.
-- ---------------------------------------------------------------------------
create or replace function encrypt_sensitive(plain text)
returns bytea
language sql
security definer
set search_path = public, vault
as $$
  select pgp_sym_encrypt(
    plain,
    (select decrypted_secret from vault.decrypted_secrets where name = 'crm_sensitive_data_key')
  );
$$;

create or replace function decrypt_sensitive(cipher bytea)
returns text
language sql
security definer
set search_path = public, vault
as $$
  select pgp_sym_decrypt(
    cipher,
    (select decrypted_secret from vault.decrypted_secrets where name = 'crm_sensitive_data_key')
  );
$$;

-- Restrict who can even call the raw encrypt/decrypt helpers directly —
-- normal app roles should only ever go through the reveal_* functions
-- below, which add the permission check.
revoke execute on function encrypt_sensitive(text) from public, anon, authenticated;
revoke execute on function decrypt_sensitive(bytea) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- STEP 4 — The actual "reveal" functions the app calls. Each one checks
-- the calling user's role permissions before decrypting anything. This is
-- the server-side equivalent of the app's viewBanking/editBanking checks —
-- except this copy can't be bypassed from the browser.
-- ---------------------------------------------------------------------------
create or replace function current_user_can_view_sensitive()
returns boolean
language sql
security definer
set search_path = public
as $$
  select coalesce(
    (select (r.perms->>'viewBanking')::boolean
     from users u
     join roles r on r.key = u.role
     where u.auth_id = auth.uid()),
    false
  );
$$;

create or replace function reveal_lead_ssn(p_lead_id uuid)
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
  select decrypt_sensitive(ssn) into v_result from leads where id = p_lead_id;
  return v_result;
end;
$$;

create or replace function reveal_lead_banking(p_lead_id uuid)
returns text  -- returns the decrypted JSON as text; parse it in the app
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
  select decrypt_sensitive(banking) into v_result from leads where id = p_lead_id;
  return v_result;
end;
$$;

create or replace function reveal_partner_banking(p_partner_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result text;
  v_is_own boolean;
  v_edit_banking text;
begin
  select (r.perms->>'editBanking')
    into v_edit_banking
    from users u join roles r on r.key = u.role
    where u.auth_id = auth.uid();

  select exists (
    select 1 from partners p
    join users u on lower(u.email) = lower(p.email)
    where p.id = p_partner_id and u.auth_id = auth.uid()
  ) into v_is_own;

  if not (current_user_can_view_sensitive() or (v_edit_banking = 'own' and v_is_own)) then
    raise exception 'Not authorized to view this field';
  end if;

  select decrypt_sensitive(banking) into v_result from partners where id = p_partner_id;
  return v_result;
end;
$$;

-- Repeat the same pattern (reveal_lead_drivers_license, reveal_lead_tax_id,
-- etc.) for the other encrypted columns — same shape, different column.

-- Only authenticated users can call the reveal functions at all; the
-- permission check inside decides what they actually get back.
grant execute on function reveal_lead_ssn(uuid) to authenticated;
grant execute on function reveal_lead_banking(uuid) to authenticated;
grant execute on function reveal_partner_banking(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- STEP 5 — Writing encrypted values (from the app, e.g. saving the SSN
-- field). This still needs its own permission check (editBanking, not just
-- viewBanking) — same idea, wrapped as another SECURITY DEFINER function
-- rather than letting the app write to the bytea column directly.
-- ---------------------------------------------------------------------------
create or replace function set_lead_ssn(p_lead_id uuid, p_ssn text)
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
  update leads set ssn = encrypt_sensitive(p_ssn) where id = p_lead_id;
end;
$$;
grant execute on function set_lead_ssn(uuid, text) to authenticated;

-- =============================================================================
-- What the app actually calls, once this is wired up:
--   - Displaying the masked value: just read whether the bytea column is
--     null or not (no decryption needed to know "something is on file").
--   - Clicking the eye icon: call reveal_lead_ssn(lead_id) via the Supabase
--     client SDK, get back plaintext (or an authorization error), display
--     it. The app's existing eye-icon UI maps onto this exactly — the only
--     change is that click now calls a real RPC instead of just toggling
--     a local reveal flag.
--   - Saving a new value: call set_lead_ssn(lead_id, newValue) instead of
--     writing to the leads table directly.
-- =============================================================================

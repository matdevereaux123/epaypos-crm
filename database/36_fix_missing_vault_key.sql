-- =============================================================================
-- EPAY POS / Envision ATM Control Center — the encryption key was never created
-- ---------------------------------------------------------------------------
-- Run after 35_google_calendar_oauth.sql. Run it BEFORE any real merchant
-- data goes in.
--
-- WHAT WENT WRONG
--
-- 02_encryption.sql step 1 creates the Vault secret, and it shipped with a
-- placeholder:
--
--     select vault.create_secret('REPLACE_WITH_YOUR_OWN_GENERATED_SECRET', ...)
--
-- That call never completed on this project. Everything else in 02 did — the
-- bytea columns exist, encrypt_sensitive() and decrypt_sensitive() exist — so
-- the system looked fully set up.
--
-- It was not, and this is the part worth remembering. encrypt_sensitive()
-- does:
--
--     pgp_sym_encrypt(plain, (select decrypted_secret from vault... ))
--
-- pgp_sym_encrypt is STRICT: given a NULL key it returns NULL rather than
-- raising. The subquery returns NULL when the secret is missing. So every
-- "encryption" since day one produced NULL, and since every sensitive column
-- is nullable, each write succeeded and stored nothing. No error, anywhere,
-- for months.
--
-- It surfaced only because google_calendar_tokens.refresh_token is NOT NULL —
-- the first column in the system that refused a NULL. A security control that
-- fails silently is worse than one that is absent, because the absent one
-- does not tell you it is working.
--
-- Nothing was lost. Confirmed before writing this: 0 applications, 0 leads
-- with sensitive fields, 0 partners with banking. There is no ciphertext
-- under an old key to strand, so generating a key now is safe.
--
-- WHAT THIS DOES
--   1. Creates the key, if and only if it is genuinely absent.
--   2. Makes both helpers RAISE on a missing key instead of returning NULL,
--      so this can never fail quietly again.
--   3. Proves the round trip at the end rather than asking you to trust it.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1. The key.
--
-- Generated inside the database by pgcrypto, so it is never typed, never
-- pasted, never in a shell history, never in this file and never in git. 32
-- random bytes, base64-encoded.
--
-- Guarded on absence: if a secret of this name already exists it is left
-- exactly alone. Replacing a live key would strand every value encrypted
-- under the old one with no way back.
-- ---------------------------------------------------------------------------
do $$
declare
  v_existing int;
begin
  select count(*) into v_existing
    from vault.decrypted_secrets
   where name = 'crm_sensitive_data_key';

  if v_existing > 0 then
    raise notice 'crm_sensitive_data_key already exists — leaving it untouched.';
  else
    perform vault.create_secret(
      encode(extensions.gen_random_bytes(32), 'base64'),
      'crm_sensitive_data_key',
      'Symmetric key for CRM sensitive columns. Created by migration 36 after the 02 placeholder was found never to have run.'
    );
    raise notice 'crm_sensitive_data_key created.';
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 2. Never fail quietly again.
--
-- Both helpers were `language sql` wrapping a STRICT pgcrypto call, which is
-- precisely how a missing key turned into a silent NULL. They are plpgsql now
-- so they can look at the key before using it and refuse to continue.
--
-- A NULL input still returns NULL — "nothing on file" is a legitimate state
-- and callers rely on it. What is no longer tolerated is a real value going
-- in and NULL coming out.
--
-- create or replace preserves the ownership and the revokes from 02.
-- ---------------------------------------------------------------------------
create or replace function encrypt_sensitive(plain text)
returns bytea
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_key text;
  v_out bytea;
begin
  if plain is null then
    return null;
  end if;

  select decrypted_secret into v_key
    from vault.decrypted_secrets
   where name = 'crm_sensitive_data_key';

  if v_key is null or v_key = '' then
    raise exception 'Encryption key crm_sensitive_data_key is missing from Vault. Refusing to store this value, because storing it would mean storing nothing at all. Run database/36_fix_missing_vault_key.sql.';
  end if;

  v_out := pgp_sym_encrypt(plain, v_key);

  -- Belt and braces. If pgcrypto ever hands back NULL for a non-null input,
  -- that is a silent data loss and must stop the transaction, not ride along
  -- into a nullable column.
  if v_out is null then
    raise exception 'Encryption produced no output for a non-null value. Nothing has been stored.';
  end if;

  return v_out;
end;
$$;

create or replace function decrypt_sensitive(cipher bytea)
returns text
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_key text;
begin
  if cipher is null then
    return null;
  end if;

  select decrypted_secret into v_key
    from vault.decrypted_secrets
   where name = 'crm_sensitive_data_key';

  if v_key is null or v_key = '' then
    raise exception 'Encryption key crm_sensitive_data_key is missing from Vault, so this value cannot be read. Run database/36_fix_missing_vault_key.sql.';
  end if;

  return pgp_sym_decrypt(cipher, v_key);
end;
$$;

-- Re-stated rather than assumed. These two are the raw helpers; app roles go
-- through the reveal_* functions, which check permissions first.
revoke execute on function encrypt_sensitive(text)  from public, anon, authenticated;
revoke execute on function decrypt_sensitive(bytea) from public, anon, authenticated;


-- ---------------------------------------------------------------------------
-- 3. Prove it. This is the whole point of the file.
-- ---------------------------------------------------------------------------
do $$
declare
  v_cipher bytea;
  v_plain  text;
begin
  v_cipher := encrypt_sensitive('round-trip-probe');
  v_plain  := decrypt_sensitive(v_cipher);

  if v_cipher is null then
    raise exception 'STILL BROKEN: encrypt_sensitive returned NULL.';
  end if;
  if v_plain is distinct from 'round-trip-probe' then
    raise exception 'STILL BROKEN: round trip returned %, expected the probe value.', coalesce(v_plain, 'NULL');
  end if;

  raise notice 'Encryption verified: % bytes of ciphertext, decrypts back correctly.', length(v_cipher);
end $$;


select
  (select count(*) from vault.decrypted_secrets where name = 'crm_sensitive_data_key') as key_present,
  length(encrypt_sensitive('probe'))                                                   as cipher_bytes,
  decrypt_sensitive(encrypt_sensitive('probe')) = 'probe'                              as round_trip_ok;


-- =============================================================================
-- AFTER RUNNING THIS
--   The select above must show key_present = 1 and round_trip_ok = true.
--
--   Then connect Google Calendar again — it will now store a real encrypted
--   refresh token instead of tripping the not-null constraint.
--
--   Two things worth knowing:
--
--   * This key lives only in this Supabase project's Vault. It is included in
--     Supabase's own backups. If the project is ever deleted or migrated,
--     every encrypted column becomes unreadable without it.
--
--   * Anything typed into a sensitive field BEFORE this ran was stored as
--     NULL. The counts said there was nothing, but if you remember entering
--     banking details for any of the three partners on file, enter them again
--     — they are not there.
-- =============================================================================

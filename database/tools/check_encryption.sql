-- =============================================================================
-- DIAGNOSTIC — is encryption actually encrypting?
-- ---------------------------------------------------------------------------
-- Read-only. Changes nothing. Safe to run any time.
--
-- Why this exists: encrypt_sensitive() calls pgp_sym_encrypt(data, key), and
-- pgp_sym_encrypt is STRICT — given a NULL key it returns NULL instead of
-- raising. The key comes from a vault lookup that yields NULL when the secret
-- is missing. So a missing vault secret does not fail loudly; it silently
-- turns every "encrypted" write into a NULL, and every sensitive column in
-- this system is nullable, so nothing complains.
--
-- One query, one result set, because the SQL Editor only shows the last one.
-- Read the `status` column top to bottom.
-- =============================================================================

with
probe as (
  -- Does the whole round trip work on a throwaway value?
  select
    (select count(*) from vault.decrypted_secrets
      where name = 'crm_sensitive_data_key')                     as key_rows,
    encrypt_sensitive('round-trip-probe')                        as cipher,
    decrypt_sensitive(encrypt_sensitive('round-trip-probe'))     as plain
),
fn as (
  -- Which build of the calendar function is installed? The fixed one raises
  -- its own error rather than letting the NOT NULL constraint do it.
  select
    coalesce(bool_or(p.prosrc like '%A refresh token is required%'), false) as has_guard,
    count(*) as defined
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'google_calendar_store_tokens'
)
select 1 as ord, 'vault secret crm_sensitive_data_key' as check,
       case when key_rows > 0 then 'FOUND' else 'MISSING  <-- this is the problem' end as status
  from probe
union all
select 2, 'encrypt_sensitive() returns ciphertext',
       case when cipher is null then 'NULL  <-- encrypting produces nothing'
            else 'ok (' || length(cipher) || ' bytes)' end
  from probe
union all
select 3, 'decrypt_sensitive(encrypt_sensitive(x)) = x',
       case when plain is null then 'NULL  <-- round trip broken'
            when plain = 'round-trip-probe' then 'ok'
            else 'MISMATCH: ' || plain end
  from probe
union all
select 4, 'google_calendar_store_tokens installed',
       case when defined = 0 then 'MISSING — migration 35 did not run'
            when has_guard then 'ok (current version)'
            else 'OLD VERSION — re-run migration 35' end
  from fn

-- Anything already written while the key was missing would be sitting as NULL
-- right now. These counts say whether real data was lost or whether the
-- columns were simply never populated.
union all
select 5, 'applications with any sensitive field stored',
       count(*)::text || ' of ' || (select count(*) from applications)::text || ' rows'
  from applications
 where ssn is not null or dob is not null or drivers_license is not null
    or business_tax_id is not null or banking is not null
union all
select 6, 'leads with any sensitive field stored',
       count(*)::text || ' of ' || (select count(*) from leads)::text || ' rows'
  from leads
 where ssn is not null or drivers_license is not null or business_tax_id is not null
union all
select 7, 'partners with banking stored',
       count(*)::text || ' of ' || (select count(*) from partners)::text || ' rows'
  from partners
 where banking is not null
order by ord;

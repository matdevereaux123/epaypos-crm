-- =============================================================================
-- EPAY POS / Envision ATM Control Center — fail-closed permission checks
-- ---------------------------------------------------------------------------
-- SECURITY FIX. Run immediately after 16_agent_onboarding.sql.
--
-- The bug
-- -------
-- These functions gate on a permission read out of roles.perms:
--
--     select (r.perms->>'viewBanking') into v_view
--       from users u join roles r on r.key = u.role
--      where u.auth_id = auth.uid();
--
--     if not (v_view = 'true' or (v_view = 'own' and <is own record>)) then
--       raise exception 'Not authorized';
--     end if;
--
-- When the caller has no matching users row — an anonymous request holding
-- only the public anon key, or a login with no CRM user — the select assigns
-- NULL rather than a value. In SQL three-valued logic:
--
--     NULL = 'true'          -> NULL
--     NULL = 'own' AND false -> false
--     NULL OR false          -> NULL
--     NOT NULL               -> NULL
--     IF NULL THEN ...       -> does NOT fire
--
-- So the guard silently does nothing and execution continues into the body.
-- These are SECURITY DEFINER functions, so they also bypass RLS. Verified
-- against the live project before this fix: calling reveal_partner_sensitive
-- with nothing but the anon key returned HTTP 200 and a decrypted payload,
-- and set_partner_sensitive returned 204 having performed the write.
--
-- The fix is to wrap every check in coalesce(..., false) so an unknown
-- permission fails closed. mark_partner_invited was already correct, because
-- current_app_has_perm() coalesces internally — which is why it alone
-- answered "Not authorized" when the others did not.
--
-- Affected:
--   set_partner_banking       (pre-existing, from 02_encryption.sql line ~342)
--   reveal_partner_banking    (introduced in 16)
--   set_partner_sensitive     (introduced in 16)
--   reveal_partner_sensitive  (introduced in 16)
--
-- The lead-side functions were checked and are NOT affected: they gate on
-- current_user_can_view_sensitive() / coalesce(...) and already fail closed.
-- =============================================================================


create or replace function reveal_partner_banking(p_partner_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_result text;
  v_view_banking text;
begin
  select (r.perms->>'viewBanking')
    into v_view_banking
    from users u join roles r on r.key = u.role
    where u.auth_id = auth.uid();

  if not coalesce(
       v_view_banking = 'true'
       or (v_view_banking = 'own' and current_partner_is_own(p_partner_id)),
       false
     ) then
    raise exception 'Not authorized to view this field';
  end if;

  select decrypt_sensitive(banking) into v_result from partners where id = p_partner_id;
  return v_result;
end;
$$;
grant execute on function reveal_partner_banking(uuid) to authenticated;
revoke execute on function reveal_partner_banking(uuid) from anon;


create or replace function set_partner_banking(p_partner_id uuid, p_banking text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_edit_banking text;
begin
  select (r.perms->>'editBanking')
    into v_edit_banking
    from users u join roles r on r.key = u.role
    where u.auth_id = auth.uid();

  if not coalesce(
       v_edit_banking = 'true'
       or (v_edit_banking = 'own' and current_partner_is_own(p_partner_id)),
       false
     ) then
    raise exception 'Not authorized to edit this field';
  end if;

  update partners set banking = encrypt_sensitive(p_banking) where id = p_partner_id;
end;
$$;
grant execute on function set_partner_banking(uuid, text) to authenticated;
revoke execute on function set_partner_banking(uuid, text) from anon;


create or replace function set_partner_sensitive(
  p_partner_id uuid,
  p_ssn text,
  p_dob text,
  p_drivers_license text,
  p_tax_id text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_edit text;
begin
  select (r.perms->>'editBanking')
    into v_edit
    from users u join roles r on r.key = u.role
    where u.auth_id = auth.uid();

  if not coalesce(
       v_edit = 'true'
       or (v_edit = 'own' and current_partner_is_own(p_partner_id)),
       false
     ) then
    raise exception 'Not authorized to edit this record';
  end if;

  update partners set
    ssn             = case when p_ssn             is null then ssn             else encrypt_sensitive(p_ssn) end,
    dob             = case when p_dob             is null then dob             else encrypt_sensitive(p_dob) end,
    drivers_license = case when p_drivers_license is null then drivers_license else encrypt_sensitive(p_drivers_license) end,
    tax_id          = case when p_tax_id          is null then tax_id          else encrypt_sensitive(p_tax_id) end
  where id = p_partner_id;
end;
$$;
grant execute on function set_partner_sensitive(uuid, text, text, text, text) to authenticated;
revoke execute on function set_partner_sensitive(uuid, text, text, text, text) from anon;


create or replace function reveal_partner_sensitive(p_partner_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_view text;
  v_row partners%rowtype;
begin
  select (r.perms->>'viewBanking')
    into v_view
    from users u join roles r on r.key = u.role
    where u.auth_id = auth.uid();

  if not coalesce(
       v_view = 'true'
       or (v_view = 'own' and current_partner_is_own(p_partner_id)),
       false
     ) then
    raise exception 'Not authorized to view this record';
  end if;

  select * into v_row from partners where id = p_partner_id;

  return jsonb_build_object(
    'ssn',             decrypt_sensitive(v_row.ssn),
    'dob',             decrypt_sensitive(v_row.dob),
    'drivers_license', decrypt_sensitive(v_row.drivers_license),
    'tax_id',          decrypt_sensitive(v_row.tax_id)
  );
end;
$$;
grant execute on function reveal_partner_sensitive(uuid) to authenticated;
revoke execute on function reveal_partner_sensitive(uuid) from anon;


-- Belt and braces: these should never have been reachable by `anon` in the
-- first place. Every one of them is for a signed-in user acting on a record,
-- so the anon role has no business holding EXECUTE on any of them.
revoke execute on function current_partner_is_own(uuid) from anon;
revoke execute on function can_invite_partner(uuid) from anon;
revoke execute on function mark_partner_invited(uuid) from anon;


-- =============================================================================
-- VERIFY AFTER RUNNING
-- Each of these, called with nothing but the public anon key, must now come
-- back with a "Not authorized" error or a permission denial — NOT with data
-- and NOT with a success:
--
--   reveal_partner_sensitive('00000000-0000-0000-0000-000000000000')
--   set_partner_sensitive('00000000-0000-0000-0000-000000000000', null, null, null, null)
--   reveal_partner_banking('00000000-0000-0000-0000-000000000000')
-- =============================================================================

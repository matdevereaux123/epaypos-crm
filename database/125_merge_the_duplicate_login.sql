-- =============================================================================
-- 125 - Two logins for one person, and portal logins with no partner row.
--
-- Blake Piha has two rows in users. 122 joined one of them to his partner
-- record by name; the other is still loose. Two logins for one person is not
-- cosmetic - whichever row a lead gets assigned to is the only row that can
-- see it, so half his work is invisible from whichever side he signs in on.
--
-- MERGING A USER ROW IS THE MOST DESTRUCTIVE THING IN THIS FOLDER, so:
--
--   * The keeper is chosen by rule, not by me guessing: the row that can
--     actually sign in (auth_id not null) wins; then the one already joined
--     to a partner; then the older row.
--   * Every reference is repointed BEFORE anything is deleted, and the
--     references are found from the catalog rather than from a list I typed -
--     a list would be out of date the next time somebody adds a table. The
--     uuid[] columns are handled separately because they are not foreign keys
--     and the catalog does not know about them.
--   * The loser is deleted only if it has never signed in. If both rows have
--     an auth_id, both are real logins, and this refuses and tells you -
--     that is a password-reset conversation, not a migration.
--   * It all runs in one transaction. Any failure and nothing happened.
--
-- Then the second half: a portal login with no partner row has nothing to
-- show - no referral link, no deals, no payout details, which is what 124
-- fixed for Mitch one row at a time. This does it for whoever is left.
--
-- Safe to run twice.
-- =============================================================================

do $$
declare
  v_keep   uuid;
  v_drop   uuid;
  v_name   text;
  v_fk     record;
  v_rows   int;
  v_total  int := 0;
begin
  -- Only act where exactly two rows share an email-less identity by name.
  -- Blake is the known case; written as a loop so it handles any other.
  -- Guarded deliberately tightly. users.email is UNIQUE, so two rows for one
  -- person necessarily carry different addresses - which means NAME is the
  -- only thing linking them, and name alone would happily merge two different
  -- people who happen to share one. So: exactly two rows, the same role, and
  -- at most one of them has ever signed in. Two real colleagues with the same
  -- name on the same role, only one of whom has logged in, would still slip
  -- through - which is why the report at the end prints what it did.
  for v_name in
    select u.name
      from users u
     group by u.name
    having count(*) = 2
       and count(distinct u.role) = 1
       and count(u.auth_id) <= 1
  loop
    select id into v_keep from users
     where name = v_name
     order by (auth_id is not null) desc,
              (linked_partner_id is not null) desc,
              created_at asc
     limit 1;

    select id into v_drop from users
     where name = v_name and id <> v_keep
     limit 1;

    if (select auth_id from users where id = v_drop) is not null
       and (select auth_id from users where id = v_keep) is not null then
      raise notice 'SKIPPED %: both rows have signed in. Needs a human.', v_name;
      continue;
    end if;

    -- Every foreign key column pointing at users.id, from the catalog.
    for v_fk in
      select c.conrelid::regclass::text as tbl, a.attname as col
        from pg_constraint c
        join unnest(c.conkey) k(attnum) on true
        join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum
       where c.contype = 'f'
         and c.confrelid = 'users'::regclass
    loop
      begin
        execute format('update %s set %I = $1 where %I = $2', v_fk.tbl, v_fk.col, v_fk.col)
          using v_keep, v_drop;
        get diagnostics v_rows = row_count;
        v_total := v_total + v_rows;
      exception when unique_violation then
        -- One row per user by design (a calendar connection, a settings row).
        -- The keeper already has one, so the duplicate's copy goes.
        execute format('delete from %s where %I = $1', v_fk.tbl, v_fk.col) using v_drop;
        raise notice '  % - keeper already had a row, dropped the duplicate''s', v_fk.tbl;
      end;
    end loop;

    -- The array columns, which are not foreign keys.
    update leads      set assigned_to_ids = array_replace(assigned_to_ids, v_drop, v_keep)
     where v_drop = any(assigned_to_ids);
    update cold_leads set assigned_to_ids = array_replace(assigned_to_ids, v_drop, v_keep)
     where v_drop = any(assigned_to_ids);
    update meetings   set attendee_user_ids = array_replace(attendee_user_ids, v_drop, v_keep)
     where v_drop = any(attendee_user_ids);

    -- Keep anything the loser had that the keeper lacks.
    update users k
       set linked_partner_id = coalesce(k.linked_partner_id, d.linked_partner_id),
           manager_id        = coalesce(k.manager_id, d.manager_id),
           auth_id           = coalesce(k.auth_id, d.auth_id),
           extra_perms       = coalesce(d.extra_perms, '{}'::jsonb) || coalesce(k.extra_perms, '{}'::jsonb)
      from users d
     where k.id = v_keep and d.id = v_drop;

    delete from users where id = v_drop;
    raise notice 'Merged % - kept %, repointed % reference(s).', v_name, v_keep, v_total;
  end loop;
end $$;

-- ------------------------------------------------- portal logins need a row
do $$
declare u record; v_slug text; v_partner uuid; v_type text;
begin
  for u in
    select * from users
     where linked_partner_id is null
       and role in ('iso','agent','referral_partner','epay_reseller')
  loop
    v_type := case when u.role = 'referral_partner' then 'referral_partner' else 'agent' end;
    v_slug := lower(regexp_replace(u.name, '[^a-zA-Z0-9]+', '-', 'g'))
              || '-' || floor(random() * 900 + 100)::text;
    while exists (select 1 from partners where link_slug = v_slug) loop
      v_slug := lower(regexp_replace(u.name, '[^a-zA-Z0-9]+', '-', 'g'))
                || '-' || floor(random() * 900 + 100)::text;
    end loop;

    insert into partners (name, contact, email, type, brand, link_slug, status)
    values (u.name, u.name, u.email, v_type,
            case when 'atm' = any(u.brands) and not ('epay' = any(u.brands))
                 then 'atm' else 'epay' end,
            v_slug, 'active')
    returning id into v_partner;

    update users set linked_partner_id = v_partner where id = u.id;
    raise notice 'Created partner row for % (%).', u.name, v_slug;
  end loop;
end $$;

-- Every portal login, end to end. No row should read "NO PARTNER ROW" and no
-- name should appear twice.
select u.name, u.role, u.email,
       p.name as partner_row, p.link_slug, p.brand,
       coalesce(p.residual_percentage, '(split not set)') as split,
       case when u.auth_id is null then 'never signed in' else 'has logged in' end as login,
       case when u.linked_partner_id is null then 'NO PARTNER ROW' else 'ok' end as state
  from users u
  left join partners p on p.id = u.linked_partner_id
 where u.role in ('iso','agent','referral_partner','epay_reseller')
 order by u.name;

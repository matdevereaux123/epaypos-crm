-- =============================================================================
-- 93 - Put your name on the cold leads from the account sheet import
--
-- The Salesforce account sheet import (import_2026-09-13_salesforce_accounts
-- and its REDO) inserted 14 cold leads straight through the SQL editor. The
-- portal_stamp_created_by trigger only stamps created_by when there is a
-- logged-in app user behind the statement, and there wasn't one, so those
-- rows have created_by = null and show as "Not recorded" in the Added-by
-- filter on Cold Leads. They were added on your behalf, so they should
-- carry your name.
--
-- Scoped by the exact source string that import wrote, not by "created_by
-- is null": anything else without a creator came from somewhere else and is
-- not yours to claim. The last query lists whatever is still unattributed.
--
-- Safe to run twice: the second run matches nothing.
--
-- ASCII only, on purpose. The first pass of that same import had to be
-- redone because a non-ASCII dash came back as mojibake through the SQL
-- editor, and the error this file raised was mangled the same way.
-- =============================================================================

do $$
declare
  v_me      uuid;
  v_who     text;
  v_n       int;
  v_updated int;
begin
  -- Find the one account that is yours. Email first; if that address is not
  -- the one on file, fall back to matching name or email, and stop with the
  -- candidates listed rather than guessing.
  select id into v_me
    from users
   where lower(email) = lower('matthew@epaypos.net');

  if v_me is null then
    select count(*) into v_n
      from users
     where email ilike '%matt%' or name ilike '%matt%';

    if v_n = 1 then
      select id, coalesce(name, '') || ' <' || coalesce(email, 'no email') || '>'
        into v_me, v_who
        from users
       where email ilike '%matt%' or name ilike '%matt%';
      raise notice 'Matched you as %', v_who;
    else
      select string_agg(coalesce(name, '(no name)') || ' <' || coalesce(email, 'no email') || '>', ' | ' order by name)
        into v_who
        from users;
      raise exception 'Could not tell which user is you. Accounts on file: %', v_who;
    end if;
  end if;

  update cold_leads
     set created_by = v_me
   where created_by is null
     and source = 'Imported from Salesforce export - flagged for manual review';

  get diagnostics v_updated = row_count;
  raise notice 'Credited % cold lead(s) from the account sheet import to %.', v_updated, v_me;
end $$;

-- What that leaves. No rows = every cold lead now says who added it.
select coalesce(source, '(no source)') as source,
       count(*)                        as still_unattributed,
       min(created_at)::date           as oldest,
       max(created_at)::date           as newest
  from cold_leads
 where created_by is null
 group by 1
 order by 2 desc;

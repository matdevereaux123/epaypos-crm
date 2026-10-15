-- =============================================================================
-- 93 — Put your name on the cold leads from the account sheet import
--
-- The Salesforce account sheet import (import_2026-09-13_salesforce_accounts
-- and its REDO) inserted 14 cold leads straight through the SQL editor. The
-- portal_stamp_created_by trigger only stamps created_by when there is a
-- logged-in app user behind the statement, and there wasn't one — so those
-- rows have created_by = null and show as "Not recorded" in the new
-- "Added by" filter on Cold Leads. They were added on your behalf, so they
-- should carry your name.
--
-- Scoped by the exact source string that import wrote, not by "created_by is
-- null": anything else without a creator came from somewhere else and is not
-- yours to claim. The last query in this file lists whatever is still
-- unattributed so you can decide about it separately.
--
-- Safe to run twice: the second run matches nothing.
-- =============================================================================

do $$
declare
  v_me      uuid;
  v_updated int;
begin
  select id into v_me from users where lower(email) = lower('matthew@envisionprocessing.com');

  if v_me is null then
    raise exception 'No user with that email — check the address in this file before running it again.';
  end if;

  update cold_leads
     set created_by = v_me
   where created_by is null
     and source = 'Imported from Salesforce export - flagged for manual review';

  get diagnostics v_updated = row_count;
  raise notice 'Credited % cold lead(s) from the account sheet import to %.', v_updated, v_me;
end $$;

-- What that leaves. Empty result = every cold lead now says who added it.
select coalesce(source, '(no source)') as source,
       count(*)                        as still_unattributed,
       min(created_at)::date           as oldest,
       max(created_at)::date           as newest
  from cold_leads
 where created_by is null
 group by 1
 order by 2 desc;

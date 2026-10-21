-- =============================================================================
-- 117 - FOR THE POS PLATFORM DATABASE (vbdgaeyerqntipzcfqag), not the CRM.
--
-- 110 fails on this database with:
--   42P10: there is no unique or exclusion constraint matching the ON CONFLICT
--
-- Why: pos_config already exists here, created by something other than 110 -
-- so "create table if not exists" skipped the definition, and with it the
-- "primary key (scope, key)" that the seed insert conflicts on. The columns
-- are there and the data is there; only the constraint is missing.
--
-- Checked before writing this: 11 rows, 11 distinct (scope, key). Nothing is
-- duplicated, so the constraint can simply be added - no row has to be
-- deleted or merged, and this touches no data at all.
--
-- Run this, then 110, 111 and 112 in that order. Safe to run twice.
-- =============================================================================

do $$
begin
  if exists (
    select 1 from pos_config
     group by scope, key
    having count(*) > 1
  ) then
    raise exception
      'pos_config has duplicate (scope, key) rows. Adding the constraint would '
      'have to delete some - stopping so that is a decision rather than a '
      'side effect.';
  end if;
end $$;

create unique index if not exists pos_config_scope_key_uidx
  on pos_config (scope, key);

-- What ON CONFLICT (scope, key) will now match.
select indexname, indexdef
  from pg_indexes
 where tablename = 'pos_config'
   and indexdef ilike '%unique%';

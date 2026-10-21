-- =============================================================================
-- 107 - Register settings, per account
--
-- 106 made pos_config a single set of values for the whole platform. That was
-- wrong for most of what is in it. A receipt footer, the tip buttons and the
-- reasons a till offers are things one merchant asks to change and the rest
-- never hear about - a steakhouse wanting 20/22/25 does not change what a
-- coffee shop sees.
--
-- So the same table carries both, distinguished by merchant_id:
--
--   merchant_id null  - the platform default. What a new account starts on,
--                       and what every account uses until it says otherwise.
--   merchant_id set   - that account's own answer, which wins.
--
-- One table rather than two, because the thing being read is "what does this
-- merchant use", and that question is answered by looking for an override
-- and falling back. Two tables would mean two reads, two policies and two
-- places for the fallback to be written differently.
--
-- WHY NOT A COLUMN ON pos_merchants
-- Because these are a growing list of unrelated settings, and a column per
-- setting is a migration every time somebody wants a new one. The whole
-- point of 106 was that this stops needing a release.
--
-- Safe to run twice.
-- =============================================================================

alter table pos_config
  add column if not exists merchant_id uuid references pos_merchants(id) on delete cascade;

comment on column pos_config.merchant_id is
  'Null for the platform default; set for one account''s own answer, which '
  'overrides the default. Read as: this merchant''s row if there is one, '
  'otherwise the row with no merchant.';

-- The primary key was (scope, key), which cannot hold a default and an
-- override of the same setting. A surrogate key, with uniqueness expressed
-- as two partial indexes: one default per setting, one override per setting
-- per merchant.
--
-- Partial indexes rather than `nulls not distinct`, which needs Postgres 15.
do $$
begin
  if exists (
    select 1 from pg_constraint
     where conrelid = 'pos_config'::regclass and contype = 'p'
       and conname = 'pos_config_pkey'
  ) then
    alter table pos_config drop constraint pos_config_pkey;
  end if;
end $$;

alter table pos_config
  add column if not exists id uuid not null default gen_random_uuid();

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'pos_config'::regclass and contype = 'p'
  ) then
    alter table pos_config add primary key (id);
  end if;
end $$;

create unique index if not exists pos_config_default_uq
  on pos_config (scope, key) where merchant_id is null;
create unique index if not exists pos_config_merchant_uq
  on pos_config (scope, key, merchant_id) where merchant_id is not null;
create index if not exists pos_config_by_merchant_idx
  on pos_config (merchant_id, scope, sort);

-- ---------------------------------------------------------------------------
-- What a merchant actually uses.
--
-- A function rather than a view, because the answer depends on which
-- merchant is being asked about. `distinct on` takes the override where one
-- exists: nulls sort last, so the merchant's own row wins over the default.
-- ---------------------------------------------------------------------------
create or replace function pos_config_for(p_merchant uuid)
returns table (
  scope text, key text, value jsonb, label text, sort integer,
  active boolean, is_override boolean, updated_at timestamptz, updated_by text
)
language sql stable as $$
  select distinct on (c.scope, c.key)
         c.scope, c.key, c.value, c.label, c.sort, c.active,
         (c.merchant_id is not null) as is_override,
         c.updated_at, c.updated_by
    from pos_config c
   where c.merchant_id is null or c.merchant_id = p_merchant
   order by c.scope, c.key, c.merchant_id nulls last;
$$;

comment on function pos_config_for(uuid) is
  'Every register setting as this merchant sees it: their own answer where '
  'they have given one, the platform default everywhere else. is_override '
  'says which, so a screen can show what has been changed from standard.';

revoke all on function pos_config_for(uuid) from public;
grant execute on function pos_config_for(uuid) to authenticated;

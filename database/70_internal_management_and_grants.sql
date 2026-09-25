/* =========================================================================
   70_internal_management_and_grants.sql

   Three things that belong together, because they are all one idea:
   access should be something you hand out per person, not only per role.

   1. A new "Internal Management" role that starts with NOTHING switched on.
      It is seeded as a custom role (is_custom = true) so it stays editable
      in Settings -> Roles & Permissions — a built-in role is deliberately
      locked there, and a role you cannot tick boxes on is useless for this.

   2. users.extra_perms — per-person grants on top of whatever the role
      allows. current_app_perms() now returns role perms with the person's
      own grants merged over the top, so every RLS policy in the database
      picks this up without being touched: they all read
      current_app_has_perm(), and that reads current_app_perms().

      Only granted keys are stored, as true. A key that is not in
      extra_perms leaves the role's own answer alone, so this adds access
      and never quietly takes it away. Writing it is manageUsers-only —
      the users_write policy from 04_rls.sql already sees to that, which
      means nobody can grant themselves anything.

   3. internal_sales_comp — what an internal sales person is paid. Its own
      table rather than columns on users, because every logged-in user
      loads the users list for the assignment dropdowns, and salary is not
      something an agent should be able to read out of it.
   ========================================================================= */

-- ---------------------------------------------------------- 1. the role
insert into roles (key, label, portal_scope, description, perms, is_custom)
values (
  'internal_management',
  'Internal Management',
  'internal',
  'Internal manager. Starts with no access at all — every tab and permission is granted individually, either on this role or on the person in Settings → Users.',
  '{}'::jsonb,
  true
)
on conflict (key) do nothing;


-- ------------------------------------------------- 2. per-person grants
alter table users add column if not exists extra_perms jsonb not null default '{}'::jsonb;

comment on column users.extra_perms is
  'Extra permissions granted to this one person, merged over their role''s perms by current_app_perms(). Only granted keys are stored, as true. manageUsers-only to write (users_write, database/04_rls.sql).';

-- The whole point of the change: same function, same name, same signature,
-- so all ~90 existing policies that call current_app_has_perm() inherit it.
create or replace function current_app_perms()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select r.perms || coalesce(u.extra_perms, '{}'::jsonb)
  from users u
  join roles r on r.key = u.role
  where u.auth_id = auth.uid();
$$;


-- ------------------------------------------- 3. internal sales team pay
create table if not exists internal_sales_comp (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null unique references users(id) on delete cascade,
  title             text,
  start_date        date,
  -- How they are paid. 'salary', 'commission', or both — a rep on a base
  -- plus a split is the normal case, so this is not an either/or.
  pay_salary        boolean not null default false,
  pay_commission    boolean not null default false,
  salary_amount     numeric(12,2),
  salary_period     text default 'year' check (salary_period in ('year','month','week','hour')),
  commission_percent numeric(6,3),
  -- What the percentage is a percentage OF. Two shops mean two different
  -- numbers by "20%", and a comp record that does not say which is a
  -- disagreement waiting to happen.
  commission_basis  text default 'residual'
                      check (commission_basis in ('residual','gross_profit','revenue','deal_value','other')),
  draw_amount       numeric(12,2),
  notes             text,
  active            boolean not null default true,
  created_by        uuid references users(id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index if not exists internal_sales_comp_user_idx on internal_sales_comp (user_id);

alter table internal_sales_comp enable row level security;

drop policy if exists "internal_sales_comp_select" on internal_sales_comp;
drop policy if exists "internal_sales_comp_insert" on internal_sales_comp;
drop policy if exists "internal_sales_comp_update" on internal_sales_comp;
drop policy if exists "internal_sales_comp_delete" on internal_sales_comp;

-- You can see your own pay, and whoever manages users can see everyone's.
-- Not viewBanking: that one is about partner payout details and is held by
-- roles who have no business reading an employee's salary.
create policy "internal_sales_comp_select" on internal_sales_comp
  for select to authenticated
  using (
    current_app_has_perm('manageUsers')
    or user_id = current_app_user_id()
  );

create policy "internal_sales_comp_insert" on internal_sales_comp
  for insert to authenticated
  with check (current_app_has_perm('manageUsers'));

create policy "internal_sales_comp_update" on internal_sales_comp
  for update to authenticated
  using (current_app_has_perm('manageUsers'))
  with check (current_app_has_perm('manageUsers'));

create policy "internal_sales_comp_delete" on internal_sales_comp
  for delete to authenticated
  using (current_app_has_perm('manageUsers'));

comment on table internal_sales_comp is
  'Pay for an internal sales person: salary, commission percentage, or both. One row per CRM user. Readable only by that person and by whoever manages users.';

/* =========================================================================
   81_marketing_materials.sql — Resources -> Marketing Materials

   One page per product, each holding the collateral for it: the brochure,
   the spec sheet, the rate card, a link to a demo video. Sales people need
   to find the right PDF in front of a merchant without asking anyone, so
   everybody who can log in can read these. Only staff can change them —
   collateral that anyone can edit stops being the approved version.

   Products are a table rather than a hard-coded list, seeded with the
   fourteen we sell today. A new product line should not need a migration.

   Files live in their own bucket, private, read by any logged-in user.
   Not public: a rate card is not something to leave on an open URL.
   ========================================================================= */

create table if not exists marketing_products (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  slug        text unique not null,
  description text,
  brand       text not null default 'epay' check (brand in ('epay','atm','both')),
  -- Our own products first, then the platforms we resell.
  category    text not null default 'epay' check (category in ('epay','partner','other')),
  sort_order  integer not null default 100,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists marketing_materials (
  id          uuid primary key default gen_random_uuid(),
  product_id  uuid not null references marketing_products(id) on delete cascade,
  title       text not null,
  description text,
  -- A material is either something we hold or somewhere we point.
  kind        text not null default 'file' check (kind in ('file','link')),
  file_path   text,
  file_name   text,
  file_type   text,
  file_size   bigint,
  url         text,
  sort_order  integer not null default 100,
  created_by  uuid references users(id) on delete set null,
  created_at  timestamptz not null default now(),
  constraint marketing_materials_has_target check (
    (kind = 'file' and file_path is not null)
    or (kind = 'link' and url is not null)
  )
);

create index if not exists marketing_materials_product_idx on marketing_materials (product_id, sort_order);

alter table marketing_products  enable row level security;
alter table marketing_materials enable row level security;

drop policy if exists "marketing_products_select" on marketing_products;
drop policy if exists "marketing_products_write"  on marketing_products;
drop policy if exists "marketing_materials_select" on marketing_materials;
drop policy if exists "marketing_materials_write"  on marketing_materials;

-- Everyone logged in can read: an agent in front of a merchant needs the
-- brochure as much as an employee does.
create policy "marketing_products_select" on marketing_products
  for select to authenticated using (true);

create policy "marketing_materials_select" on marketing_materials
  for select to authenticated using (true);

-- Staff only to change. This is the approved collateral.
create policy "marketing_products_write" on marketing_products
  for all to authenticated
  using (current_app_has_perm('fullDashboard'))
  with check (current_app_has_perm('fullDashboard'));

create policy "marketing_materials_write" on marketing_materials
  for all to authenticated
  using (current_app_has_perm('fullDashboard'))
  with check (current_app_has_perm('fullDashboard'));


-- ---------------------------------------------------------------- the pages
insert into marketing_products (name, slug, brand, category, sort_order) values
  ('EPAY Full Service Restaurant', 'epay-full-service-restaurant', 'epay', 'epay', 10),
  ('EPAY Express Restaurant',      'epay-express-restaurant',      'epay', 'epay', 20),
  ('EPAY Retail',                  'epay-retail',                  'epay', 'epay', 30),
  ('EPAY Express Retail',          'epay-express-retail',          'epay', 'epay', 40),
  ('EPAY Smart Terminal',          'epay-smart-terminal',          'epay', 'epay', 50),
  ('EPAY Salon',                   'epay-salon',                   'epay', 'epay', 60),
  ('EPAY Charge',                  'epay-charge',                  'epay', 'epay', 70),
  ('EPAY Health',                  'epay-health',                  'epay', 'epay', 80),
  ('EPAY Lodging',                 'epay-lodging',                 'epay', 'epay', 90),
  ('EPAY Petro',                   'epay-petro',                   'epay', 'epay', 100),
  ('Clover',                       'clover',                       'epay', 'partner', 200),
  ('Genius',                       'genius',                       'epay', 'partner', 210),
  ('NRS',                          'nrs',                          'epay', 'partner', 220),
  ('NCR',                          'ncr',                          'epay', 'partner', 230)
on conflict (slug) do update
  set name = excluded.name,
      category = excluded.category,
      sort_order = excluded.sort_order,
      active = true;


-- ------------------------------------------------------------------ storage
insert into storage.buckets (id, name, public)
values ('marketing-materials', 'marketing-materials', false)
on conflict (id) do nothing;

drop policy if exists "marketing_bucket_read"   on storage.objects;
drop policy if exists "marketing_bucket_write"  on storage.objects;
drop policy if exists "marketing_bucket_update" on storage.objects;
drop policy if exists "marketing_bucket_delete" on storage.objects;

create policy "marketing_bucket_read" on storage.objects
  for select to authenticated
  using (bucket_id = 'marketing-materials');

create policy "marketing_bucket_write" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'marketing-materials' and current_app_has_perm('fullDashboard'));

create policy "marketing_bucket_update" on storage.objects
  for update to authenticated
  using (bucket_id = 'marketing-materials' and current_app_has_perm('fullDashboard'))
  with check (bucket_id = 'marketing-materials' and current_app_has_perm('fullDashboard'));

create policy "marketing_bucket_delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'marketing-materials' and current_app_has_perm('fullDashboard'));

/* =========================================================================
   AFTER RUNNING THIS
     Sidebar -> Resources -> Marketing Materials shows fourteen product
     pages. Open one and upload a PDF or add a link; check an agent login
     can open it and cannot change it.
   ========================================================================= */

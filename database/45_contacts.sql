-- =============================================================================
-- EPAY POS / Envision ATM Control Center — Contacts
-- ---------------------------------------------------------------------------
-- A general business-contacts directory — not a sales pipeline like Leads/
-- Cold Leads/Partners, just a rolodex of people worth keeping track of
-- (manufacturer reps, internal team contacts, anyone else). Filterable
-- between customer-facing and internal/manufacturer contacts. Not brand-
-- restricted — both EPAY POS and Envision ATM share one contact list.
-- Internal-only (fullDashboard), same as Loaders — no portal login has any
-- reason to see this.
-- =============================================================================

create table contacts (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  business_name text,
  phone         text,
  email         text,
  category      text not null default 'customer_facing'
                  check (category in ('customer_facing', 'internal_manufacturer')),
  notes         text,
  created_by    uuid references users(id) on delete set null,
  created_at    timestamptz not null default now()
);
create index on contacts (category);

alter table contacts enable row level security;

create policy "contacts_all" on contacts
  for all to authenticated
  using (current_app_has_perm('fullDashboard'))
  with check (current_app_has_perm('fullDashboard'));

-- =============================================================================
-- EPAY POS / Envision ATM Control Center — Team Structure
-- ---------------------------------------------------------------------------
-- Backs the new "Team Structure" tab: organizes Agents/EPAY Resellers into
-- offices (Chicago, Detroit, New York today, but a real addable list, not
-- hardcoded) via drag-and-drop, alongside the existing recruiting hierarchy
-- (partners.parent_partner_id — already used by the Partners tab's downline
-- view, reused here rather than inventing a second hierarchy concept).
-- =============================================================================

create table offices (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  brand       text not null default 'both' check (brand in ('epay', 'atm', 'both')),
  created_at  timestamptz not null default now()
);

alter table partners add column if not exists office_id uuid references offices(id) on delete set null;

alter table offices enable row level security;

-- Same visibility as partners generally — internal viewAllPartners sees/
-- manages offices; portal logins have no reason to see this at all.
create policy "offices_select" on offices
  for select to authenticated
  using (current_app_has_perm('viewAllPartners'));

create policy "offices_write" on offices
  for all to authenticated
  using (current_app_has_perm('editPartners'))
  with check (current_app_has_perm('editPartners'));

insert into offices (name, brand) values
  ('Chicago', 'both'),
  ('Detroit', 'both'),
  ('New York', 'both');

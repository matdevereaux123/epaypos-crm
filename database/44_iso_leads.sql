-- =============================================================================
-- EPAY POS / Envision ATM Control Center — Envision ISO Leads
-- ---------------------------------------------------------------------------
-- A new, separate pipeline for leads sourced through independent ISOs on the
-- Envision ATM side — distinct from the main `leads` table's ATM board
-- (which already has an 'iso_lead' intake *stage*, but no way to say which
-- ISO actually sent it in). Structured like `lending_leads` (its own simple
-- stage set, own notes tables) but, unlike lending_leads, portal-accessible:
-- each row links to the specific ISO partner who submitted it, mirroring
-- `leads`'s linked_partner_id/assigned_to access model exactly, since an ISO
-- is a portal_scope:'own' login (roles.iso, seeded in 01_schema.sql) who
-- should be able to see their own submissions.
--
-- Also adds 'iso' as a real partners.type value — until now partners.type
-- was only 'referral_partner' | 'agent', so there was no record to link an
-- ISO lead to at all. (Two dead spots in app/index.html — residualPartnerOptions()
-- and buildResidualsSectionHTML() — already checked for a `partner_type`
-- value of 'iso' that could never be set; this migration is what finally
-- makes that real, and the app-code fix renames `partner_type` to the actual
-- `type` column those checks meant to read.)
-- =============================================================================

alter table partners drop constraint if exists partners_type_check;
alter table partners add constraint partners_type_check
  check (type in ('referral_partner', 'agent', 'iso'));

create table iso_leads (
  id                uuid primary key default gen_random_uuid(),
  business_name     text not null,
  contact_name      text,
  phone             text,
  email             text,
  est_volume        text,
  source            text,
  stage             text not null default 'new_lead',
  linked_partner_id uuid references partners(id) on delete set null,
  assigned_to       uuid references users(id) on delete set null,
  created_at        date not null default current_date,
  stage_entered_at  date not null default current_date
);
create index on iso_leads (linked_partner_id);
create index on iso_leads (assigned_to);

create table iso_lead_notes (
  id           uuid primary key default gen_random_uuid(),
  iso_lead_id  uuid not null references iso_leads(id) on delete cascade,
  text         text not null,
  created_by   text not null,
  created_at   date not null default current_date
);

create table iso_lead_call_notes (
  id           uuid primary key default gen_random_uuid(),
  iso_lead_id  uuid not null references iso_leads(id) on delete cascade,
  text         text not null,
  created_by   text not null,
  created_at   date not null default current_date
);

-- ---------------------------------------------------------------------------
-- iso_leads — same shape as leads_select/leads_write: internal fullDashboard
-- sees/edits everything; the linked ISO or whoever it's assigned to sees/
-- edits their own. with check on write omits assigned_to for the same
-- reason leads_write does — reassignment is governed by the trigger below,
-- not by this policy.
-- ---------------------------------------------------------------------------
alter table iso_leads enable row level security;

create policy "iso_leads_select" on iso_leads
  for select to authenticated
  using (
    current_app_has_perm('fullDashboard')
    or linked_partner_id = current_app_linked_partner_id()
    or assigned_to = current_app_user_id()
  );

create policy "iso_leads_write" on iso_leads
  for all to authenticated
  using (
    current_app_has_perm('fullDashboard')
    or linked_partner_id = current_app_linked_partner_id()
    or assigned_to = current_app_user_id()
  )
  with check (
    current_app_has_perm('fullDashboard')
    or linked_partner_id = current_app_linked_partner_id()
  );

-- Reuses the same enforce_assignment_scope() function already governing
-- leads/cold_leads/applications (database/27_assignment_scope.sql) — an ISO
-- can only assign their own leads to themselves or someone in their
-- downline, never to an arbitrary user id.
drop trigger if exists iso_leads_assignment_scope on iso_leads;
create trigger iso_leads_assignment_scope
  before insert or update on iso_leads
  for each row execute function enforce_assignment_scope();

-- ---------------------------------------------------------------------------
-- iso_lead_notes / iso_lead_call_notes — read/add follows lead access,
-- edit/delete internal only. Identical shape to lead_notes/lead_call_notes.
-- ---------------------------------------------------------------------------
alter table iso_lead_notes enable row level security;

create policy "iso_lead_notes_select" on iso_lead_notes
  for select to authenticated
  using (
    exists (
      select 1 from iso_leads l
      where l.id = iso_lead_notes.iso_lead_id
        and (
          current_app_has_perm('fullDashboard')
          or l.linked_partner_id = current_app_linked_partner_id()
          or l.assigned_to = current_app_user_id()
        )
    )
  );

create policy "iso_lead_notes_insert" on iso_lead_notes
  for insert to authenticated
  with check (
    exists (
      select 1 from iso_leads l
      where l.id = iso_lead_notes.iso_lead_id
        and (
          current_app_has_perm('fullDashboard')
          or l.linked_partner_id = current_app_linked_partner_id()
          or l.assigned_to = current_app_user_id()
        )
    )
  );

create policy "iso_lead_notes_update" on iso_lead_notes
  for update to authenticated
  using (current_app_has_perm('fullDashboard'))
  with check (current_app_has_perm('fullDashboard'));

create policy "iso_lead_notes_delete" on iso_lead_notes
  for delete to authenticated
  using (current_app_has_perm('fullDashboard'));

alter table iso_lead_call_notes enable row level security;

create policy "iso_lead_call_notes_select" on iso_lead_call_notes
  for select to authenticated
  using (
    exists (
      select 1 from iso_leads l
      where l.id = iso_lead_call_notes.iso_lead_id
        and (
          current_app_has_perm('fullDashboard')
          or l.linked_partner_id = current_app_linked_partner_id()
          or l.assigned_to = current_app_user_id()
        )
    )
  );

create policy "iso_lead_call_notes_insert" on iso_lead_call_notes
  for insert to authenticated
  with check (
    exists (
      select 1 from iso_leads l
      where l.id = iso_lead_call_notes.iso_lead_id
        and (
          current_app_has_perm('fullDashboard')
          or l.linked_partner_id = current_app_linked_partner_id()
          or l.assigned_to = current_app_user_id()
        )
    )
  );

create policy "iso_lead_call_notes_update" on iso_lead_call_notes
  for update to authenticated
  using (current_app_has_perm('fullDashboard'))
  with check (current_app_has_perm('fullDashboard'));

create policy "iso_lead_call_notes_delete" on iso_lead_call_notes
  for delete to authenticated
  using (current_app_has_perm('fullDashboard'));

-- =============================================================================
-- AFTER RUNNING THIS
--   Add at least one partner with type='iso' (via the app's "Add ISO" flow,
--   see the same commit's app/index.html changes) before trying to create an
--   ISO lead — the lead form's "Submitted by" dropdown is empty otherwise.
-- =============================================================================

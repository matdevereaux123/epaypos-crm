-- =============================================================================
-- EPAY POS / Envision ATM Control Center — dated, attributed notes everywhere
-- ---------------------------------------------------------------------------
-- Run after 74_recruit_assignment.sql. Safe to re-run.
--
-- Leads, partners, ISO leads and lending leads already keep notes as a log:
-- each entry is its own row, stamped with who wrote it and when, and can be
-- deleted but never edited. Everything else (cold leads, loaders, contacts,
-- cold outreach, recruits) had a single free-text box that was overwritten in
-- place — no author, no date, and the previous text simply gone.
--
-- This is one shared table for those, keyed by (entity_type, entity_id).
--
--   Who can read/write: whoever can already see the parent record. The
--   policies ask the parent table, and because that lookup runs as the
--   caller, the parent's own row-level security decides — nothing about who
--   sees a cold lead or a contact is re-stated here.
--
--   Author: stamped by trigger from the signed-in user, never taken from the
--   browser, so an entry cannot be written in someone else's name.
--
--   Delete: the author, or an admin (manageUsers). No update policy at all —
--   same "delete, never edit" rule as the notes on leads.
--
-- Existing free-text notes are copied in as the first entry of each record
-- ("Earlier note"), so nothing that was written is lost. The old columns are
-- left in place, untouched.
-- =============================================================================

create table if not exists record_notes (
  id             uuid primary key default gen_random_uuid(),
  entity_type    text not null
                   check (entity_type in ('cold_lead','loader','contact','cold_outreach','recruit')),
  entity_id      uuid not null,
  text           text not null,
  created_by_id  uuid references users(id) on delete set null,
  created_by     text not null default '',
  created_at     timestamptz not null default now()
);
create index if not exists record_notes_entity_idx on record_notes (entity_type, entity_id, created_at desc);

alter table record_notes enable row level security;

-- plpgsql (not sql) so a table that has not been created yet — cold_outreach
-- and recruit_leads come from later migrations — is only looked at if a note
-- for it is actually being read or written.
create or replace function record_note_parent_visible(p_type text, p_id uuid)
returns boolean
language plpgsql
stable
as $$
begin
  if p_type = 'cold_lead'     then return exists (select 1 from cold_leads   where id = p_id); end if;
  if p_type = 'loader'        then return exists (select 1 from atm_loaders  where id = p_id); end if;
  if p_type = 'contact'       then return exists (select 1 from contacts     where id = p_id); end if;
  if p_type = 'cold_outreach' then return exists (select 1 from cold_outreach where id = p_id); end if;
  if p_type = 'recruit'       then return exists (select 1 from recruit_leads where id = p_id); end if;
  return false;
end;
$$;

create or replace function record_notes_stamp_author()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me   uuid := current_app_user_id();
  v_name text;
begin
  if v_me is not null then
    select coalesce(nullif(trim(name), ''), email) into v_name from users where id = v_me;
    NEW.created_by_id := v_me;
    NEW.created_by    := coalesce(v_name, '');
  end if;
  return NEW;
end;
$$;

drop trigger if exists record_notes_stamp_author on record_notes;
create trigger record_notes_stamp_author
  before insert on record_notes
  for each row execute function record_notes_stamp_author();

drop policy if exists "record_notes_select" on record_notes;
create policy "record_notes_select" on record_notes
  for select to authenticated
  using (record_note_parent_visible(entity_type, entity_id));

drop policy if exists "record_notes_insert" on record_notes;
create policy "record_notes_insert" on record_notes
  for insert to authenticated
  with check (record_note_parent_visible(entity_type, entity_id));

drop policy if exists "record_notes_delete" on record_notes;
create policy "record_notes_delete" on record_notes
  for delete to authenticated
  using (
    created_by_id = current_app_user_id()
    or coalesce(current_app_has_perm('manageUsers'), false)
  );

-- ---------------------------------------------------------------------------
-- Carry over what was already written. Only once per record.
-- ---------------------------------------------------------------------------
insert into record_notes (entity_type, entity_id, text, created_by, created_at)
select 'cold_lead', c.id, trim(c.notes), 'Earlier note', c.created_at::timestamptz
  from cold_leads c
 where nullif(trim(coalesce(c.notes, '')), '') is not null
   and not exists (select 1 from record_notes r where r.entity_type = 'cold_lead' and r.entity_id = c.id);

insert into record_notes (entity_type, entity_id, text, created_by, created_at)
select 'loader', c.id, trim(c.notes), 'Earlier note', c.created_at
  from atm_loaders c
 where nullif(trim(coalesce(c.notes, '')), '') is not null
   and not exists (select 1 from record_notes r where r.entity_type = 'loader' and r.entity_id = c.id);

insert into record_notes (entity_type, entity_id, text, created_by, created_at)
select 'contact', c.id, trim(c.notes), 'Earlier note', c.created_at
  from contacts c
 where nullif(trim(coalesce(c.notes, '')), '') is not null
   and not exists (select 1 from record_notes r where r.entity_type = 'contact' and r.entity_id = c.id);

do $$
begin
  if to_regclass('public.cold_outreach') is not null then
    insert into record_notes (entity_type, entity_id, text, created_by, created_at)
    select 'cold_outreach', c.id, trim(c.notes), 'Earlier note', c.created_at::timestamptz
      from cold_outreach c
     where nullif(trim(coalesce(c.notes, '')), '') is not null
       and not exists (select 1 from record_notes r where r.entity_type = 'cold_outreach' and r.entity_id = c.id);
  end if;
  if to_regclass('public.recruit_leads') is not null then
    insert into record_notes (entity_type, entity_id, text, created_by, created_at)
    select 'recruit', c.id, trim(c.notes), 'Earlier note', c.created_at
      from recruit_leads c
     where nullif(trim(coalesce(c.notes, '')), '') is not null
       and not exists (select 1 from record_notes r where r.entity_type = 'recruit' and r.entity_id = c.id);
  end if;
end $$;

-- =============================================================================
-- AFTER RUNNING THIS
--   Open a cold lead, add a note, and confirm it shows your name and the
--   date and time. Sign in as someone who cannot see that cold lead and
--   confirm they cannot read its notes either.
-- =============================================================================

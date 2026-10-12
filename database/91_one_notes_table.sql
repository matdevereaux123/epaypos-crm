/* =========================================================================
   91_one_notes_table.sql — eight notes tables become one

   lead_notes, lead_call_notes, partner_notes, iso_lead_notes,
   iso_lead_call_notes, lending_lead_notes, lending_lead_call_notes and
   record_notes. The same idea eight times, with identical columns —
   id, <parent>_id, text, created_by, created_at — and three different
   behaviours on screen, because each grew its own widget. Two autosave,
   the rest want a button; one shows the time, the others only the date.

   They all fold into record_notes, which already had the right shape and
   the author-stamping trigger. Two additions: the entity types for the
   records being folded in, and a `kind` so "call notes" stay distinct from
   the general log rather than being merged into one stream.

   WHAT THIS DOES NOT DO
     It does not drop the seven old tables. The rows are copied, keeping
     their original ids, so this file can be run twice without duplicating
     anything and the originals remain readable if something needs
     checking. Dropping them is a separate step, worth taking only once
     the new one has been lived with.
   ========================================================================= */

alter table record_notes add column if not exists kind text not null default 'general';

alter table record_notes drop constraint if exists record_notes_kind_check;
alter table record_notes
  add constraint record_notes_kind_check check (kind in ('general', 'call'));

alter table record_notes drop constraint if exists record_notes_entity_type_check;
alter table record_notes
  add constraint record_notes_entity_type_check
  check (entity_type in ('cold_lead','loader','contact','cold_outreach','recruit',
                         'internal_sales','lead','partner','iso_lead','lending_lead'));

create index if not exists record_notes_entity_kind_idx
  on record_notes (entity_type, entity_id, kind, created_at desc);


-- --------------------------------------------------------------- the move
-- Original ids are kept, which is what makes this safe to re-run: a second
-- pass conflicts on the primary key and does nothing.
insert into record_notes (id, entity_type, entity_id, kind, text, created_by, created_at)
  select id, 'lead',         lead_id,         'general', text, created_by, created_at from lead_notes
  union all
  select id, 'lead',         lead_id,         'call',    text, created_by, created_at from lead_call_notes
  union all
  select id, 'partner',      partner_id,      'general', text, created_by, created_at from partner_notes
  union all
  select id, 'iso_lead',     iso_lead_id,     'general', text, created_by, created_at from iso_lead_notes
  union all
  select id, 'iso_lead',     iso_lead_id,     'call',    text, created_by, created_at from iso_lead_call_notes
  union all
  select id, 'lending_lead', lending_lead_id, 'general', text, created_by, created_at from lending_lead_notes
  union all
  select id, 'lending_lead', lending_lead_id, 'call',    text, created_by, created_at from lending_lead_call_notes
on conflict (id) do nothing;


-- ------------------------------------------------------------- visibility
-- A note is visible to whoever can see the record it is attached to. This
-- function is plain plpgsql and STABLE rather than SECURITY DEFINER, so
-- each exists() below runs under the caller's own policies — the note
-- inherits the parent's visibility rather than restating it, which is why
-- there is nothing here about owners or assignment.
create or replace function record_note_parent_visible(p_type text, p_id uuid)
returns boolean
language plpgsql
stable
as $$
begin
  if p_type = 'cold_lead'     then return exists (select 1 from cold_leads    where id = p_id); end if;
  if p_type = 'loader'        then return exists (select 1 from atm_loaders   where id = p_id); end if;
  if p_type = 'contact'       then return exists (select 1 from contacts      where id = p_id); end if;
  if p_type = 'cold_outreach' then return exists (select 1 from cold_outreach where id = p_id); end if;
  if p_type = 'recruit'       then return exists (select 1 from recruit_leads where id = p_id); end if;
  if p_type = 'lead'          then return exists (select 1 from leads         where id = p_id); end if;
  if p_type = 'partner'       then return exists (select 1 from partners      where id = p_id); end if;
  if p_type = 'iso_lead'      then return exists (select 1 from iso_leads     where id = p_id); end if;
  if p_type = 'lending_lead'  then return exists (select 1 from lending_leads where id = p_id); end if;

  if p_type = 'internal_sales' then
    return exists (
      select 1 from users u
       where u.id = p_id
         and (
           coalesce(current_app_has_perm('manageUsers'), false)
           or u.id = current_app_user_id()
           or u.manager_id = current_app_user_id()
         )
    );
  end if;

  return false;
end;
$$;

comment on table record_notes is
  'Every dated, attributed note in the CRM. entity_type says what it is attached to, kind separates call notes from the general log. Replaced seven per-record tables (database/91_one_notes_table.sql); those still exist, unread, until they are dropped.';

/* =========================================================================
   AFTER RUNNING THIS
     Counts should match. Each old table against its slice of the new one:

       select 'lead general' as what, count(*) from lead_notes
       union all select 'moved', count(*) from record_notes
          where entity_type = 'lead' and kind = 'general';

     Then open a lead, a partner, an ISO lead and a lending lead: the notes
     that were there should still be there, with the same dates and
     authors.
   ========================================================================= */

/* =========================================================================
   85_internal_sales_notes.sql — dated notes on an internal sales person

   Referral partners and agents already have an activity log (partner_notes);
   internal sales people had one free-text box on their pay record, which
   anyone could overwrite and which never said who wrote it or when.

   Rather than a third notes table, this extends the generic one from
   database/75_record_notes.sql with an 'internal_sales' entity type keyed
   on users.id. Its author stamping, its RLS and its delete rule all come
   along unchanged.

   Visibility follows the person: you can note on yourself, on anyone who
   reports to you, and on anybody at all if you manage users — the same
   line internal_sales_comp draws (database/79_ownership_scoping.sql), so a
   note cannot be read by somebody who cannot see the person it is about.
   ========================================================================= */

alter table record_notes drop constraint if exists record_notes_entity_type_check;
alter table record_notes
  add constraint record_notes_entity_type_check
  check (entity_type in ('cold_lead','loader','contact','cold_outreach','recruit','internal_sales'));

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

  -- The person themselves, their manager, or whoever manages users. Mirrors
  -- internal_sales_comp_select so a note is never readable by somebody who
  -- cannot see the person it is written about.
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

/* =========================================================================
   AFTER RUNNING THIS
     Open someone under Internal Sales — the note box at the top of the
     drawer saves as you type, and each note lands below it with the
     author's email and the time.
   ========================================================================= */

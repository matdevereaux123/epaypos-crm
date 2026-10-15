/* =========================================================================
   79_ownership_scoping.sql — Recruiting, Partners, Agents/ISOs and
   Internal Sales become owner-scoped

   Until now these four were all-or-nothing: anyone with viewAllPartners saw
   every partner and agent, and Recruiting was admin-only. The rule from here
   is the one the pipeline already follows — you see what is yours, and an
   admin sees everything.

   "Yours" means assigned to you, or created by you. Both, because a record
   you entered and have not assigned to anyone yet must not vanish from under
   you the moment you save it.

   The switch for seeing everyone's is the EXISTING viewAllPartners
   permission rather than a new one. It already means "view all partner
   records", it is already in the per-person grants list
   (database/70_internal_management_and_grants.sql), and one switch for
   "can you see other people's people" is easier to reason about than three.

   Note what this changes for In House Sales: that role had viewAllPartners
   by default, so today those users see every partner and agent. After this
   they see their own. Granting it back to one person is two clicks in
   Settings -> Users; this only changes the default.

   Internal Sales is scoped by the reporting line rather than assignment,
   because it already has one: users.manager_id, shown in the UI as
   "Reports to". A manager sees the people who report to them.
   ========================================================================= */

-- ------------------------------------------------------------- partners
-- Referral Partners and Agents/ISOs are both rows here; `type` separates
-- them, so one set of columns and one policy covers both tabs.
alter table partners add column if not exists assigned_to     uuid references users(id) on delete set null;
alter table partners add column if not exists assigned_to_ids uuid[] not null default '{}'::uuid[];
alter table partners add column if not exists created_by      uuid references users(id) on delete set null;

create index if not exists partners_assigned_idx on partners (assigned_to);
create index if not exists partners_created_by_idx on partners (created_by);

alter table recruit_leads add column if not exists assigned_to uuid references users(id) on delete set null;


-- Whoever adds a record owns it unless they say otherwise. Without this a
-- rep who adds a partner and does not touch the assignment field cannot see
-- what they just typed in, which is the sort of thing that makes people
-- stop using the tool.
create or replace function stamp_record_owner()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := current_app_user_id();
begin
  if v_me is null then
    return NEW;
  end if;
  if NEW.created_by is null then
    NEW.created_by := v_me;
  end if;
  if NEW.assigned_to is null then
    NEW.assigned_to := v_me;
  end if;
  return NEW;
end;
$$;

drop trigger if exists partners_stamp_owner on partners;
create trigger partners_stamp_owner
  before insert on partners
  for each row execute function stamp_record_owner();

drop trigger if exists recruit_leads_stamp_owner on recruit_leads;
create trigger recruit_leads_stamp_owner
  before insert on recruit_leads
  for each row execute function stamp_record_owner();


-- Everything that already exists stays with whoever entered it, and
-- anything with no creator on record becomes unassigned — visible to admins
-- only, rather than silently landing on one person's desk.
update partners set assigned_to = created_by
 where assigned_to is null and created_by is not null;

update recruit_leads set assigned_to = created_by
 where assigned_to is null and created_by is not null;


-- ---------------------------------------------------------------- policies
drop policy if exists "partners_select" on partners;
create policy "partners_select" on partners
  for select to authenticated
  using (
    current_app_has_perm('viewAllPartners')
    -- A portal login still sees its own partner row and its downline: that
    -- is what the agent portal IS, and it predates this file
    -- (database/26_downline_visibility.sql).
    or id = current_app_linked_partner_id()
    or current_partner_has_in_downline(id)
    or assigned_to = current_app_user_id()
    or created_by = current_app_user_id()
    or current_app_user_id() = ANY(assigned_to_ids)
  );

-- Write follows sight. editPartners alone used to be enough to update any
-- row, including ones the same user could not select — a rep could change a
-- partner they were not allowed to look at.
drop policy if exists "partners_write" on partners;
create policy "partners_write" on partners
  for all to authenticated
  using (
    current_app_has_perm('editPartners')
    and (
      current_app_has_perm('viewAllPartners')
      or id = current_app_linked_partner_id()
      or assigned_to = current_app_user_id()
      or created_by = current_app_user_id()
      or current_app_user_id() = ANY(assigned_to_ids)
    )
  )
  with check (
    current_app_has_perm('editPartners')
    and (
      current_app_has_perm('viewAllPartners')
      or id = current_app_linked_partner_id()
      or assigned_to = current_app_user_id()
      or created_by = current_app_user_id()
      or current_app_user_id() = ANY(assigned_to_ids)
    )
  );


-- Recruiting was manageUsers-only, so it opens up here rather than closing
-- down: whoever is working a recruit can now see and edit that recruit.
drop policy if exists "recruit_leads_all" on recruit_leads;
drop policy if exists "recruit_leads_select" on recruit_leads;
drop policy if exists "recruit_leads_write" on recruit_leads;

create policy "recruit_leads_select" on recruit_leads
  for select to authenticated
  using (
    current_app_has_perm('viewAllPartners')
    or assigned_to = current_app_user_id()
    or created_by = current_app_user_id()
    or current_app_user_id() = ANY(assigned_to_ids)
  );

create policy "recruit_leads_write" on recruit_leads
  for all to authenticated
  using (
    current_app_has_perm('viewAllPartners')
    or assigned_to = current_app_user_id()
    or created_by = current_app_user_id()
    or current_app_user_id() = ANY(assigned_to_ids)
  )
  with check (
    current_app_has_perm('viewAllPartners')
    or assigned_to = current_app_user_id()
    or created_by = current_app_user_id()
    or current_app_user_id() = ANY(assigned_to_ids)
  );


-- Internal Sales: your own pay, your team's pay if they report to you, and
-- everyone's if you manage users. Deliberately the reporting line and not
-- assignment — a salary belongs to a manager, not to whoever happens to be
-- working the record.
drop policy if exists "internal_sales_comp_select" on internal_sales_comp;
create policy "internal_sales_comp_select" on internal_sales_comp
  for select to authenticated
  using (
    current_app_has_perm('manageUsers')
    or user_id = current_app_user_id()
    or exists (
      select 1 from users u
       where u.id = internal_sales_comp.user_id
         and u.manager_id = current_app_user_id()
    )
  );


-- --------------------------------------------------- the default for staff
-- In House Sales keeps everything else it had; only the "see every partner"
-- half goes, which is the whole point of the change. Admin is untouched, and
-- any individual can have it granted back per person in Settings -> Users.
update roles
   set perms = perms - 'viewAllPartners' || '{"viewAllPartners": false}'::jsonb
 where key = 'in_house_sales';


comment on column partners.assigned_to is
  'Who owns this partner. Set on insert by stamp_record_owner() when not given. Scopes visibility unless the viewer has viewAllPartners (database/79_ownership_scoping.sql).';

/* =========================================================================
   AFTER RUNNING THIS
     select name, type, assigned_to, created_by from partners order by name;

   Rows with both null are visible to admins only until someone is assigned.
   ========================================================================= */

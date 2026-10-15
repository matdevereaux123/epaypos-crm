-- =============================================================================
-- EPAY POS / Envision ATM Control Center — seeing your own downline
-- ---------------------------------------------------------------------------
-- Run after 25_encrypt_lead_sensitive.sql.
--
-- partners_select in 04_rls.sql allows viewAllPartners, or your own record,
-- and nothing else. An agent who recruits other agents therefore cannot see
-- the people reporting to them — partners.parent_partner_id exists and the
-- Team Structure hierarchy is built on it, but RLS never took it into account.
--
-- This adds recursive downline access: you can see anyone beneath you in the
-- recruiting tree, at any depth.
--
-- WHAT THIS DELIBERATELY DOES NOT DO
-- Downline access covers the partner record and its application details. It
-- does NOT extend to the encrypted fields — an upline agent cannot reveal a
-- downline's SSN, date of birth, driver's licence or payout banking. Those
-- stay with the person themselves and staff holding viewBanking/viewSensitive.
-- Recruiting someone is not a reason to see their social security number.
--
-- The RPCs enforce that independently (current_partner_is_own is an identity
-- check, not a hierarchy one), so no change is needed there — but it is worth
-- being explicit that the split is intended rather than an oversight.
-- =============================================================================


-- Everyone beneath p_partner_id in the recruiting tree.
-- The depth cap is a guard against a cycle: parent_partner_id is a plain
-- self-reference with nothing stopping A -> B -> A, and without a bound that
-- would recurse until the statement was killed.
create or replace function partner_downline_ids(p_partner_id uuid)
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  with recursive tree as (
    select id, 1 as depth
      from partners
     where parent_partner_id = p_partner_id
    union all
    select p.id, t.depth + 1
      from partners p
      join tree t on p.parent_partner_id = t.id
     where t.depth < 20
  )
  select id from tree;
$$;

revoke execute on function partner_downline_ids(uuid) from public;
revoke execute on function partner_downline_ids(uuid) from anon;
grant execute on function partner_downline_ids(uuid) to authenticated;


-- Is p_partner_id somewhere beneath the caller's own partner record?
create or replace function current_partner_has_in_downline(p_partner_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
      from users u
     where u.auth_id = auth.uid()
       and u.linked_partner_id is not null
       and p_partner_id in (select partner_downline_ids(u.linked_partner_id))
  );
$$;

revoke execute on function current_partner_has_in_downline(uuid) from public;
revoke execute on function current_partner_has_in_downline(uuid) from anon;
grant execute on function current_partner_has_in_downline(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- Reading a partner: staff, your own record, or anyone in your downline.
-- Writing is untouched — an upline can see their downline, not edit them.
-- ---------------------------------------------------------------------------
drop policy if exists "partners_select" on partners;

create policy "partners_select" on partners
  for select to authenticated
  using (
    current_app_has_perm('viewAllPartners')
    or id = current_app_linked_partner_id()
    or current_partner_has_in_downline(id)
  );


-- ---------------------------------------------------------------------------
-- Notes follow the record, same as before, now including the downline.
-- ---------------------------------------------------------------------------
drop policy if exists "partner_notes_select" on partner_notes;

create policy "partner_notes_select" on partner_notes
  for select to authenticated
  using (
    exists (
      select 1 from partners p
      where p.id = partner_notes.partner_id
        and (
          current_app_has_perm('viewAllPartners')
          or p.id = current_app_linked_partner_id()
          or current_partner_has_in_downline(p.id)
        )
    )
  );


-- ---------------------------------------------------------------------------
-- Documents: an upline can see WHAT is on file against their downline, which
-- is useful for chasing a missing admit packet. Opening the file itself stays
-- with staff and the person concerned, since a signed agreement carries the
-- same personal details the encrypted columns hold.
-- ---------------------------------------------------------------------------
drop policy if exists "partner_documents_select" on partner_documents;

create policy "partner_documents_select" on partner_documents
  for select to authenticated
  using (
    current_app_has_perm('viewAllPartners')
    or partner_id = current_app_linked_partner_id()
    or current_partner_has_in_downline(partner_id)
  );


-- =============================================================================
-- AFTER RUNNING THIS
--   Log in as an agent with someone beneath them and confirm they can see that
--   person's record and application, and that revealing the downline's SSN or
--   banking still refuses. Both halves matter.
-- =============================================================================

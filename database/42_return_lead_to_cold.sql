-- =============================================================================
-- EPAY POS / Envision ATM Control Center — sending a lead back to cold
-- ---------------------------------------------------------------------------
-- Run after 41_dual_brand_leads.sql.
--
-- promoteColdLead() has always moved a cold lead up into the pipeline. There
-- was no way back, so a lead that went quiet either sat in a stage forever or
-- got deleted.
--
-- DELETING WOULD HAVE BEEN THE WRONG ANSWER
--
-- lead_notes, lead_call_notes and lead_documents are all
-- `on delete cascade`. Deleting the lead would take the entire call history
-- and every uploaded document with it, silently, in an action a person would
-- reasonably read as "move this back to the other list". Whoever picks the
-- business up again in six months would find nothing.
--
-- So nothing is deleted. The lead is stamped as returned and drops out of the
-- pipeline; the record, its notes and its documents all stay. Promote it
-- again and the same lead comes back with its history intact.
-- =============================================================================

alter table leads
  -- Set when the lead is sent back; null means it is in play. Nullable rather
  -- than a boolean so it also answers "when".
  add column if not exists returned_to_cold_at timestamptz,
  -- Which cold lead it came from, so sending it back updates that record
  -- rather than creating a second one for the same business.
  add column if not exists from_cold_lead_id uuid references cold_leads(id) on delete set null;

create index if not exists leads_returned_idx on leads (returned_to_cold_at)
  where returned_to_cold_at is not null;
create index if not exists leads_from_cold_idx on leads (from_cold_lead_id)
  where from_cold_lead_id is not null;

-- The other half of the link. A cold lead that has been promoted can find its
-- lead again, which is what lets a re-promote reuse the existing record
-- instead of starting a third copy of the same business.
alter table cold_leads
  add column if not exists promoted_lead_id uuid references leads(id) on delete set null;

create index if not exists cold_leads_promoted_lead_idx on cold_leads (promoted_lead_id)
  where promoted_lead_id is not null;


-- ---------------------------------------------------------------------------
-- Backfill the link for pairs that already exist.
--
-- Matched on business name within a brand, which is the only signal there is
-- for records created before the column existed. Deliberately narrow: only
-- where exactly one cold lead and one lead share a name, so an ambiguous
-- match is left unlinked rather than joined to the wrong business. Anything
-- missed simply creates a fresh cold lead on the way back, which is the old
-- behaviour and is safe.
-- ---------------------------------------------------------------------------
with pairs as (
  select c.id as cold_id, l.id as lead_id
    from cold_leads c
    join leads l
      on lower(trim(l.business_name)) = lower(trim(c.business_name))
     and (l.brand = c.brand or l.brand = 'both' or c.brand = 'both')
   where c.promoted = true
),
unambiguous as (
  select cold_id, min(lead_id) as lead_id
    from pairs
   group by cold_id
  having count(*) = 1
)
update cold_leads c
   set promoted_lead_id = u.lead_id
  from unambiguous u
 where c.id = u.cold_id
   and c.promoted_lead_id is null;

update leads l
   set from_cold_lead_id = c.id
  from cold_leads c
 where c.promoted_lead_id = l.id
   and l.from_cold_lead_id is null;


-- =============================================================================
-- AFTER RUNNING THIS
--   Open any lead and use "Send back to cold leads". It should leave the
--   pipeline and appear on the Cold Leads list. Open it there, promote it
--   again, and confirm the notes and documents are still on it — that is the
--   whole point of not deleting.
--
--   To see what has been sent back:
--     select business_name, returned_to_cold_at from leads
--      where returned_to_cold_at is not null;
-- =============================================================================

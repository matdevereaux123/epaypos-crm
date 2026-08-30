-- =============================================================================
-- EPAY POS / Envision ATM Control Center — agent ID
-- ---------------------------------------------------------------------------
-- Run after 42_return_lead_to_cold.sql.
--
-- The identifier an agent is known by outside this system — on processor
-- statements, in commission files, in the conversation when they ring up
-- about a payout. Until now the only shared reference was their name, which
-- is neither unique nor what anyone else's paperwork uses.
--
-- Typed in, not generated. It has to match whatever the processor already
-- calls them; a number this system invented would be a second identifier
-- nobody else recognises, which is worse than none.
--
-- Visible to the agent. That is the point — it is their reference too, and an
-- ID only one side can see does not settle anything. partners is already
-- readable by a portal login for their own row, so this comes along with it.
-- =============================================================================

alter table partners
  add column if not exists agent_id text;

-- Normalised on the way in: trimmed, uppercased, blank stored as null.
-- 'ag-1042 ' and 'AG-1042' are the same agent, and a lookup that misses
-- because of a trailing space is the kind of thing nobody debugs, they just
-- conclude the ID does not work.
create or replace function partners_normalise_agent_id()
returns trigger
language plpgsql
as $$
begin
  new.agent_id := nullif(upper(trim(coalesce(new.agent_id, ''))), '');
  return new;
end;
$$;

drop trigger if exists partners_agent_id_trg on partners;
create trigger partners_agent_id_trg
  before insert or update on partners
  for each row execute function partners_normalise_agent_id();

update partners set agent_id = agent_id where agent_id is not null;

-- Unique, because the whole value of an ID is that it points at one person.
-- Partial so the many partners without one do not collide with each other.
create unique index if not exists partners_agent_id_unique
  on partners (agent_id) where agent_id is not null;


-- =============================================================================
-- AFTER RUNNING THIS
--   Open an agent from Partners / Sales Team and set their Agent ID with the
--   pencil. It then shows on their record, on the residual payout report
--   beside their name, and in their own portal — confirm that last one by
--   previewing as them.
--
--   Two agents cannot share an ID; the second save is refused by the index
--   rather than quietly overwriting.
-- =============================================================================

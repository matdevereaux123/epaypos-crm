-- =============================================================================
-- EPAY POS / Envision ATM Control Center — Collections
-- ---------------------------------------------------------------------------
-- Backs the new "In collections" toggle on the Account detail drawer and
-- the Collections report under Reports. Lives on `leads` since Accounts
-- are converted_to_account=true rows on that same table, not a separate one.
-- =============================================================================

alter table leads
  add column if not exists in_collections boolean not null default false,
  add column if not exists collections_marked_at date,
  add column if not exists collections_marked_by text,
  add column if not exists collections_note text;

create index on leads (in_collections);

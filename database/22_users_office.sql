-- =============================================================================
-- EPAY POS / Envision ATM Control Center — in-house staff belong to offices too
-- ---------------------------------------------------------------------------
-- Run after 21_application_links.sql.
--
-- Team Structure only ever placed PARTNERS with type = 'agent' — external
-- commission agents. In-house sales people are USERS with an internal role,
-- a different table, and had nowhere to sit: partners.office_id existed,
-- users.office_id did not.
--
-- This adds it so the board can hold both, and a card can say which it is.
-- =============================================================================

alter table users
  add column if not exists office_id uuid references offices(id) on delete set null;

create index if not exists users_office_id_idx on users (office_id);

-- =============================================================================
-- NOTE ON WHO CAN MOVE PEOPLE
-- users_write in 04_rls.sql gates on manageUsers, so only an admin can change
-- a user's office. Dragging an in-house card as anyone else will fail at the
-- database rather than silently appearing to work — which is the correct
-- outcome, but worth knowing when testing.
-- =============================================================================

-- =============================================================================
-- 97 - What a site still has to tell us before it opens.
--
-- Boarding takes a name, an owner, an address, an edition and a rate — enough
-- to create the account, nowhere near enough to run a shift. The rest has
-- always been collected by somebody ringing the merchant and writing it on a
-- pad: is there a kitchen, how many tills, what prints on the receipt, where
-- the menu is coming from. That is the part that decides whether an install
-- takes a day or three weeks, and it had no home.
--
-- A column rather than a table. The answers are a bag of key/value pairs that
-- only ever belong to one merchant and are only ever read all at once; a table
-- would be a join and a migration every time a question is added.
--
-- Safe to run twice.
-- =============================================================================

alter table pos_merchants
  add column if not exists setup_answers jsonb not null default '{}'::jsonb;

comment on column pos_merchants.setup_answers is
  'Answers to the setup questionnaire, keyed by question id. Questions that '
  'do not apply to this merchant are absent rather than null — a bar has no '
  'kitchen answer because it was never asked.';

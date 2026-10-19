-- =============================================================================
-- 107 - Moving a lead past Application without one in hand.
--
-- The Application stage will not let a lead move on until an application is
-- attached to it. That rule is right nearly always: the next stage is App ID
-- Entered, and an App ID has to come from somewhere.
--
-- Nearly always is not always. A merchant boards on paper, or the application
-- is sitting in somebody's inbox, or the deal is being worked ahead of the
-- paperwork. The honest answer is not to loosen the rule for everyone, but to
-- let somebody step over it deliberately and leave their name on it.
--
-- Hence two columns rather than a boolean: who, and when. A waiver that
-- cannot be attributed is indistinguishable from a rule that was never there.
-- Clearing both columns puts the lead back behind the gate.
--
-- Safe to run twice.
-- =============================================================================

alter table leads
  add column if not exists application_waived_at timestamptz,
  add column if not exists application_waived_by uuid references users(id) on delete set null;

comment on column leads.application_waived_at is
  'Set when somebody moved this lead past the Application stage without an '
  'application attached. Null means the normal rule applies.';
comment on column leads.application_waived_by is
  'Who stepped over the rule. Kept separate from created_by/assigned_to: it '
  'is an exception, not ownership.';

-- An index is not worth it for a column this sparse; the app reads it one
-- lead at a time, from a row it already has.

-- =============================================================================
-- EPAY POS / Envision ATM Control Center — leads that belong to both brands
-- ---------------------------------------------------------------------------
-- Run after 40_atm_loaders.sql.
--
-- A shop that wants card processing AND a cash machine is one business, and
-- until now it had to be entered twice — two records, two sets of contact
-- details, drifting apart the moment either was edited.
--
-- WHY LEADS NEED A SECOND STAGE COLUMN AND COLD LEADS DO NOT
--
-- The two brands do not share a pipeline. EPAY POS runs eleven stages ending
-- in Converted/Active; Envision ATM runs seven ending in Installation. They
-- are different processes with different meanings, deliberately kept apart.
--
-- So a lead in both brands is at two places at once — perhaps Application on
-- the EPAY board while its ATM placement is still Finding Loader. One `stage`
-- column cannot hold that. leads gets atm_stage: `stage` always means the
-- EPAY position, `atm_stage` always the ATM one, whatever the brand says.
--
-- Cold leads have no pipeline at all — a temperature and a promoted flag,
-- nothing brand-specific. One row genuinely is enough there, and adding a
-- second column would be inventing a distinction that does not exist.
--
-- The alternative was two linked rows per business. Rejected: switching a
-- lead back to a single brand would then mean deleting the other row and
-- everything recorded against it. With one row the pipelines simply stop
-- being shown, and turning the brand back on finds the work exactly where it
-- was left.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1. leads
-- ---------------------------------------------------------------------------
alter table leads add column if not exists atm_stage text;

-- Existing ATM leads keep their pipeline position, moved to the column that
-- now owns it. Their `stage` is left holding an ATM key otherwise, and the
-- day one of them is switched to 'both' the EPAY board would filter on a
-- stage it has never heard of — the lead would not error, it would silently
-- not appear anywhere. That is the worst of the available failures.
update leads
   set atm_stage = stage,
       stage     = 'inbound_lead'
 where brand = 'atm'
   and atm_stage is null;

-- EPAY leads have no ATM position yet; give them the entry stage so switching
-- one to 'both' puts it at the front of the ATM board rather than nowhere.
update leads set atm_stage = 'inbound_placement' where atm_stage is null;

alter table leads alter column atm_stage set default 'inbound_placement';
alter table leads alter column atm_stage set not null;

-- Tracked separately so "how long has this sat here?" stays answerable per
-- pipeline. A lead can be moving on one board and stuck on the other.
alter table leads add column if not exists atm_stage_entered_at date;
update leads set atm_stage_entered_at = coalesce(stage_entered_at, current_date)
 where atm_stage_entered_at is null;
alter table leads alter column atm_stage_entered_at set default current_date;

alter table leads drop constraint if exists leads_brand_check;
alter table leads add constraint leads_brand_check
  check (brand in ('epay', 'atm', 'both'));

create index if not exists leads_atm_stage_idx on leads (brand, atm_stage);


-- ---------------------------------------------------------------------------
-- 2. cold_leads — nothing but the constraint, for the reason in the header
-- ---------------------------------------------------------------------------
alter table cold_leads drop constraint if exists cold_leads_brand_check;
alter table cold_leads add constraint cold_leads_brand_check
  check (brand in ('epay', 'atm', 'both'));


-- =============================================================================
-- AFTER RUNNING THIS
--   Check the ATM leads still sit where they did — their positions moved
--   columns, so this is worth eyeballing rather than assuming:
--
--     select business_name, brand, stage, atm_stage from leads where brand = 'atm';
--
--   Every row should show its old ATM stage in atm_stage and 'inbound_lead'
--   in stage. Then open the ATM Leads board and confirm the columns look the
--   same as they did before.
-- =============================================================================

-- Adds a manually-editable Quote # field to Cold Leads. Leads already has
-- one (leads.quote_number, added separately) — this brings Cold Leads to
-- parity. Not wired to any intake form yet on purpose; the field just needs
-- to exist for now.
alter table cold_leads add column if not exists quote_number text;

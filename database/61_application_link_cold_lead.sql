-- Applications could only ever attach to a lead/account (linked_account_id).
-- The new "search and attach" widget on the Cold Lead drawer needs the same
-- for cold leads.
alter table applications add column if not exists linked_cold_lead_id uuid references cold_leads(id) on delete set null;
create index if not exists applications_linked_cold_lead_idx on applications (linked_cold_lead_id);

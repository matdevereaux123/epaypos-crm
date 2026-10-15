-- Adds NRS, NCR, and third-party-integration/gateway as POS station
-- choices alongside the existing EPAY/Clover options on the Initial
-- Outreach / Equipment & Pricing Confirm stages.
alter table leads add column if not exists nrs_device text;
alter table leads add column if not exists ncr_price numeric(10,2);
alter table leads add column if not exists third_party_name text;
alter table leads add column if not exists third_party_price numeric(10,2);

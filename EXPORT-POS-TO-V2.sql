-- =============================================================================
-- MOVING THE POS ROWS OUT OF THE CONTROL CENTER
--
-- RUN THIS IN THE CRM PROJECT. It changes nothing: it reads the pos_* tables
-- and prints the INSERT statements that will recreate them in V2.
--
-- Then copy the one column it returns and run that in the EPAY V2 project.
--
-- WHY A PRINTOUT RATHER THAN A TOOL
-- Two projects cannot query each other, so something has to carry the rows
-- across. A printout is the version you can read before you run it: every
-- row is visible, nothing needs a service key, and no credential for one
-- project is ever handed to the other.
--
-- WHAT COMES ACROSS
-- Merchants, their locations, their devices, the agreements they accepted,
-- any per-account settings, and the relationship notes. Ids are preserved,
-- so leads.pos_merchant_id in the Control Center still points at the right
-- business afterwards.
--
-- WHAT DOES NOT
-- pos_plans, pos_addons and pos_terms. V2 has its own, seeded in step 4 with
-- the corrections already in them - the real capability ids, no capability on
-- the three delivery links, EPAY Connect not sellable, Kiosk priced. Copying
-- the CRM's would undo all of that.
--
-- pos_support_sessions. Short-lived tokens; anything live has expired by the
-- time you read this.
-- =============================================================================

with lines as (
  select 0 as ord, 1 as seq,
         '-- Paste this into the EPAY V2 project. Safe to run twice.' as sql
  union all
  select 0, 2, '-- Generated ' || now()::date || ' from the Control Center.'

  -- Merchants ---------------------------------------------------------------
  union all
  select 1, 0, '' union all select 1, 1, '-- Merchants'
  union all
  select 1, 2, format(
    'insert into public.pos_merchants (id, dba, legal_name, status, owner_name, owner_email, '
    'owner_phone, phone, website, street, city, state, zip, rep, mid, tax_id, crm_lead_id, '
    'setup_answers, created_at) values (%L, %L, %L, %L, %L, %L, %L, %L, %L, %L, %L, %L, %L, '
    '%L, %L, %L, %L, %L::jsonb, %L) on conflict (id) do nothing;',
    m.id, m.dba, m.legal_name, m.status, m.owner_name, m.owner_email, m.owner_phone,
    m.phone, m.website, m.street, m.city, m.state, m.zip, m.rep, m.mid, m.tax_id,
    -- The lead this came from. Looked up rather than taken from the merchant,
    -- because the link lives on leads in this project.
    (select l.id from leads l where l.pos_merchant_id = m.id limit 1),
    coalesce(m.setup_answers, '{}'::jsonb)::text, m.created_at)
  from pos_merchants m

  -- Locations ---------------------------------------------------------------
  union all
  select 2, 0, '' union all select 2, 1, '-- Locations'
  union all
  select 2, 2, format(
    'insert into public.pos_locations (id, merchant_id, name, street, city, state, zip, '
    'edition, plan_key, add_ons, pricing_mode, dual_pricing_ppm, dual_pricing_fixed_cents, '
    'tax_ppm, created_at) values (%L, %L, %L, %L, %L, %L, %L, %L, %L, %L::text[], %L, %s, '
    '%s, %s, %L) on conflict (id) do nothing;',
    l.id, l.merchant_id, l.name, l.street, l.city, l.state, l.zip, l.edition, l.plan_key,
    coalesce(l.add_ons, '{}')::text, l.pricing_mode,
    coalesce(l.dual_pricing_ppm, 0), coalesce(l.dual_pricing_fixed_cents, 0),
    coalesce(l.tax_ppm, 0), l.created_at)
  from pos_locations l

  -- Devices -----------------------------------------------------------------
  union all
  select 3, 0, '' union all select 3, 1, '-- Devices'
  union all
  select 3, 2, format(
    'insert into public.pos_devices (id, location_id, label, kind, paired_at, last_seen_at, '
    'created_at) values (%L, %L, %L, %L, %L, %L, %L) on conflict (id) do nothing;',
    -- Pairing codes are deliberately left behind: a code in flight when the
    -- move happens is one nobody should be able to redeem afterwards.
    d.id, d.location_id, d.label, d.kind, d.paired_at, d.last_seen_at, d.created_at)
  from pos_devices d

  -- Agreements --------------------------------------------------------------
  union all
  select 4, 0, '' union all select 4, 1, '-- Agreements. Append-only; the price is the one that was shown.'
  union all
  select 4, 2, format(
    'insert into public.pos_addon_agreements (id, merchant_id, location_id, addon_key, '
    'price_cents, terms_version, accepted_by, accepted_email, accepted_in, accepted_at, '
    'cancelled_at, cancelled_by) values (%L, %L, %L, %L, %s, %L, %L, %L, %L, %L, %L, %L) '
    'on conflict (id) do nothing;',
    a.id, a.merchant_id, a.location_id, a.addon_key,
    coalesce(a.price_cents::text, 'null'), a.terms_version, a.accepted_by, a.accepted_email,
    a.accepted_in, a.accepted_at, a.cancelled_at, a.cancelled_by)
  from pos_addon_agreements a

  -- Per-account settings ----------------------------------------------------
  union all
  select 5, 0, '' union all select 5, 1, '-- Per-account settings. Platform defaults are already in V2.'
  union all
  select 5, 2, format(
    'insert into public.pos_config (merchant_id, scope, key, value, label, sort, updated_at, '
    'updated_by) values (%L, %L, %L, %L::jsonb, %L, %s, %L, %L) on conflict do nothing;',
    c.merchant_id, c.scope, c.key, c.value::text, c.label, coalesce(c.sort, 0),
    c.updated_at, c.updated_by)
  from pos_config c where c.merchant_id is not null

  -- Relationship notes ------------------------------------------------------
  union all
  select 6, 0, '' union all select 6, 1, '-- Relationship notes. EPAY''s record, not the merchant''s.'
  union all
  select 6, 2, format(
    'insert into public.pos_merchant_notes (id, merchant_id, kind, body, by_name, created_at) '
    'values (%L, %L, %L, %L, %L, %L) on conflict (id) do nothing;',
    n.id, n.merchant_id, n.kind, n.body, n.by_name, n.created_at)
  from pos_merchant_notes n

  -- The referral offer ------------------------------------------------------
  union all
  select 7, 0, '' union all select 7, 1, '-- The referral offer. One row, updated rather than inserted.'
  union all
  select 7, 2, format(
    'update public.pos_referral_offer set running = %L, pitch = %L, tiers = %L::jsonb '
    'where id = true;',
    o.running, o.pitch, coalesce(o.tiers, '[]'::jsonb)::text)
  from pos_referral_offer o

  union all
  select 9, 0, '' union all
  select 9, 1, '-- Check, after running the above:'
  union all
  select 9, 2, '--   select (select count(*) from pos_merchants) as merchants,'
  union all
  select 9, 3, '--          (select count(*) from pos_locations) as locations,'
  union all
  select 9, 4, '--          (select count(*) from pos_addon_agreements) as agreements;'
)
select string_agg(sql, E'\n' order by ord, seq) as paste_into_v2
from lines;

-- =============================================================================
-- EPAY POS / Envision ATM Control Center — public referral landing page
-- ---------------------------------------------------------------------------
-- Backs the "?ref=<slug>" page (renderReferralLandingPage() /
-- submitReferralLead() in app/index.html) — the page a merchant lands on
-- after clicking a partner's custom referral link. Unlike every other RPC
-- in this project, this one runs for a visitor who was NEVER logged in at
-- all, so it's granted to the `anon` role instead of `authenticated`.
--
-- Both tables involved (partners, leads, lead_notes) have RLS policies
-- scoped to `authenticated` only — anon has zero direct access to them.
-- Rather than writing separate anon RLS policies (which would need very
-- careful WITH CHECK clauses to stop an anonymous caller from reading other
-- partners' data or writing arbitrary lead fields), both operations this
-- page needs are wrapped as narrow SECURITY DEFINER functions that do their
-- own validation and only expose exactly what the page needs.
-- =============================================================================

-- Looks up just enough about a partner to render the landing page (name,
-- brand — for the logo) without exposing anything else on the partners row
-- (email, phone, banking, leads_submitted, etc.) to an anonymous caller.
create or replace function public_lookup_referral_partner(p_slug text)
returns table (id uuid, name text, brand text)
language sql
security definer
set search_path = public
as $$
  select id, name, brand from partners where link_slug = p_slug;
$$;
grant execute on function public_lookup_referral_partner(text) to anon;

-- Submits the landing page form as a real Lead, attributed to the referring
-- partner — same shape as submitReferralLead() used to build client-side.
-- Brand is derived from the partner's own record server-side (never trusts
-- a client-supplied brand), and every column written is one this specific
-- form is meant to set — nothing else on `leads` is reachable through this.
create or replace function public_submit_referral_lead(
  p_partner_id uuid,
  p_business_name text,
  p_contact_name text,
  p_phone text,
  p_email text,
  p_business_address text,
  p_est_volume text,
  p_notes text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_partner partners%rowtype;
  v_brand text;
  v_lead_id uuid;
begin
  select * into v_partner from partners where id = p_partner_id;
  if not found then
    raise exception 'Unknown referral partner';
  end if;
  if p_business_name is null or trim(p_business_name) = '' or p_contact_name is null or trim(p_contact_name) = '' then
    raise exception 'Business name and contact name are required';
  end if;

  v_brand := case when v_partner.brand = 'atm' then 'atm' else 'epay' end;

  insert into leads (
    brand, business_name, contact_name, phone, email, business_address,
    est_volume, stage, lead_source, linked_partner_id
  ) values (
    v_brand, trim(p_business_name), trim(p_contact_name),
    coalesce(nullif(trim(p_phone), ''), '—'),
    coalesce(nullif(trim(p_email), ''), '—'),
    trim(coalesce(p_business_address, '')),
    trim(coalesce(p_est_volume, '')),
    'inbound_lead', 'Referral link — ' || v_partner.name, p_partner_id
  ) returning id into v_lead_id;

  if p_notes is not null and trim(p_notes) <> '' then
    insert into lead_notes (lead_id, text, created_by)
    values (v_lead_id, 'Submitted via referral link: "' || trim(p_notes) || '"', 'referral-link');
  end if;

  update partners set leads_submitted = leads_submitted + 1 where id = p_partner_id;

  return v_lead_id;
end;
$$;
grant execute on function public_submit_referral_lead(uuid, text, text, text, text, text, text, text) to anon;

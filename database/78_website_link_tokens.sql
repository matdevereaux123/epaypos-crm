/* =========================================================================
   72_website_link_tokens.sql — the slugs epaypos.net posts with

   The public website has two forms that write straight into this database:
   the enquiry form on every page, and the merchant application at /sign-up.
   Both take a p_slug, and both resolve it against application_link_tokens —
   NOT partners.link_slug. Partner slugs belong to the referral landing pages
   at /r/<slug> (public_submit_referral_lead, database/12_public_referral.sql),
   which is a different door into the same pipeline.

   A token carries three things the submission needs: which brand the record
   belongs to, which partner (if any) to credit, and a label that becomes the
   lead's source line. It also counts its own submissions, which is what makes
   "how much did the website bring in" answerable without a partner record
   standing in for the website.

   Deliberately NOT a partner record for the website itself. Partners are
   people we pay and whose productivity we report on; a partner row for our
   own site would show up in payout screens, referral stats and the partner
   dropdowns on every lead. The token already gives the attribution.
   ========================================================================= */

-- 1. Enquiry forms on epaypos.net  ->  content/application.json: crm.lead_slug
insert into application_link_tokens (slug, label, brand, kind, is_active)
values ('website', 'EPAY POS Website', 'epay', 'lead', true)
on conflict (slug) do update
  set label = excluded.label,
      brand = excluded.brand,
      kind  = excluded.kind,
      is_active = true;

-- 2. Merchant application at epaypos.net/sign-up  ->  crm.slug
insert into application_link_tokens (slug, label, brand, kind, is_active)
values ('website-signup', 'EPAY POS Website — Sign Up', 'epay', 'application', true)
on conflict (slug) do update
  set label = excluded.label,
      brand = excluded.brand,
      kind  = excluded.kind,
      is_active = true;

-- 3. Palm Tree Pay Tech's referrals from the website
--    -> content/partners.json: partners[].lead_slug
--
-- Linked to the partner row so these leads count toward their productivity
-- the same way their /r/ link does. If no such partner exists yet the token
-- is still created, unattributed, and the notice below says so — an enquiry
-- landing with no credit is recoverable, a form that 500s is not.
do $$
declare
  v_partner_id uuid;
begin
  select id into v_partner_id
    from partners
   where name ilike '%palm tree%'
   order by created_at
   limit 1;

  insert into application_link_tokens (slug, label, brand, kind, is_active, partner_id)
  values ('palm-tree-pay-tech', 'Palm Tree Pay Tech — Website', 'epay', 'lead', true, v_partner_id)
  on conflict (slug) do update
    set label = excluded.label,
        brand = excluded.brand,
        kind  = excluded.kind,
        is_active = true,
        partner_id = coalesce(excluded.partner_id, application_link_tokens.partner_id);

  if v_partner_id is null then
    raise notice 'No partner matching "Palm Tree" — the palm-tree-pay-tech link was created WITHOUT partner credit. Add the partner in the CRM, then re-run this file to attach it.';
  else
    raise notice 'palm-tree-pay-tech linked to partner %', v_partner_id;
  end if;
end $$;


-- What the website should be configured with.
select slug, label, kind, brand, partner_id, is_active, submissions
  from application_link_tokens
 where slug in ('website', 'website-signup', 'palm-tree-pay-tech')
 order by kind, slug;

/* =========================================================================
   AFTER RUNNING THIS
     content/application.json   crm.lead_slug = "website"
                                crm.slug      = "website-signup"
     content/partners.json      Palm Tree Pay Tech lead_slug = "palm-tree-pay-tech"

   Enquiries arrive as leads at Inbound Lead with lead_source
   "Lead form — EPAY POS Website". Applications arrive in the Applications
   tab with the six sensitive fields encrypted on the way in.
   ========================================================================= */

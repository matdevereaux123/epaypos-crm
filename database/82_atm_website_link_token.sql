/* =========================================================================
   82_atm_website_link_token.sql — the slug envisionatm.org posts with

   The sibling of database/78_website_link_tokens.sql, for the other brand.
   Same mechanism: p_slug resolves against application_link_tokens, and the
   token's `brand` is what decides which side of the Leads tab a submission
   lands on. public_submit_lead_form reads it directly:

       v_brand := case when v_token.brand = 'atm' then 'atm' else 'epay' end;

   so brand = 'atm' here is the whole of what makes these Envision ATM
   leads. Nothing on the website needs to say so.

   The ATM pipeline's first stage comes for free: leads.atm_stage is NOT
   NULL with a default of 'inbound_placement' (database/41_dual_brand_leads.sql),
   so a lead inserted without one starts at the front of the ATM board
   rather than nowhere.

   partner_id is left null deliberately — see the note at the foot.
   ========================================================================= */

insert into application_link_tokens (slug, label, brand, kind, is_active)
values ('envisionatm', 'Envision ATM Website', 'atm', 'lead', true)
on conflict (slug) do update
  set label = excluded.label,
      brand = excluded.brand,
      kind  = excluded.kind,
      is_active = true;

select slug, label, kind, brand, partner_id, created_by, is_active, submissions
  from application_link_tokens
 where slug in ('envisionatm', 'website')
 order by brand;

/* =========================================================================
   AFTER RUNNING THIS
     content/site.json   crm.lead_slug = "envisionatm"

   Enquiries arrive on the Envision ATM side of the Leads tab at Inbound /
   Placement, with lead_source "Lead form — Envision ATM Website".

   WHO OWNS THEM
     partner_id and created_by are both null, so these leads arrive
     unassigned. That is the right default for a website enquiry — nobody
     earned it yet — and it is what makes them visible to internal staff:
     In House Sales sees leads that came in through a form precisely
     BECAUSE they have no creator (database/58). Assigning the link to one
     person would hand them every enquiry the site ever takes and hide them
     from everyone else.

     To change that later, set partner_id (credits a partner, as the Palm
     Tree link does) or created_by (makes one user the owner):

       update application_link_tokens
          set partner_id = '<partners.id>'
        where slug = 'envisionatm';
   ========================================================================= */

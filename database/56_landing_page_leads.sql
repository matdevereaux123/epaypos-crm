-- =============================================================================
-- EPAY POS / Envision ATM Control Center — landing page leads into Cold Leads
-- ---------------------------------------------------------------------------
-- Run after 55_notifications.sql.
--
-- The four EPAY landing pages (consumerchoice / statementreview /
-- epaybonussignup / freeposstation .epaypos.net) email every form submission
-- to sales@. This makes each submission a Cold Lead as well, so nobody has to
-- retype it from the inbox.
--
-- Same shape as public_book_slot (53/55): a SECURITY DEFINER function granted
-- to anon, so the landing pages can call it with the public anon key while
-- cold_leads itself stays closed to anonymous access. The function only ever
-- inserts or appends to a cold lead and notifies one user — it cannot read
-- anything back.
--
-- WHO IT GOES TO
--
-- Assigned to, and notifies, the user whose CRM login email is
-- LANDING_LEAD_OWNER_EMAIL below. If that user doesn't exist the lead still
-- lands, unassigned and without a notification, rather than being lost.
--
-- TEMPERATURE
--
-- 'hot' when the merchant uploaded a statement (the page sends a Quote
-- Number), otherwise 'warm' — same as a booking-link lead.
--
-- REPEAT SUBMISSIONS
--
-- The same email from the same page on the same day appends to that cold
-- lead's notes instead of creating a second row. Merchants do resubmit —
-- usually after trying a different statement — and two records for one
-- business is exactly what the promote / return-to-cold links in 42 exist to
-- avoid.
-- =============================================================================

create or replace function public_submit_landing_lead(
  p_page     text,   -- the page's "Lead Source" value, e.g. 'Statement Analysis Landing Page'
  p_name     text,
  p_business text,
  p_phone    text,
  p_email    text,
  p_details  jsonb   -- [["Label","value"], ...] — everything else the form sent, in order
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  LANDING_LEAD_OWNER_EMAIL constant text := 'matthew@envisionprocessing.com';

  v_owner    uuid;
  v_source   text;
  v_hot      boolean := false;
  v_quote    text;
  v_fees     text;
  v_notes    text := '';
  v_pair     jsonb;
  v_label    text;
  v_value    text;
  v_existing uuid;
  v_id       uuid;
begin
  -- Only the four pages we publish. Anything else is someone calling the
  -- endpoint by hand.
  if p_page not in (
    'Consumer Choice Program Landing Page',
    'Statement Analysis Landing Page',
    '$3,000 Switch Bonus Landing Page',
    'Free Placement Program Landing Page'
  ) then
    raise exception 'Unknown landing page';
  end if;

  if coalesce(trim(p_name), '') = '' or coalesce(trim(p_business), '') = ''
     or coalesce(trim(p_phone), '') = '' or coalesce(trim(p_email), '') = '' then
    raise exception 'Name, business, phone and email are required';
  end if;

  if length(p_name) > 200 or length(p_business) > 200
     or length(p_phone) > 40 or length(p_email) > 254 then
    raise exception 'Field too long';
  end if;

  if p_details is not null and jsonb_typeof(p_details) <> 'array' then
    raise exception 'Details must be a list';
  end if;

  v_source := 'Landing page — ' || regexp_replace(p_page, ' Landing Page$', '');

  -- Details become the notes, one "Label: value" per line.
  for v_pair in select * from jsonb_array_elements(coalesce(p_details, '[]'::jsonb)) limit 40 loop
    continue when jsonb_typeof(v_pair) <> 'array' or jsonb_array_length(v_pair) <> 2;
    v_label := left(trim(v_pair->>0), 60);
    v_value := left(trim(v_pair->>1), 1000);
    continue when v_label = '' or v_value = '';
    v_notes := v_notes || v_label || ': ' || v_value || E'\n';
    if v_label = 'Quote Number' then v_hot := true; v_quote := v_value; end if;
    if v_label = 'Statement Monthly Fees' then v_fees := v_value; end if;
  end loop;
  v_notes := left(rtrim(v_notes, E'\n'), 6000);

  select id into v_owner from users where lower(email) = lower(LANDING_LEAD_OWNER_EMAIL);

  select id into v_existing
    from cold_leads
   where lower(email) = lower(trim(p_email))
     and source = v_source
     and created_at = current_date
     and promoted = false
   order by id
   limit 1;

  if v_existing is not null then
    update cold_leads
       set notes = left(coalesce(notes || E'\n\n', '') ||
                        '— Resubmitted ' || to_char(now() at time zone 'America/Detroit', 'HH12:MI AM') || E' —\n' ||
                        v_notes, 12000),
           temperature = case when v_hot then 'hot' else temperature end,
           phone = trim(p_phone),
           contact_name = trim(p_name)
     where id = v_existing;
    v_id := v_existing;
  else
    insert into cold_leads (
      brand, business_name, contact_name, phone, email,
      source, source_category, temperature, notes, assigned_to
    ) values (
      'epay',
      trim(p_business),
      trim(p_name),
      trim(p_phone),
      trim(p_email),
      v_source,
      'marketing',
      case when v_hot then 'hot' else 'warm' end,
      nullif(v_notes, ''),
      v_owner
    ) returning id into v_id;
  end if;

  if v_owner is not null then
    insert into notifications (user_id, type, title, body, link_view, link_id)
    values (
      v_owner,
      'landing_lead',
      case when v_existing is not null then 'Resubmitted: ' else 'New lead: ' end || trim(p_business),
      regexp_replace(p_page, ' Landing Page$', '') ||
        coalesce(' · Quote ' || v_quote, '') ||
        coalesce(' · ' || v_fees || '/mo in fees', ''),
      'coldleads',
      v_id
    );
  end if;

  return v_id;
end;
$$;

revoke execute on function public_submit_landing_lead(text, text, text, text, text, jsonb) from public;
grant execute on function public_submit_landing_lead(text, text, text, text, text, jsonb) to anon, authenticated;

-- Check after running:
--   select public_submit_landing_lead('Statement Analysis Landing Page',
--     'TEST - delete me', 'TEST BUSINESS', '5555550100', 'test@example.com',
--     '[["Quote Number","EPAY-TEST-0000"],["Statement Monthly Fees","$1,284.57"]]');
--   select * from cold_leads where business_name = 'TEST BUSINESS';
--   delete from cold_leads where business_name = 'TEST BUSINESS';

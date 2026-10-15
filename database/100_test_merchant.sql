-- =============================================================================
-- 100 - One merchant to look at.
--
-- Something to open while the first real one is still a phone call away: every
-- screen in the Back End reads better with a business in it than with an empty
-- state, and an empty state is a poor way to judge a layout.
--
-- Deliberately obvious. "TEST —" in the name, an invented MID, and a phone
-- number in 555, so nobody mistakes it for a real account or rings it. Delete
-- it with the line at the bottom when you have a real one.
--
-- Safe to run twice: it does nothing if the test merchant is already there.
-- =============================================================================

do $$
declare m_id uuid; l_id uuid;
begin
  if exists (select 1 from pos_merchants where dba = 'TEST — Maple Street Grill') then
    raise notice 'The test merchant is already here. Nothing to do.';
    return;
  end if;

  insert into pos_merchants (dba, legal_name, status, owner_name, owner_email, owner_phone,
                             phone, street, city, state, zip, rep, mid, setup_answers)
  values ('TEST — Maple Street Grill', 'Maple Street Hospitality LLC', 'live',
          'Dana Ruiz', 'dana@example.test', '(248) 555-0142',
          '(248) 555-0100', '412 Maple Rd', 'Troy', 'MI', '48084',
          'Matthew', '4445019277310',
          -- Part filled on purpose: the Setup page is duller when everything
          -- is answered, and the point of it is showing what is outstanding.
          '{"receiptName":"Maple Street Grill","receiptPhone":"(248) 555-0100",
            "serviceStyle":"Table service","hasKitchen":true,"kitchenScreens":1,
            "areas":"Main dining, Patio, Bar","runsTabs":true,
            "stations":2,"cardTerminals":2}'::jsonb)
  returning id into m_id;

  insert into pos_locations (merchant_id, name, street, city, state, zip, edition,
                             dual_pricing_ppm, dual_pricing_fixed_cents, tax_ppm)
  values (m_id, 'Main dining', '412 Maple Rd', 'Troy', 'MI', '48084', 'restaurant',
          39900, 0, 60000)
  returning id into l_id;

  -- A second shop, on its own rate, so the Locations tab shows what it is for.
  insert into pos_locations (merchant_id, name, street, city, state, zip, edition,
                             dual_pricing_ppm, dual_pricing_fixed_cents, tax_ppm)
  values (m_id, 'Patio bar', '412 Maple Rd', 'Troy', 'MI', '48084', 'restaurant',
          0, 25, 60000);

  insert into pos_devices (location_id, kind, label, last_seen_at) values
    (l_id, 'station',       'Station 1',       now() - interval '4 minutes'),
    (l_id, 'station',       'Station 2',       now() - interval '9 minutes'),
    (l_id, 'handheld',      'Handheld 1',      now() - interval '2 hours'),
    (l_id, 'kds',           'Kitchen display', now() - interval '6 minutes'),
    -- Never checked in: the state a device is in between being added here
    -- and being switched on in the shop.
    (l_id, 'card-terminal', 'Card terminal 2', null);

  insert into pos_merchant_notes (merchant_id, kind, body, by_name) values
    (m_id, 'call',    'Dana asked about adding a patio section. Walked her through it.', 'Matthew'),
    (m_id, 'support', 'Replaced the receipt printer paper roll holder on Station 2.',    'Support desk'),
    (m_id, 'system',  'Merchant account created.',                                       'System');
end $$;

-- To remove it again:
--   delete from pos_merchants where dba = 'TEST — Maple Street Grill';
-- Locations, devices and notes go with it.

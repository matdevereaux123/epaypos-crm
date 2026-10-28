-- =============================================================================
-- 124 - Mitch has no partner row, so there is nothing for an ISO to see.
--
-- Found at the end of the 120 trail. Two things came back empty:
--
--   * no partner row exists under any spelling of Cochran, Mitch, Palm or Tree
--   * NOT ONE partner in the system has parent_partner_id set
--
-- So the ISO hierarchy was never populated. 120 is correct and had nothing to
-- walk, which is why it reported zero and looked like a policy failure. His
-- real downline is the four in_house_sales reps who report to him through
-- users.manager_id, and 109 has been serving those correctly all along.
--
-- What is genuinely missing is the partner record itself. Without it he has no
-- referral link, no residual split - the new Pay column on the Agents page
-- will read "Not set" for him forever, because there is no row to set it on -
-- and nowhere to attach a sub-agent when he recruits one.
--
-- ------------------------------------------------------------------- BRAND
-- Set to 'epay' because his address is mitch@epaypos.net. If he sells ATMs
-- too, change it to 'both' before running - brand decides which side's leads
-- and links he gets, and it is one word:
--
--      v_brand text := 'epay';
--
-- WHAT THIS DOES NOT DO. It invents no residual split and no banking
-- details - those are money, and they get entered by you in the UI, not
-- guessed in a migration. It creates one row, joins his login to it, and
-- stops. His leads, accounts and notes are untouched.
--
-- Safe to run twice: if he already has a partner row it changes nothing.
-- =============================================================================

do $$
declare
  v_brand   text := 'epay';
  v_user    users;
  v_partner uuid;
  v_slug    text;
begin
  select * into v_user from users where lower(email) = 'mitch@epaypos.net';
  if v_user.id is null then
    raise exception 'No user with mitch@epaypos.net - check the address first.';
  end if;

  if v_user.linked_partner_id is not null then
    raise notice 'Already linked to partner %, nothing to do.', v_user.linked_partner_id;
    return;
  end if;

  -- link_slug is unique and not null; this mirrors the pattern the app uses.
  v_slug := 'mitchell-cochran-' || floor(random() * 900 + 100)::text;
  while exists (select 1 from partners where link_slug = v_slug) loop
    v_slug := 'mitchell-cochran-' || floor(random() * 900 + 100)::text;
  end loop;

  insert into partners (name, contact, email, type, brand, link_slug, status)
  values ('Mitchell Cochran', 'Mitchell Cochran', v_user.email,
          'agent', v_brand, v_slug, 'active')
  returning id into v_partner;

  update users set linked_partner_id = v_partner where id = v_user.id;

  raise notice 'Created partner % (%) and linked his login.', v_partner, v_slug;
end $$;

-- His access, end to end. agents_under_them stays 0 until you parent his
-- sub-agents to this row in the UI - that is the data entry 120 was waiting
-- for, not a permission.
select u.name, u.role, p.name as partner_row, p.link_slug, p.brand,
       coalesce(p.residual_percentage, '(not set - enter in the UI)') as split,
       (select count(*) from users d where d.manager_id = u.id)             as employees_reporting,
       (select count(*) from partners c where c.parent_partner_id = p.id)  as agents_under_them
  from users u
  left join partners p on p.id = u.linked_partner_id
 where lower(u.email) = 'mitch@epaypos.net';

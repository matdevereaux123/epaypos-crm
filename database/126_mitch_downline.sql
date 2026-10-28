-- =============================================================================
-- 126 - Put Mitch's sub-agents under him.
--
-- 120 gave an ISO the right to see their downline's work and found no downline
-- to walk: no partner in the system has parent_partner_id set. 124 gave Mitch
-- the partner row he was missing. This is the last piece - saying who is under
-- him - and it is the only one that needs a fact from you rather than from the
-- database.
--
-- IMPORTANT: there may be nothing to create. Ten partner rows already exist
-- with nobody logging in as them and no parent set:
--
--     Chanh Pham            Elliot Terner        elvis credit cards
--     Elvis Swift cash      imperial ATMs        Jeff burton
--     Nat ATM               Nick lagrange        Toby ATM guy
--     Toby cc and ATM guy
--
-- If any of those are his recruits, this parents the existing row rather than
-- making a second one - which matters, because the leads already attached to
-- that row become visible to him the moment it is parented. A duplicate row
-- would leave the history behind.
--
-- ----------------------------------------------------------------- TO USE
-- Put his agents' names in the list below, exactly as you would type them.
-- A name that already exists as a partner is parented. A name that does not
-- is created and parented. Spelling does not have to be perfect - the match
-- is case-insensitive and ignores punctuation - but it does have to be the
-- same person.
--
--     v_agents text[] := array['Jeff burton', 'Nat ATM'];   <- example
--
-- Leave the list empty and this file does nothing except print the candidates
-- at the end, so it is safe to run now just to see them.
-- =============================================================================

do $$
declare
  v_agents text[] := array[]::text[];   -- <<< his agents go here
  v_mitch   uuid;
  v_name    text;
  v_match   uuid;
  v_hits    int;
  v_slug    text;
begin
  select linked_partner_id into v_mitch
    from users where lower(email) = 'mitch@epaypos.net';
  if v_mitch is null then
    raise exception 'Mitch has no partner row - run 124 first.';
  end if;

  if array_length(v_agents, 1) is null then
    raise notice 'No names given, nothing changed. See the list below.';
    return;
  end if;

  foreach v_name in array v_agents loop
    select count(*), min(id) into v_hits, v_match
      from partners
     where lower(regexp_replace(name, '[^a-zA-Z0-9]', '', 'g'))
         = lower(regexp_replace(v_name, '[^a-zA-Z0-9]', '', 'g'));

    if v_hits > 1 then
      raise exception '% matches % partner rows - be more specific.', v_name, v_hits;
    end if;

    if v_hits = 1 then
      -- Already here. Parent it, keeping whatever leads it already carries.
      if v_match = v_mitch then
        raise exception 'Refusing to make % its own parent.', v_name;
      end if;
      update partners set parent_partner_id = v_mitch where id = v_match;
      raise notice 'Parented existing partner % under Mitch.', v_name;
    else
      v_slug := lower(regexp_replace(v_name, '[^a-zA-Z0-9]+', '-', 'g'))
                || '-' || floor(random() * 900 + 100)::text;
      while exists (select 1 from partners where link_slug = v_slug) loop
        v_slug := lower(regexp_replace(v_name, '[^a-zA-Z0-9]+', '-', 'g'))
                  || '-' || floor(random() * 900 + 100)::text;
      end loop;

      insert into partners (name, contact, type, brand, link_slug, status,
                            parent_partner_id)
      values (v_name, v_name, 'agent', 'epay', v_slug, 'active', v_mitch);
      raise notice 'Created % under Mitch (%).', v_name, v_slug;
    end if;
  end loop;
end $$;

-- Candidates: partner rows with no parent and nobody logging in as them.
-- Any of these that are Mitch's go in the list above.
select p.name, p.type, p.reseller_type, p.link_slug,
       (select count(*) from leads l where l.linked_partner_id = p.id) as leads_on_it,
       coalesce(p.residual_percentage, '(no split)')                   as split
  from partners p
 where p.parent_partner_id is null
   and not exists (select 1 from users u where u.linked_partner_id = p.id)
 order by p.name;

-- What Mitch can actually reach once they are parented.
select pa.name as agent, pa.link_slug,
       (select count(*) from leads l where l.linked_partner_id = pa.id) as their_leads
  from partners pa
 where pa.parent_partner_id = (select linked_partner_id from users
                                where lower(email) = 'mitch@epaypos.net')
 order by pa.name;

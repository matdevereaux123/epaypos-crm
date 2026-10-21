-- =============================================================================
-- 113 - A library of referral offers, instead of the one.
--
-- pos_referral_offer is a single row whose primary key can only be true. That
-- was right when there was one offer: the merchant portal reads that row, and
-- one row cannot be ambiguous about which offer is running.
--
-- What it cannot do is let somebody draft the Q1 push while the Christmas one
-- is still live, keep last year's to copy from, or put an offer back without
-- retyping its tiers. Every one of those meant editing the live offer in
-- place, in front of every merchant.
--
-- So: a library of named offers here, and the singleton stays exactly what it
-- is - the published one, the only thing the portal reads. Publishing copies
-- an offer into it. The portal's contract does not change at all, which
-- matters because the portal is deployed from a bundle this repo does not
-- build.
--
-- Safe to run twice.
-- =============================================================================

create table if not exists pos_referral_offers (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  -- Same shape as the singleton, so publishing is a copy and not a mapping.
  pitch        text not null default 'Know another owner? Send them your link.',
  -- [{ id, signups, kind, label, detail }] - kind is cash | credit | waiver | other.
  tiers        jsonb not null default '[]'::jsonb,
  -- True for the one that was last published. Not a constraint: it is a
  -- record of what happened, and the singleton is the authority on what is
  -- live. Two rows claiming it would be a bug worth seeing rather than one
  -- the database hides.
  is_published boolean not null default false,
  published_at timestamptz,
  created_by   uuid references users(id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index if not exists pos_referral_offers_published_idx
  on pos_referral_offers (is_published) where is_published;

alter table pos_referral_offers enable row level security;

-- Read by anyone signed in, written by EPAY admins - the same pair the
-- singleton uses, so moving between them does not move the boundary.
drop policy if exists "pos_referral_offers_read" on pos_referral_offers;
create policy "pos_referral_offers_read" on pos_referral_offers
  for select to authenticated using (true);

drop policy if exists "pos_referral_offers_write" on pos_referral_offers;
create policy "pos_referral_offers_write" on pos_referral_offers
  for all to authenticated
  using (current_user_is_epay_admin())
  with check (current_user_is_epay_admin());

-- The offer that is live right now becomes the first entry, so the library
-- opens with the real thing in it rather than empty, and nobody has to retype
-- what is already running. Once only: the guard is the name.
insert into pos_referral_offers (name, pitch, tiers, is_published, published_at)
select 'Current offer', o.pitch, o.tiers, true, now()
  from pos_referral_offer o
 where o.id
   and not exists (select 1 from pos_referral_offers);

comment on table pos_referral_offers is
  'Named referral offers to draft, keep and reuse. pos_referral_offer holds '
  'the published one and is the only thing the merchant portal reads.';

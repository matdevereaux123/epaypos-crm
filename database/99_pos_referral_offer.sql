-- =============================================================================
-- 99 - What EPAY pays a merchant for a referral.
--
-- Read by every merchant portal, set here. Deliberately a record rather than
-- something written into the code: the offer changes — a quarter-end push, a
-- seasonal double bonus, a pause while finance catches up — and an offer that
-- needs a release to change is an offer that goes stale. The first a merchant
-- hears of that is a reward that does not arrive.
--
-- NOT THE SAME AS partners
-- `partners` are referral partners, agents and ISOs who send EPAY leads and
-- earn residuals. This is a live merchant pointing a friend at EPAY and being
-- thanked for it. Related, and not the same relationship: one is a commercial
-- agreement, the other is a thank-you with tiers.
--
-- ONE ROW, ENFORCED
-- There is one offer at a time. A table that can hold two is a table that will,
-- and then every merchant portal has to decide which one it believes.
--
-- Safe to run twice.
-- =============================================================================

create table if not exists pos_referral_offer (
  id         boolean primary key default true,
  -- The one-row guard: the primary key can only ever be true.
  constraint pos_referral_offer_single check (id),
  -- Off while EPAY is between offers. The merchant portal says so rather
  -- than showing tiers nobody will honour.
  running    boolean not null default true,
  -- One line under the heading, so staff can change the pitch without a
  -- release.
  pitch      text not null default 'Know another owner? Send them your link.',
  -- [{ id, signups, kind, label, detail }] — kind is cash | credit | waiver | other.
  -- A list rather than columns because the number of tiers is the thing that
  -- changes most often.
  tiers      jsonb not null default '[]'::jsonb,
  updated_by text,
  updated_at timestamptz not null default now()
);

insert into pos_referral_offer (id) values (true) on conflict (id) do nothing;

alter table pos_referral_offer enable row level security;

-- Read by anybody signed in — a merchant portal has to be able to show the
-- offer. Changed only by an EPAY admin.
drop policy if exists "pos_referral_offer_read" on pos_referral_offer;
create policy "pos_referral_offer_read" on pos_referral_offer
  for select to authenticated using (true);

drop policy if exists "pos_referral_offer_write" on pos_referral_offer;
create policy "pos_referral_offer_write" on pos_referral_offer
  for all to authenticated
  using (current_user_is_epay_admin())
  with check (current_user_is_epay_admin());

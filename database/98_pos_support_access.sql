-- =============================================================================
-- 98 - Opening a merchant's own portal, as support.
--
-- The merchant portal is on its own domain, deliberately: a different origin
-- means a merchant can never reach anything belonging to EPAY or the Control
-- Center. The cost of that boundary is that "Visit portal" cannot be a link —
-- the CRM's session does not travel, and should not.
--
-- So a token. EPAY mints one for a named merchant, the portal redeems it once,
-- and both ends write down that it happened.
--
-- WHY SINGLE USE AND SHORT LIVED
-- A token that opens somebody's business is a password for their business. One
-- that sits in a browser history, a chat message or a support ticket for a
-- week is a standing door into a merchant's sales. Minutes, and once.
--
-- WHY IT IS LOGGED ON THE MERCHANT'S RECORD
-- "EPAY staff opened your portal" is exactly the kind of thing a merchant is
-- entitled to see. The relationship log already holds everything else that was
-- done to their account; this belongs beside it, not in a separate place only
-- EPAY reads.
--
-- Safe to run twice.
-- =============================================================================

create table if not exists pos_support_sessions (
  id           uuid primary key default gen_random_uuid(),
  merchant_id  uuid not null references pos_merchants(id) on delete cascade,
  -- Random, long, and never derived from anything. Compared, never shown
  -- again after it is handed over.
  token        text not null unique,
  issued_to    uuid references users(id) on delete set null,
  issued_name  text not null,
  issued_at    timestamptz not null default now(),
  -- Minutes. A token still valid tomorrow is a door somebody forgot to shut.
  expires_at   timestamptz not null,
  -- Set the moment it is redeemed. A second attempt finds this and is refused.
  used_at      timestamptz,
  -- What the merchant's portal saw when it let somebody in.
  used_ip      text
);
create index if not exists pos_support_sessions_merchant_idx
  on pos_support_sessions (merchant_id, issued_at desc);

comment on table pos_support_sessions is
  'Short-lived single-use tokens letting EPAY staff open a merchant''s own '
  'portal. The merchant portal is a different origin, so the Control Center '
  'session cannot travel and a token is how access crosses the boundary.';

-- ---------------------------------------------------------------------------
-- Only an EPAY admin may mint or read one. The merchant portal redeems with
-- the service role from its own server, not as a signed-in user, so it is not
-- covered by this policy and does not need to be.
-- ---------------------------------------------------------------------------
alter table pos_support_sessions enable row level security;

drop policy if exists "pos_support_sessions_epay_admin" on pos_support_sessions;
create policy "pos_support_sessions_epay_admin" on pos_support_sessions
  for all to authenticated
  using (current_user_is_epay_admin())
  with check (current_user_is_epay_admin());

-- =============================================================================
-- AFTER RUNNING THIS
--
-- Nothing changes on screen yet. The Visit portal button mints a row here;
-- the merchant portal redeems it, and that half lands with the portal's own
-- deployment.
--
--   select count(*) from pos_support_sessions;   -- 0, expected
-- =============================================================================

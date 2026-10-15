-- =============================================================================
-- EPAY POS / Envision ATM Control Center — monthly residual payouts
-- ---------------------------------------------------------------------------
-- Run after 38_calendar_ownership.sql.
--
-- partners.residual_percentage already records what split someone is on. It
-- says nothing about what they were actually paid. This is the ledger: one
-- row per partner per month, entered here, readable by that partner in their
-- portal and by nobody else.
--
-- ON THE MONEY COLUMNS BEING numeric
--
-- Every other money field in this schema is text — commission_value,
-- monthly_sales_average, highest_sale_amount — because they are free-form
-- notes a person typed and nothing adds them up.
--
-- These are different and are deliberately typed. They get summed for a
-- year-to-date total, sorted, and compared against what was actually paid. In
-- text, '900' sorts above '1000', '1,200.00' will not cast, and a fat-fingered
-- 'l200' is stored happily and silently breaks every total that touches it.
-- An agent's earnings is the wrong place to find that out.
--
-- ON WHO CAN SEE WHAT
--
-- An agent sees their own rows. Not their downline's — a manager knowing what
-- their own downline earns is a business decision nobody has made, and the
-- safe default for someone else's pay is no. There is deliberately no
-- partner_downline_ids() clause here, unlike the leads policies.
--
-- Agents cannot write. Not "the UI does not offer it" — the policy does not
-- permit it. Someone editing their own payout record is the one thing this
-- table exists to make impossible.
-- =============================================================================

create table if not exists residual_payouts (
  id             uuid primary key default gen_random_uuid(),
  partner_id     uuid not null references partners(id) on delete cascade,

  -- Always the first of the month. A month is a period, not a day, and
  -- storing an arbitrary day within it makes "the same month" a comparison
  -- nobody gets right twice.
  period_month   date not null,

  merchant_count integer,
  gross_residual numeric(12,2),
  adjustments    numeric(12,2) not null default 0,
  net_payout     numeric(12,2) not null,

  status         text not null default 'pending' check (status in ('pending','paid')),
  paid_on        date,
  reference      text,          -- cheque number, ACH reference, however it went out
  notes          text,

  created_by     uuid references users(id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

-- One row per partner per month. Without this, re-running an upload silently
-- doubles everybody's year-to-date.
create unique index if not exists residual_payouts_partner_month_idx
  on residual_payouts (partner_id, period_month);

create index if not exists residual_payouts_month_idx  on residual_payouts (period_month desc);
create index if not exists residual_payouts_status_idx on residual_payouts (status);

alter table residual_payouts enable row level security;

drop policy if exists "residual_payouts_select" on residual_payouts;
drop policy if exists "residual_payouts_write"  on residual_payouts;

create policy "residual_payouts_select" on residual_payouts
  for select to authenticated
  using (
    coalesce(current_app_has_perm('fullDashboard'), false)
    or partner_id = current_app_linked_partner_id()
  );

-- Internal only, and every branch coalesced: a null from the permission check
-- in a USING clause filters the row rather than granting it, but WITH CHECK
-- treats null as a failure too, and being explicit here means the next person
-- reading it does not have to remember which way each one falls.
create policy "residual_payouts_write" on residual_payouts
  for all to authenticated
  using (coalesce(current_app_has_perm('fullDashboard'), false))
  with check (coalesce(current_app_has_perm('fullDashboard'), false));


-- ---------------------------------------------------------------------------
-- Upsert by (partner, month).
--
-- A month gets restated — a chargeback lands late, a split was wrong. The
-- upload has to be safe to run twice, and re-running it must correct the
-- month rather than add a second one. Doing that in the browser would be
-- select-then-insert-or-update, which races two admins uploading at once and
-- trips the unique index; on conflict resolves it in one statement.
-- ---------------------------------------------------------------------------
create or replace function upsert_residual_payout(
  p_partner_id     uuid,
  p_period_month   date,
  p_merchant_count integer,
  p_gross          numeric,
  p_adjustments    numeric,
  p_net            numeric,
  p_status         text,
  p_paid_on        date,
  p_reference      text,
  p_notes          text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if not coalesce(current_app_has_perm('fullDashboard'), false) then
    raise exception 'Not authorised to record residual payouts';
  end if;

  if p_partner_id is null or p_period_month is null then
    raise exception 'A partner and a month are required';
  end if;
  if p_net is null then
    raise exception 'A net payout amount is required';
  end if;

  insert into residual_payouts (
    partner_id, period_month, merchant_count, gross_residual, adjustments,
    net_payout, status, paid_on, reference, notes, created_by
  ) values (
    p_partner_id,
    date_trunc('month', p_period_month)::date,
    p_merchant_count, p_gross, coalesce(p_adjustments, 0), p_net,
    coalesce(nullif(trim(coalesce(p_status, '')), ''), 'pending'),
    p_paid_on, nullif(trim(coalesce(p_reference, '')), ''),
    nullif(trim(coalesce(p_notes, '')), ''),
    current_app_user_id()
  )
  on conflict (partner_id, period_month) do update set
    merchant_count = excluded.merchant_count,
    gross_residual = excluded.gross_residual,
    adjustments    = excluded.adjustments,
    net_payout     = excluded.net_payout,
    status         = excluded.status,
    paid_on        = excluded.paid_on,
    reference      = excluded.reference,
    notes          = excluded.notes,
    updated_at     = now()
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function upsert_residual_payout(uuid, date, integer, numeric, numeric, numeric, text, date, text, text) from public, anon;
grant  execute on function upsert_residual_payout(uuid, date, integer, numeric, numeric, numeric, text, date, text, text) to authenticated;


-- =============================================================================
-- AFTER RUNNING THIS
--   Reports -> Residual Payouts. Log one, or paste a month's worth at once.
--
--   Then check the portal side properly — preview as an agent and confirm the
--   report shows only their own rows. The quickest real test is to give two
--   agents a payout for the same month and confirm neither can see the other:
--     select count(*) from residual_payouts;
--   run as an agent should equal their own row count, never the table's.
-- =============================================================================

-- =============================================================================
-- EPAY POS / Envision ATM Control Center — outbound email
-- ---------------------------------------------------------------------------
-- Run after 28_application_links.sql.
--
-- Two things:
--
-- 1. email_log — every send the send-email function attempts, successful or
--    not. "Did that actually go out?" should have an answer inside the CRM
--    rather than depending on Resend's dashboard, and a failure needs to be
--    visible rather than silent.
--
-- 2. Seeds the integrations row for outbound email. INTEGRATIONS currently
--    lives in localStorage — one browser, gone on a cache clear, invisible to
--    everyone else on the team. The table has existed since 01_schema.sql and
--    is already locked to manageSettings; this just gives it a row to hold.
--    The Resend API key does NOT go here: it is an environment variable on
--    the edge function, because anything in this table is readable by anyone
--    with manageSettings and the key should not be.
-- =============================================================================

create table if not exists email_log (
  id           uuid primary key default gen_random_uuid(),
  kind         text not null,
  to_email     text not null,
  subject      text not null,
  lead_id      uuid references leads(id) on delete set null,
  sent_by      uuid references users(id) on delete set null,
  provider_id  text,
  status       text not null default 'sent' check (status in ('sent','failed')),
  error        text,
  created_at   timestamptz not null default now()
);

create index if not exists email_log_lead_idx    on email_log (lead_id);
create index if not exists email_log_created_idx on email_log (created_at desc);
create index if not exists email_log_status_idx  on email_log (status);

alter table email_log enable row level security;

-- Internal staff read it; nobody writes from the browser. The edge function
-- inserts with the service role, which bypasses RLS, so there is deliberately
-- no insert policy here at all.
-- Dropped first so this file can be re-run. Postgres has no
-- "create policy if not exists", and a duplicate aborts the whole script —
-- which is how the integrations seed below got skipped the first time.
drop policy if exists "email_log_select" on email_log;

create policy "email_log_select" on email_log
  for select to authenticated
  using (current_app_has_perm('fullDashboard'));


-- ---------------------------------------------------------------------------
-- The integrations row. `connected` is flipped from Settings once the edge
-- function has its environment variables; `values` holds display-only config,
-- never the key.
-- ---------------------------------------------------------------------------
insert into integrations (key, connected, values)
values (
  'outbound_email',
  false,
  jsonb_build_object(
    'from_email', 'noreply@mail.epaypos.net',
    'from_name',  'EPAY POS',
    'reply_to',   ''
  )
)
on conflict (key) do nothing;


-- =============================================================================
-- AFTER RUNNING THIS
--   1. Deploy the function:  supabase functions deploy send-email
--   2. Set its environment variables — WITHOUT these it refuses to send and
--      says so rather than failing quietly:
--        RESEND_API_KEY   your Resend key (re_...)
--        EMAIL_FROM       EPAY POS <noreply@mail.epaypos.net>
--      The from-domain must be verified in Resend. mail.epaypos.net already
--      is; epaypos.net is not.
--   3. Send one from the CRM and confirm a row lands in email_log.
-- =============================================================================

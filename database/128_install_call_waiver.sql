-- =============================================================================
-- 128 - Converting without a scheduled install/training call.
--
-- The gate on install_training wants a calendar event linked to the lead
-- before the account can convert, and there was no way past it. But the
-- install and training call is often done on the phone the same day, or
-- booked in somebody's own calendar outside the CRM - and then the account
-- cannot convert at all, which is the pipeline refusing to record something
-- that has actually happened.
--
-- Same shape as 107, which did this for the application gate, deliberately:
-- not a quiet override. The waiver records who allowed it and when, the app
-- writes a note on the lead, the stage panel shows it, and it comes off again
-- from the same button. A converted account that skipped the step says so
-- instead of looking like one that never needed it.
--
-- Nothing else changes. The gate still applies to every lead that has not
-- been waived.
--
-- Safe to run twice.
-- =============================================================================

alter table leads add column if not exists install_call_waived_at timestamptz;
alter table leads add column if not exists install_call_waived_by uuid references users(id) on delete set null;

comment on column leads.install_call_waived_at is
  'Set when someone converted this account without a scheduled install/training '
  'call. Null means the gate applies. See database/128.';

select count(*) filter (where install_call_waived_at is not null) as waived_so_far,
       count(*)                                                   as leads_total
  from leads;

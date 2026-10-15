/* =========================================================================
   86_extra_subscriptions.sql — recurring charges that are not catalogue items

   Subscriptions have lived in two arrays on the lead: integrations_selected
   and epay_apps_selected, both picked from fixed catalogues inside the
   boarding stage panel. Two consequences:

     - the picker only exists at one stage, so an account created directly
       — a merchant boarded outside the CRM, or imported — had no way to
       carry a subscription at all;

     - anything not in a catalogue had nowhere to go. A gateway fee, a
       monthly service charge, a one-off arrangement for one merchant.

   This adds a third array for those, and the Subscriptions section that
   reads all three works at any stage and on any account however it was
   created. Same shape as its siblings — [{name, price, added_at}] plus a
   note — so the subscription report sums it with the others.
   ========================================================================= */

alter table leads
  add column if not exists extra_subscriptions jsonb not null default '[]'::jsonb;

comment on column leads.extra_subscriptions is
  'Recurring charges that are not catalogue integrations or EPAY apps: [{name, price, added_at, note}]. Editable at any stage, unlike integrations_selected and epay_apps_selected which are picked in the boarding panel (database/86_extra_subscriptions.sql).';

/* =========================================================================
   AFTER RUNNING THIS
     Open any account — including one added straight from the Accounts tab —
     and the Subscriptions section takes a name, a price and a start date.
     It shows up in Reports -> Subscriptions in the period it started.
   ========================================================================= */

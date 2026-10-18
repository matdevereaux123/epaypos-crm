-- =============================================================================
-- 108 - The terms a merchant actually saw, recorded so it can be shown again
--
-- 102 recorded which VERSION of the terms somebody accepted. That is most of
-- what is needed and not all of it: `pos_terms.body` can be edited, and if it
-- is, every agreement already made against that version now points at wording
-- nobody ever read. "They accepted v1" is only worth something while v1 still
-- says what it said.
--
-- So two things:
--
--   terms_hash  - a fingerprint of the exact text on the screen. If the body
--                 is edited afterwards the hashes stop matching and we can
--                 say so, rather than quietly showing the wrong wording.
--
--   shown_price - what the screen said, in words, as well as in cents. A
--                 dispute is argued about what somebody was shown, and
--                 "1500" is not what they were shown; "$15.00 a month, per
--                 location" is.
--
-- Versions become immutable once anything is accepted against them. A new
-- wording is a new version, which is what 102 said and what this enforces.
--
-- The v2 body here is a DRAFT. See docs/ADDON-TERMS-DRAFT.md in the POS repo.
-- It is inserted unpublished: nothing shows it to a merchant until somebody
-- sets published = true, and that should not happen before counsel has been
-- through it.
--
-- Safe to run twice.
-- =============================================================================

alter table pos_addon_agreements
  add column if not exists terms_hash text,
  add column if not exists shown_price text;

comment on column pos_addon_agreements.terms_hash is
  'Fingerprint of the exact terms text displayed at acceptance. Lets us show '
  'what they read rather than what the table says now.';
comment on column pos_addon_agreements.shown_price is
  'The price as the screen worded it. A dispute is about what somebody was '
  'shown, and "1500" is not what they were shown.';

-- ---------------------------------------------------------------------------
-- A version that has been accepted cannot be reworded.
--
-- Nothing stopped an edit to pos_terms.body before, and an edit silently
-- changes what every past agreement appears to say. Rewording is a new
-- version; this makes that the only way.
-- ---------------------------------------------------------------------------
create or replace function pos_terms_are_immutable()
returns trigger language plpgsql as $$
begin
  if new.body is distinct from old.body
     and exists (select 1 from pos_addon_agreements where terms_version = old.version) then
    raise exception
      'Terms % have been accepted by a merchant and cannot be reworded. Publish a new version instead.',
      old.version;
  end if;
  return new;
end $$;

drop trigger if exists pos_terms_no_rewrite on pos_terms;
create trigger pos_terms_no_rewrite
  before update on pos_terms
  for each row execute function pos_terms_are_immutable();

-- ---------------------------------------------------------------------------
-- v2, unpublished, awaiting counsel.
-- ---------------------------------------------------------------------------
insert into pos_terms (version, published, body) values ('v2', false,
'EPAY POS add-on subscription terms

1. What this covers. These terms apply when the business named on this
   account ("you") adds an optional feature ("Add-on") to its EPAY POS
   subscription. They add to, and do not replace, the agreement under which
   EPAY POS was supplied to you. Where the two conflict, that agreement
   governs.

2. What you are agreeing to. By accepting, you agree to add the Add-on shown
   on this screen to your subscription at the price shown, charged per month
   and per location.

3. The price. The price shown is the price you pay. It is charged monthly for
   each location the Add-on is enabled on, starting with your next invoice. It
   is not prorated for the month in which it is accepted, and it is exclusive
   of any tax that applies.

4. It renews each month. The Add-on continues from month to month until it is
   cancelled. There is no minimum term and no cancellation fee.

5. Cancelling. You can turn the Add-on off at any time from your back office,
   without contacting us. Billing stops at the end of the monthly period in
   which you cancel. Amounts already invoiced are not refunded, and the
   feature remains available until the end of that period.

6. If we change the price. We may change the list price of an Add-on at any
   time. A change does not affect you while you keep the Add-on continuously:
   you keep the price you accepted until you cancel it, change plan, or re-add
   it later. If you re-add an Add-on after cancelling, the price then current
   applies.

7. Card processing is separate. Nothing here changes your card processing
   rates, interchange, assessments, or anything else charged by your
   processor. These terms cover software only.

8. Who may accept. Only somebody authorised to commit the business may
   accept. By accepting you confirm that you are, and that the name you enter
   is your own.

9. Suspension. We may suspend an Add-on if an invoice for it is unpaid after
   we have told you and given you a reasonable chance to settle it. Suspension
   does not cancel it, and does not affect your ability to take payments.

10. Availability. We will make reasonable efforts to keep Add-ons available,
    and some depend on third parties. If a third party withdraws a service, we
    may withdraw the Add-on that depends on it, and will stop charging you for
    it from that point.

11. Your records. Data created through an Add-on belongs to you. If an Add-on
    is cancelled, we keep what it created and it remains available through
    your back office, except where we have told you otherwise.

12. These terms may change. We may update these terms for new acceptances. A
    change does not apply to an Add-on you have already accepted; your
    agreement stays on the version you accepted, which is recorded with it.

13. Electronic acceptance. You agree that ticking the box and entering your
    name is your electronic signature, and has the same effect as a
    handwritten one. We record what you were shown, the price, the version of
    these terms, the name you entered, and the date and time.

14. Governing law. These terms are governed by the laws of the State of
    Michigan, without regard to its conflict-of-law rules.')
on conflict (version) do nothing;

comment on table pos_terms is
  'The wording a merchant accepts. A version that has been accepted cannot be '
  'reworded - see the trigger above. v2 is unpublished until counsel has been '
  'through it; see docs/ADDON-TERMS-DRAFT.md.';

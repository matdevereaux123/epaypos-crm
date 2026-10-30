-- =============================================================================
-- 129 - A note you are still typing has to be allowed to change.
--
-- "Not saved - Cannot coerce the result to a single JSON object" when saving a
-- note on a lead. That message is PostgREST's PGRST116: the statement ran and
-- came back with no row, and .single() wants exactly one.
--
-- The cause is a missing policy. record_notes has select, insert and delete
-- and NO UPDATE, and the notes box does not insert once - the first pause in
-- typing inserts the note, and every pause after that updates that same row
-- so one thought stays one entry in the log instead of forty. The update was
-- being filtered to zero rows, so it looked like a failure.
--
-- It is worse than a bad message. The INSERT succeeded, so the opening
-- fragment of the note is in the log while the box says "Not saved" - the
-- half you typed first is kept and the rest is thrown away, which is the one
-- outcome nobody would choose.
--
-- partner_notes has had an update policy since 04_rls, which is why notes on
-- an agent have always saved and notes on a lead have not. This closes the
-- gap the same way, scoped tighter:
--
--   * your own note only (created_by_id, set by the stamp trigger on insert),
--   * and only for an hour after it was written.
--
-- The hour is what keeps the log a log. The autosave finishes its work in
-- seconds; the window is generous for a long note and still leaves yesterday's
-- entries immutable, which is the property 75 was protecting. Changing an old
-- note remains impossible for everyone, including an admin - delete it and
-- write another, which is already how this works.
--
-- entity_type is deliberately NOT updatable in practice: the policy's with
-- check requires the parent to still be visible, so a note cannot be moved to
-- a record you cannot see.
--
-- Safe to run twice.
-- =============================================================================

drop policy if exists "record_notes_update" on record_notes;
create policy "record_notes_update" on record_notes
  for update to authenticated
  using (
    created_by_id = current_app_user_id()
    and created_at > now() - interval '1 hour'
    and record_note_parent_visible(entity_type, entity_id)
  )
  with check (
    created_by_id = current_app_user_id()
    and record_note_parent_visible(entity_type, entity_id)
  );

comment on table record_notes is
  'Every dated, attributed note in the CRM. Append-only by design, with one '
  'exception: the author may change their own note for an hour after writing '
  'it, which is what lets the notes box save as you type rather than once per '
  'keystroke (database/129).';

select count(*)                                                        as notes_total,
       count(*) filter (where entity_type = 'lead')                    as on_leads,
       count(*) filter (where created_at > now() - interval '1 hour')   as still_editable
  from record_notes;

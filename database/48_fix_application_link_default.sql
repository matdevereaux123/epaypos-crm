-- =============================================================================
-- EPAY POS / Envision ATM Control Center — application links were defaulting
-- to a dead end
-- ---------------------------------------------------------------------------
-- emptyAccountFields() in app/index.html set every new lead's
-- application_link_choice to 'free_processing' — a link to the Wix
-- marketing site (epaypos.net/copy-of-free-processing), which has no
-- backend wired into this CRM at all (see the Wix integration card in
-- Settings). emailApplicationLink() only creates a real, tracked
-- /apply/<slug> link — the one that actually lands a submission in the
-- Applications tab — when application_link_choice is 'portal'. Since new
-- leads never got that value unless someone manually flipped the dropdown
-- first, every "Send an application link" click on an untouched lead sent
-- a link that could be filled out completely and still never show up here.
--
-- app/index.html's default is fixed alongside this migration (now 'portal').
-- This is the other half: correcting leads created before that fix, so
-- they start working immediately instead of needing every one hand-edited.
--
-- Deliberately scoped to exactly 'free_processing' — the one value the
-- broken default could produce on its own. A lead explicitly switched to
-- some other marketing link (e.g. 'sign_up') was a deliberate choice, not
-- this bug, and is left alone.
-- =============================================================================

update leads
   set application_link_choice = 'portal'
 where application_link_choice = 'free_processing';

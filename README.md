# EPAY POS / Envision ATM Control Center

Internal CRM covering both EPAY POS and Envision ATM — Leads, Accounts,
Cold Leads, a separate Lending pipeline, Referral Partners/Agents/EPAY
Resellers, a subscription add-on report, and a Newsletter tool.

## Current state — read this first

This whole app currently lives as **one self-contained HTML file**
(`app/index.html`), with all data in the browser's `localStorage`. That
was the right call for building it fast and iterating in a chat, but it
is not the production architecture. **The single highest-priority work
here is the Supabase migration** — see `database/` and `supabase/` below,
and the phased checklist in this file.

Nothing in `app/index.html` is connected to a real backend yet.
Third-party integrations shown in Settings (Instantly, Wix, Google
Calendar, Outbound Email, AI Lead Scraper) are all UI-only previews —
each one is marked in its own code comment with what it actually needs
to go live.

## Folder structure

```
app/
  index.html          The entire CRM — markup, styles, and logic in one file
database/
  01_schema.sql        Every table (leads, partners, users, roles, etc.)
  02_encryption.sql     Column-level encryption for SSN/DOB/DL/banking, run
                         right after 01, before any real data goes in
  03_auth_link.sql      Trigger linking Supabase Auth logins to the users table
  04_rls.sql             Row-Level Security policies for every table, matching
                          roles.perms dynamically — run after Auth is set up
supabase/
  functions/invite-user/  Edge Function that sends real portal invite emails
emails/
  portal_invite_email.html  Branded email template, ready to paste into
                             Supabase's Auth email templates
```

## Migration checklist

### Phase 1 — Foundation
1. Create the Supabase project
2. Run `database/01_schema.sql`
3. Run `database/02_encryption.sql` — before any real data, not after

### Phase 2 — Login
4. Set up Supabase Auth
5. Run `database/03_auth_link.sql`
6. Set up Resend, verify the domain
7. Plug Resend's SMTP credentials into Supabase's Auth SMTP settings
8. Deploy `supabase/functions/invite-user`
9. Paste `emails/portal_invite_email.html` into Auth → Email Templates → Invite user
10. Send a real test invite and confirm it arrives correctly

### Phase 3 — Lock it down
11. Confirm encryption is actually working (insert a test SSN, check it's unreadable in the table, check `reveal_lead_ssn()` respects permissions)
12. Write Row-Level Security policies for every table, matching `roles.perms` — since custom roles can be created from Settings, these need to check permissions dynamically rather than being hardcoded per role

### Phase 4 — Swap the data layer ✅ done
13. Go collection by collection, replacing `app/index.html`'s `loadX()`/`saveX()` functions with real Supabase calls. Test each collection before moving to the next.
14. Move document uploads to Supabase Storage

**Progress:** every collection is converted and tested — Auth, Users,
Partners, Leads, Applications, Cold Leads, Notes (partner/lead/call),
Lending Leads (+ its notes), Leads' document attachments, the public
referral landing page (`?ref=slug`), CSV bulk import, the AI Lead
Scraper's "push to partners/Cold Leads" flow, custom Roles management,
Newsletters/NL Templates, Connected Calendars/Calendar Events, and
Instantly Contacts. Only Integrations (Settings → Integrations connection
config — Wix, Instantly, AI Scraper, Google Calendar, Outbound Email) is
still localStorage-only, and that's expected to stay that way until each
integration actually goes live in Phase 6 — there's no real distinction
yet between "saved config" and "connected."

**New since the original build:** a **Team Structure** tab (under
Overview) for organizing Agents/EPAY Resellers by office — a freeform
drag-anywhere canvas with connector lines showing the recruiting hierarchy
(`partners.parent_partner_id`), a Board view for quick office assignment,
and residual %/equipment fields on each Agent/Reseller. Backed by new
`offices` table and `partners.canvas_x/canvas_y/residual_percentage/
free_equipment_placement/purchased_equipment` columns — see
`database/08_team_structure.sql` through `10_canvas_and_residuals.sql`.

Also new: a **Collections** toggle on the Account detail drawer ("In
collections — unit/system needs to be returned"), with an optional note,
and a **Collections report** under Reports — same period-navigation UI as
the Subscription report, but a genuine rolling 30-day window instead of a
fixed billing cycle. Available on both brands. Backed by
`leads.in_collections/collections_marked_at/collections_marked_by/
collections_note` — see `database/13_collections.sql`.

Also new: **Envision ISO Leads** — a standalone Kanban pipeline (Envision
ATM side only) for leads sourced through independent ISOs, structured like
Lending Leads (own stage set, own notes) but with each lead linking back
to the specific ISO who submitted it, since an ISO is a real portal login
(`roles.iso`) that should see its own submissions. Required adding `'iso'`
as a third `partners.type` value alongside `referral_partner`/`agent` — a
new "Add ISO" button lives on the Partners tab (Envision ATM brand only).
See `database/44_iso_leads.sql`.

Also new: a **Contacts** tab — a general business-contacts directory
(manufacturers, internal team, anyone else worth tracking), not a sales
pipeline. Simple filterable table like Loaders, filtered between
customer-facing and internal/manufacturer contacts. Both brands, internal
staff only. See `database/45_contacts.sql`.

Also new: **"Created by"** tracking on Leads, Cold Leads, ISO Leads, and
Lending Leads — every insert path across all four now stamps which
internal user created the row, shown in each detail drawer to staff with
`fullDashboard` only. The public referral landing page is the one path
with no logged-in user behind it (runs as anon); those leads show
"Public referral link (self-submitted)" instead of a blank. See
`database/46_lead_created_by.sql`.

Fixed: a partner added without an email never got a portal login created
for them, and the "Send invite" error's own suggested fix ("re-save the
partner with an email address") didn't actually do anything — that logic
only ever ran on brand-new partners. Extracted into a shared
`ensurePartnerPortalUser()` now called from both the Add Partner flow and
the Email field's inline edit on an existing partner. No SQL — app-code only.

Fixed: the Calendar tab was visible to every portal-scoped login (Agent,
EPAY Reseller, ISO, Referral Partner) — nav visibility only checked brand,
never role, even though Calendar's RLS has required `fullDashboard` since
`database/38_calendar_ownership.sql`. Narrowed further on request to
admin-only, nobody else — including other `fullDashboard` internal staff.
`'calendar'` now sits in the existing `ADMIN_ONLY_VIEWS` array (same
hard-gate + post-render bounce already used for AI Lead Scraper/Cold
Email), and `connected_calendars`/`calendar_events` RLS itself was
narrowed from `fullDashboard` to `manageUsers` so the database enforces
the same bar the UI does — see `database/47_calendar_admin_only.sql`.

Fixed: application links were silently going nowhere. Every new lead
defaulted `application_link_choice` to `'free_processing'` — a Wix
marketing page with no backend wired into this CRM at all — instead of
`'portal'`, the one choice that generates a real tracked `/apply/<slug>`
link and actually lands a submission in the Applications tab. A prospect
could fill the Wix form out completely and it would just vanish, since it
never reached Supabase in the first place. `emptyAccountFields()` now
defaults to `'portal'`, and `database/48_fix_application_link_default.sql`
corrects existing leads still sitting on the broken default. Also labeled
`source === 'link'` applications as "Portal application link" instead of
the generic "Manual" pill, so these are recognizable at a glance.

**Known gaps inside already-converted collections** (each flagged in code
where it applies):
- The "purge demo data" utility is deliberately NOT wired to real deletes —
  too destructive to enable without a separate explicit decision.

### Phase 5 — Go live
15. Deploy to real hosting
16. Stand up the real referral link routes (`epaypos.net/r/[slug]`, `envisionatm.com/r/[slug]`) — currently simulated via a `?ref=` query param on the same file

### Phase 6 — Wire up the rest
17. ~~Connect the same Resend account as the CRM's own Outbound Email integration~~ **Done** — `supabase/functions/send-email`, every send logged to `email_log`
18. ~~Google Calendar~~ **Done** — per-user OAuth, two-way sync, per-user event ownership (`database/35`–`38`)
19. Wix form capture
20. Instantly
21. AI Lead Scraper — needs a server-side Claude API key; never call it directly from `app/index.html`, since that would expose the key in the browser

### Phase 7 — Prove it before real data goes in
22. Multi-user test — two people logged in simultaneously, confirm data actually syncs
23. Re-confirm encryption one final time — use `database/tools/check_encryption.sql`, which is what caught the vault key never having been created
24. Real merchant/client data goes in
25. Launch

### Phase 8 — Training

Nobody has been taught this system yet, and it is now large enough that
handing someone a login is not the same as handing them a working tool.

- **Record training videos**, one per role rather than one long tour — an
  agent never sees Cold Leads or Applications, and a video that walks
  through them teaches an agent things that are not true of their account
- **A Training tab inside the CRM** so the videos live where the work does.
  A link in an email is found once and lost; a tab is there on the day
  someone actually needs it
- **Per-role tracks** — Admin, In-House Sales, Agent, EPAY Reseller, ISO,
  Referral Partner. Each sees only their own, driven by `portal_scope` and
  role perms the same way the nav already is
- **Decide where the video files live** before recording. They are the one
  asset here that does not belong in Supabase Storage on cost alone; an
  unlisted host with a plain embed is likely enough
- **Written quick-reference beside each video** — the answer to "how do I
  log a residual" should be findable without watching six minutes to reach
  it
- **Track completion per user**, so onboarding a new agent has a state
  rather than an assumption. Same shape as `partner_documents`: a row per
  user per module, stamped when finished
- **Decide whether any module gates access.** Signing the admit packet
  already gates an agent's portal; whether training should too is a
  business call, not a technical one — and worth making deliberately
  rather than discovering later that nobody watched anything
- **Cover the destructive paths explicitly** — deleting a lead cascades to
  its notes and documents, "send back to cold" does not, and the
  difference is not obvious from either button

### Operational, not yet scheduled

- **Move the repo off iCloud-synced storage.** It has corrupted the git
  repository twice — once truncating a file mid-commit, once clobbering
  `refs/heads/master` and leaving a single orphan commit where the history
  had been. Nothing was lost either time, but both were luck. Either turn
  off "Optimise Mac Storage" or move the working copy outside
  Desktop/Documents
- **Automatic Google Calendar sync.** Currently manual, on the Sync button.
  Automatic needs Google push notifications and a public webhook endpoint
- **New / Medium / Old filter chips on Cold Leads** — the ages are shown
  but cannot be filtered on
- **The "preview as" banner reads the viewer's own onboarding status**
  rather than the previewed user's. Cosmetic, but misleading in the one
  place built for checking what someone else sees
- **Two tabs both read "Sales Team"** in the sidebar — Partners / Sales
  Team and Sales Team & INT Agents. Deliberate or not, worth settling
- **Sensitive fields on an application are not yet inline-editable.** DOB,
  SSN, licence, tax ID and banking write through encrypting RPCs and have
  the pencil; the equivalent fields on a *lead* still go through the older
  form. Worth unifying so there is one way to edit a sensitive field

## Working in this codebase

- There are no automated tests yet. Verify changes by hand — open the
  file in a browser and exercise the flow you touched.
- The file is large and everything lives in one place. When making a
  change, search for the existing pattern first (e.g. every branded
  email reuses the same `.email-preview` CSS structure) rather than
  building something new from scratch.
- Sensitive fields (SSN, DOB, driver's license, bank routing/account
  numbers) are already gated by role permission and masked-by-default in
  the UI — see `canViewSensitive()`/`canEditSensitive()`/`sensitiveFieldHtml()`
  in `app/index.html`. Any new sensitive field should follow the same
  pattern, not a new one.

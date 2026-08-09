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

### Phase 4 — Swap the data layer
13. Go collection by collection, replacing `app/index.html`'s `loadX()`/`saveX()` functions with real Supabase calls. Test each collection before moving to the next.
14. Move document uploads to Supabase Storage

### Phase 5 — Go live
15. Deploy to real hosting
16. Stand up the real referral link routes (`epaypos.net/r/[slug]`, `envisionatm.com/r/[slug]`) — currently simulated via a `?ref=` query param on the same file

### Phase 6 — Wire up the rest
17. Connect the same Resend account as the CRM's own Outbound Email integration (separate from Auth's invite emails) — unlocks welcome emails, tracking emails, application emails, and the Newsletter tool
18. Google Calendar
19. Wix form capture
20. Instantly
21. AI Lead Scraper — needs a server-side Claude API key; never call it directly from `app/index.html`, since that would expose the key in the browser

### Phase 7 — Prove it before real data goes in
22. Multi-user test — two people logged in simultaneously, confirm data actually syncs
23. Re-confirm encryption one final time
24. Real merchant/client data goes in
25. Launch

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

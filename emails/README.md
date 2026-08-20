# System Email Templates — Reference for Claude Code

Every automated email in this app uses the same visual shell:
`emails/system_email_base_template.html`. Don't create a new template
per email type — fill in this same one with the values below, per
email. This keeps every email looking identical (logo, button style,
footer) even as new ones get added later.

## How the base template works

Six placeholders, always filled in the same way:

| Placeholder | What goes there |
|---|---|
| `{{EMAIL_SUBJECT}}` | The `<title>` and the actual email subject line |
| `{{PREHEADER_TEXT}}` | One sentence — the inbox preview text before opening |
| `{{LOGO_URL}}` | A real hosted image URL — see note below |
| `{{BRAND_NAME}}` | `EPAY POS` or `Envision ATM` depending which brand this is for |
| `{{BRAND_DOMAIN}}` | `epaypos.net` or `envisionatm.com` to match |
| `{{EMAIL_HEADING}}` | The `<h1>` inside the email |
| `{{EMAIL_BODY}}` | The main paragraph(s) |
| `{{BUTTON_TEXT}}` | Label on the CTA button — omit the whole button `<table>` block if an email doesn't need one |
| `{{BUTTON_URL}}` | **See the per-email table below — this is the part that actually matters** |
| `{{CLOSING_TEXT}}` | Short sign-off line before "— The [Brand] Team" |

### Logo hosting — do this first

The old version of this template had the logo embedded as a giant base64
string directly in the HTML. That's fine for a one-off preview, but bad
practice for a real transactional email — some email clients handle
embedded images poorly, and it makes every template file enormous.
**Upload the EPAY POS and Envision ATM logos as real hosted image files**
(e.g. `https://epaypos.net/assets/logo.png`) before wiring any of this
up. Every email below references that hosted URL instead.

## Every email type, and exactly what its button should link to

| Email | Sent from | `{{BUTTON_URL}}` — what it actually links to | Has a button? |
|---|---|---|---|
| **Portal invite** | Supabase Auth (not this template directly — see note below) | Supabase's own `{{ .ConfirmationURL }}` — auto-generated, not something you construct | Yes |
| **Application email** | CRM, Application stage | The specific application link the rep picked — either the Free Processing link (`https://www.epaypos.net/copy-of-free-processing`) or the Sign Up link (`https://www.epaypos.net/sign-up`), whichever was selected in the app for that lead | Yes |
| **Tracking email** | CRM, Equipment Shipment stage | The shipping carrier's tracking page, built from the tracking number on file — e.g. for UPS: `https://www.ups.com/track?tracknum=` + the tracking number | Yes |
| **Account welcome email** | CRM, on lead → account conversion | No button needed — this one's purely informational. Omit the button block entirely for this one. | No |
| **Newsletter** | CRM, Newsletter tab | Only if the newsletter is announcing something specific with its own page/offer — otherwise omit. When there is one, whoever's composing the newsletter should be the one supplying the URL, not something auto-generated. | Sometimes |
| **Shipment log entry email** | CRM, Shipments section on an Account | Same as Tracking email — carrier tracking URL built from that shipment's tracking number | Yes |

### Important — Supabase Auth emails are all special cases

Supabase Auth's own login system requires **its own separate copies**
of this template, using Supabase's own variable syntax instead of the
`{{PLACEHOLDER}}` style used everywhere else — mainly `{{ .ConfirmationURL }}`
for the button link and `{{ .Email }}` / `{{ .Data.first_name }}` for
personalization (the latter only populates if the inviting code passes
`first_name` in the `data` object — already wired up in
`supabase/functions/invite-user/index.ts` for invites specifically).

These five files are ready to paste directly into Supabase's dashboard
under **Authentication → Email Templates**, one per matching template
slot:

| File | Supabase template slot |
|---|---|
| `portal_invite_email.html` | Invite user |
| `account_activation_email.html` | Confirm signup |
| `password_reset_email.html` | Reset Password |
| `magic_link_email.html` | Magic Link |
| `change_email_email.html` | Change Email Address |

None of these five are ever sent through the CRM's own Outbound Email
integration the way the other five (below) are — Supabase Auth sends
them directly, on its own, the moment the matching event happens (a
password reset request, a new signup, etc.).

Worth knowing: this app's model is admin-initiated invites, not open
self-signup, so **Confirm signup and Magic Link may not be active flows
day one** — they're included so the full set is ready if that ever
changes (e.g. if agents/partners get self-signup later), not because
they're required for launch. Password Reset and Change Email Address
are the two that matter immediately, since anyone with a login will
eventually need one or both.

## What still needs to be built

None of the five CRM-sent emails (Application, Tracking, Welcome,
Newsletter, Shipment) actually deliver yet — they're fully built and
preview correctly inside the app, but nothing sends them until:

1. The Outbound Email integration is connected to a real provider
   (Resend, same account already set up for Supabase Auth — see the
   main README's Phase 6)
2. Each "send" action in `app/index.html` (search for
   `openApplicationEmailPreview`, `openTrackingEmailPreview`,
   `openAccountWelcomeEmailPreview`, the Newsletter's `nlPreviewBtn`
   handler, and `emailShipment`) gets a real API call added where it
   currently just marks a `_sent` flag as true

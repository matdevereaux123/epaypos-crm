# What a merchant receives — EPAY V2 auth emails

Supabase sends these itself, from the EPAY V2 project
(`vbdgaeyerqntipzcfqag`). They are not sent through `send-email`, so the
Control Center's templates never reach them: until these were installed,
every one was Supabase's unstyled default.

Paste each file's contents into **Authentication → Emails** in the V2
project, into the slot named below. Subject lines are in each file's
`<title>`.

| File | Supabase slot | Subject |
|---|---|---|
| `reset_password.html` | Reset Password | Reset your EPAY back office password |
| `invite_user.html` | Invite user | Your EPAY back office is ready |
| `confirm_signup.html` | Confirm signup | Confirm your email for EPAY POS |
| `magic_link.html` | Magic Link | Your sign-in link for EPAY POS |
| `change_email.html` | Change Email Address | Confirm your new email for EPAY POS |
| `reauthentication.html` | Reauthentication | Your EPAY confirmation code |

## Why these are separate from `../`

The templates in the parent folder say "Partner Portal" ten times over.
That is right for the Control Center project, where the recipient is a
partner or a member of staff. It is wrong here: a merchant resetting their
back office password has never heard of a Partner Portal, and an email that
names something they do not recognise is an email that reads as a phishing
attempt.

Same shell, same colours, same logo. Different reader.

## The variables

Supabase fills these in; leave them exactly as they are.

- `{{ .ConfirmationURL }}` — the one-time link. Every template has one
  except Reauthentication.
- `{{ .Token }}` — the six-digit code, Reauthentication only.

## Before these work properly

**Authentication → URL Configuration → Redirect URLs** must include
`https://epayportal.epaypos.net/**`. Without it Supabase ignores the
`redirect_to` the portal sends and falls back to the Site URL, so the link
lands somewhere that cannot catch it — which is what "the link does
nothing" looks like from the merchant's side.

The screen that catches it is `SetPasswordScreen` in the back-office app.

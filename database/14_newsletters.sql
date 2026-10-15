-- =============================================================================
-- EPAY POS / Envision ATM Control Center — Newsletter tool
-- ---------------------------------------------------------------------------
-- Backs the Newsletter tab: reusable templates (shared across both brands)
-- and the actual scheduled/sent newsletter log. Same access gate as the
-- client's own nav check — the Newsletter tab requires manageUsers
-- (ADMIN_ONLY_VIEWS in app/index.html), so RLS mirrors that exactly.
-- =============================================================================

create table nl_templates (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  subject     text not null,
  body        text not null,
  created_at  timestamptz not null default now()
);

alter table nl_templates enable row level security;

create policy "nl_templates_all" on nl_templates
  for all to authenticated
  using (current_app_has_perm('manageUsers'))
  with check (current_app_has_perm('manageUsers'));

-- Same three starter templates the app used to auto-seed into localStorage
-- on first load — genuinely useful starting content, not demo data, so
-- they carry over as real rows here.
insert into nl_templates (name, subject, body) values
  ('Monthly Update', 'What''s new this month', E'Hey there!\n\nWe wanted to share a quick update on what''s new with your account and what''s coming next.\n\n[Add your update here]\n\nAs always, reach out any time with questions.'),
  ('Feature Announcement', 'New feature now available', E'We''re excited to let you know about a new feature now available on your account.\n\n[Describe the feature and how it helps]\n\nGive it a try and let us know what you think.'),
  ('Seasonal Promotion', 'A limited-time offer for you', E'For a limited time, we''re offering something special for our current customers.\n\n[Describe the offer and how to claim it]\n\nDon''t wait — this offer won''t last long.');

create table newsletters (
  id               uuid primary key default gen_random_uuid(),
  subject          text not null,
  body             text,
  brand            text not null check (brand in ('epay', 'atm')),
  status           text not null check (status in ('scheduled', 'sent')),
  sent_at          date,
  scheduled_for    timestamptz,
  recipient_mode   text,
  recipient_ids    jsonb not null default '[]'::jsonb,
  recipient_count  integer not null default 0,
  created_at       timestamptz not null default now()
);
create index on newsletters (brand, status);

alter table newsletters enable row level security;

create policy "newsletters_all" on newsletters
  for all to authenticated
  using (current_app_has_perm('manageUsers'))
  with check (current_app_has_perm('manageUsers'));

-- =============================================================================
-- EPAY POS / Envision ATM Control Center — Booking Links (Calendly-style)
-- ---------------------------------------------------------------------------
-- Run after 52_calendar_per_user.sql.
--
-- Any logged-in user can create one or more personal booking links. A
-- stranger opens one with no login, sees real open slots pulled from that
-- user's calendar, picks one, and books directly onto that person's
-- calendar — never anyone else's. Same "own calendar only" boundary as
-- 52_calendar_per_user.sql, just reachable from outside a login this time.
-- =============================================================================

create table if not exists booking_links (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references users(id) on delete cascade,
  name              text not null,
  slug              text not null unique,
  meeting_type      text not null check (meeting_type in ('phone', 'email')),
  duration_minutes  integer not null default 30,
  description       text,
  brand             text not null default 'epay' check (brand in ('epay', 'atm')),
  active            boolean not null default true,
  created_at        timestamptz not null default now()
);
create index if not exists booking_links_user_idx on booking_links (user_id);

-- One shared weekly schedule per user, reused by every link they create —
-- not a separate schedule per link. weekday follows JS's Date.getDay()
-- (0 = Sunday .. 6 = Saturday) so the client can match rows directly with
-- no translation. Multiple rows per weekday are allowed (split shifts).
create table if not exists booking_availability (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references users(id) on delete cascade,
  weekday     smallint not null check (weekday between 0 and 6),
  start_time  time not null,
  end_time    time not null
);
create index if not exists booking_availability_user_idx on booking_availability (user_id);

-- Seed Mon-Fri 9-5 for every existing user so the feature isn't empty on day
-- one. Guarded per-user (not per-row), so re-running this file never touches
-- a user who has already set up their own hours, seeded or custom.
insert into booking_availability (user_id, weekday, start_time, end_time)
select u.id, wd.weekday, '09:00', '17:00'
from users u
cross join (values (1), (2), (3), (4), (5)) as wd(weekday)
where not exists (
  select 1 from booking_availability ba where ba.user_id = u.id
);

-- Marks a meeting as created through a public booking link (as opposed to
-- one entered by hand in the CRM). Used both to label it in the UI and as
-- the hard authorization boundary on the anon Google-push action below —
-- that action will only ever touch a row that has this set.
alter table calendar_events add column if not exists booking_link_id uuid references booking_links(id) on delete set null;

-- ---------------------------------------------------------------------------
-- RLS — identical shape to 52_calendar_per_user.sql. Owner manages their own
-- rows; Admin (manageUsers) can see/manage everyone's, for oversight.
-- ---------------------------------------------------------------------------
alter table booking_links enable row level security;
alter table booking_availability enable row level security;

drop policy if exists "booking_links_select" on booking_links;
drop policy if exists "booking_links_insert" on booking_links;
drop policy if exists "booking_links_update" on booking_links;
drop policy if exists "booking_links_delete" on booking_links;

create policy "booking_links_select" on booking_links
  for select to authenticated
  using (user_id = current_app_user_id() or coalesce(current_app_has_perm('manageUsers'), false));

create policy "booking_links_insert" on booking_links
  for insert to authenticated
  with check (user_id = current_app_user_id());

create policy "booking_links_update" on booking_links
  for update to authenticated
  using (user_id = current_app_user_id() or coalesce(current_app_has_perm('manageUsers'), false));

create policy "booking_links_delete" on booking_links
  for delete to authenticated
  using (user_id = current_app_user_id() or coalesce(current_app_has_perm('manageUsers'), false));

drop policy if exists "booking_availability_select" on booking_availability;
drop policy if exists "booking_availability_insert" on booking_availability;
drop policy if exists "booking_availability_update" on booking_availability;
drop policy if exists "booking_availability_delete" on booking_availability;

create policy "booking_availability_select" on booking_availability
  for select to authenticated
  using (user_id = current_app_user_id() or coalesce(current_app_has_perm('manageUsers'), false));

create policy "booking_availability_insert" on booking_availability
  for insert to authenticated
  with check (user_id = current_app_user_id());

create policy "booking_availability_update" on booking_availability
  for update to authenticated
  using (user_id = current_app_user_id() or coalesce(current_app_has_perm('manageUsers'), false));

create policy "booking_availability_delete" on booking_availability
  for delete to authenticated
  using (user_id = current_app_user_id() or coalesce(current_app_has_perm('manageUsers'), false));

-- ---------------------------------------------------------------------------
-- Public (anon) access — same reasoning as 12_public_referral.sql: rather
-- than write anon RLS policies on tables that hold other people's data,
-- everything a visitor with a link needs is wrapped in narrow SECURITY
-- DEFINER functions that expose exactly, and only, what the page needs.
-- ---------------------------------------------------------------------------

-- Enough to render the landing page. No owner id, email, or anything else
-- about the account leaks to an anonymous caller.
create or replace function public_lookup_booking_link(p_slug text)
returns table (
  name text,
  description text,
  duration_minutes integer,
  meeting_type text,
  brand text,
  owner_name text
)
language sql
security definer
set search_path = public
as $$
  select bl.name, bl.description, bl.duration_minutes, bl.meeting_type, bl.brand, u.name
  from booking_links bl
  join users u on u.id = bl.user_id
  where bl.slug = p_slug and bl.active = true;
$$;
grant execute on function public_lookup_booking_link(text) to anon;

-- The owner's weekly availability windows plus their busy calendar_events in
-- the requested date range. Free-slot computation happens client-side in
-- app/index.html, not here — simpler to write and debug than generating
-- candidate slots in SQL, and consistent with how the rest of this app keeps
-- logic in the client file over the database.
create or replace function public_get_booking_context(p_slug text, p_start_date date, p_end_date date)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_link booking_links%rowtype;
  v_availability json;
  v_busy json;
begin
  select * into v_link from booking_links where slug = p_slug and active = true;
  if not found then
    raise exception 'Unknown or inactive booking link';
  end if;

  select coalesce(json_agg(json_build_object('weekday', weekday, 'start_time', start_time, 'end_time', end_time)), '[]'::json)
    into v_availability
    from booking_availability
    where user_id = v_link.user_id;

  select coalesce(json_agg(json_build_object('date', date, 'time', time, 'duration', duration)), '[]'::json)
    into v_busy
    from calendar_events
    where owner_id = v_link.user_id
      and date between p_start_date and p_end_date;

  return json_build_object('availability', v_availability, 'busy', v_busy, 'duration_minutes', v_link.duration_minutes);
end;
$$;
grant execute on function public_get_booking_context(text, date, date) to anon;

-- Books the slot: re-validates it is still free (a second visitor loading
-- the same open slot a moment earlier is exactly the race this guards
-- against), creates a Cold Lead so the booking shows up in the owner's
-- pipeline, and inserts the calendar_event itself. Nothing about the
-- request is trusted beyond what this function explicitly writes — the
-- brand, owner, and meeting type all come from the booking_links row, never
-- from the caller.
create or replace function public_book_slot(
  p_slug text,
  p_date date,
  p_time text,
  p_name text,
  p_email text,
  p_phone text,
  p_business text,
  p_notes text
)
returns table (event_id uuid, owner_user_id uuid, google_connected boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_link booking_links%rowtype;
  v_cold_lead_id uuid;
  v_event_id uuid;
  v_conflict int;
begin
  select * into v_link from booking_links where slug = p_slug and active = true;
  if not found then
    raise exception 'Unknown or inactive booking link';
  end if;

  if p_name is null or trim(p_name) = '' or p_email is null or trim(p_email) = '' then
    raise exception 'Name and email are required';
  end if;

  select count(*) into v_conflict
    from calendar_events
    where owner_id = v_link.user_id and date = p_date and time = p_time;
  if v_conflict > 0 then
    raise exception 'That time was just booked by someone else — please pick another.';
  end if;

  insert into cold_leads (
    brand, business_name, contact_name, phone, email, source, temperature, notes, assigned_to
  ) values (
    v_link.brand,
    coalesce(nullif(trim(p_business), ''), trim(p_name)),
    trim(p_name),
    coalesce(nullif(trim(p_phone), ''), '—'),
    trim(p_email),
    'Booking link — ' || v_link.name,
    'warm',
    nullif(trim(p_notes), ''),
    v_link.user_id
  ) returning id into v_cold_lead_id;

  insert into calendar_events (
    title, date, time, duration, type, linked_cold_lead_id, notes, owner_id, booking_link_id
  ) values (
    trim(p_name) || ' — ' || v_link.name,
    p_date, p_time, v_link.duration_minutes::text, v_link.meeting_type,
    v_cold_lead_id,
    trim(coalesce(p_business, '')) || case when p_phone is not null and trim(p_phone) <> '' then E'\nPhone: ' || trim(p_phone) else '' end
      || case when p_notes is not null and trim(p_notes) <> '' then E'\n\n' || trim(p_notes) else '' end,
    v_link.user_id,
    v_link.id
  ) returning id into v_event_id;

  return query
    select v_event_id, v_link.user_id, exists(
      select 1 from connected_calendars where user_id = v_link.user_id and connected = true and google_email is not null
    );
end;
$$;
grant execute on function public_book_slot(text, date, text, text, text, text, text, text) to anon;

-- =============================================================================
-- AFTER RUNNING THIS
--   As a logged-in user: check booking_availability has Mon-Fri 9-5 seeded
--   for your own account. Create a booking_links row (from the CRM, once
--   the app-side UI ships) and confirm a logged-OUT browser hitting
--   /book/<slug> can look it up (public_lookup_booking_link) but cannot
--   read anything else about you or your calendar directly.
-- =============================================================================

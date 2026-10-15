-- =============================================================================
-- EPAY POS / Envision ATM Control Center — Notification bell
-- ---------------------------------------------------------------------------
-- Run after 54_booking_zoom_not_email.sql.
--
-- A general-purpose notifications table — not booking-specific, even though
-- a booked meeting is the first (and for now only) thing that writes to it.
-- `type`/`title`/`body`/`link_view`/`link_id` are generic on purpose so a
-- future notification (a lead assigned to you, a follow-up due) reuses this
-- table rather than needing its own.
-- =============================================================================

create table if not exists notifications (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references users(id) on delete cascade,
  type        text not null,
  title       text not null,
  body        text,
  link_view   text,
  link_id     uuid,
  read        boolean not null default false,
  created_at  timestamptz not null default now()
);
create index if not exists notifications_user_idx on notifications (user_id, read);

alter table notifications enable row level security;

drop policy if exists "notifications_select" on notifications;
drop policy if exists "notifications_update" on notifications;

-- Read your own, mark your own read. No insert policy for authenticated —
-- same reasoning as email_log having none — every row here comes from a
-- SECURITY DEFINER function (public_book_slot below), never a direct
-- client insert.
create policy "notifications_select" on notifications
  for select to authenticated
  using (user_id = current_app_user_id());

create policy "notifications_update" on notifications
  for update to authenticated
  using (user_id = current_app_user_id())
  with check (user_id = current_app_user_id());

-- Re-defines public_book_slot (53_booking_links.sql, last redefined in
-- 54_booking_zoom_not_email.sql) to also notify the link's owner. Everything
-- else about the function is unchanged.
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
    title, date, time, duration, type, linked_cold_lead_id, notes, owner_id, booking_link_id, zoom_link
  ) values (
    trim(p_name) || ' — ' || v_link.name,
    p_date, p_time, v_link.duration_minutes::text, v_link.meeting_type,
    v_cold_lead_id,
    trim(coalesce(p_business, '')) || case when p_phone is not null and trim(p_phone) <> '' then E'\nPhone: ' || trim(p_phone) else '' end
      || case when p_notes is not null and trim(p_notes) <> '' then E'\n\n' || trim(p_notes) else '' end,
    v_link.user_id,
    v_link.id,
    nullif(v_link.zoom_link, '')
  ) returning id into v_event_id;

  insert into notifications (user_id, type, title, body, link_view, link_id)
  values (
    v_link.user_id,
    'booking',
    trim(p_name) || ' booked ' || v_link.name,
    to_char(p_date, 'Mon DD') || ' at ' || p_time,
    'calendar',
    v_event_id
  );

  return query
    select v_event_id, v_link.user_id, exists(
      select 1 from connected_calendars where user_id = v_link.user_id and connected = true and google_email is not null
    );
end;
$$;

-- =============================================================================
-- AFTER RUNNING THIS
--   Book a test slot through any active booking link, then confirm a row
--   lands in notifications for that link's owner (select * from
--   notifications order by created_at desc limit 5).
-- =============================================================================

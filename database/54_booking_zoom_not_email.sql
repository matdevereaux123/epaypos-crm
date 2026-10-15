-- =============================================================================
-- EPAY POS / Envision ATM Control Center — Booking links: Zoom, not Email
-- ---------------------------------------------------------------------------
-- Run after 53_booking_links.sql.
--
-- Swaps Email out for Zoom as the second meeting type (Phone Call stays).
-- Zoom reuses the existing 'zoom_meeting' calendar_events.type value
-- (MEETING_TYPES in app/index.html) rather than inventing a separate one,
-- so a booked Zoom meeting renders identically to one entered by hand.
--
-- Also adds an optional Zoom link per booking link — a "Zoom meeting" type
-- with nowhere to actually meet is not much of one. Set once on the link,
-- stamped onto every calendar_events row it books, and included in the
-- visitor's confirmation email when present.
-- =============================================================================

alter table booking_links add column if not exists zoom_link text;

-- Any link or meeting created while Email was still an option becomes Zoom
-- instead, rather than being orphaned by the constraint below.
update booking_links set meeting_type = 'zoom_meeting' where meeting_type = 'email';
update calendar_events set type = 'zoom_meeting' where type = 'email' and booking_link_id is not null;

alter table booking_links drop constraint if exists booking_links_meeting_type_check;
alter table booking_links add constraint booking_links_meeting_type_check
  check (meeting_type in ('phone', 'zoom_meeting'));

-- Re-defines public_book_slot (originally in 53_booking_links.sql) to also
-- stamp the link's zoom_link onto the meeting it creates. Everything else
-- about the function is unchanged.
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

  return query
    select v_event_id, v_link.user_id, exists(
      select 1 from connected_calendars where user_id = v_link.user_id and connected = true and google_email is not null
    );
end;
$$;

-- =============================================================================
-- AFTER RUNNING THIS
--   Redeploy the google-calendar edge function is NOT needed for this file —
--   its TYPE_LABELS 'email' entry is just unused now, harmlessly, until the
--   next unrelated deploy tidies it up. Only the SQL here needs to run.
-- =============================================================================

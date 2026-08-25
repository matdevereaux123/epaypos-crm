// Supabase Edge Function: google-calendar
// ---------------------------------------------------------------------------
// Deploy with:  supabase functions deploy google-calendar
// (JWT verification ON — every action here is on behalf of a signed-in user.)
//
// Everything the browser is allowed to ask about a Google Calendar link.
// Actions: connect_url | status | disconnect | push_event | delete_event
//
// Why a function rather than calling Google from app/index.html: the exchange
// needs GOOGLE_CLIENT_SECRET, and the stored refresh token is a permanent key
// to somebody's calendar. app/index.html ships to every visitor. Neither one
// can be in it.
//
// Environment variables:
//   GOOGLE_CLIENT_ID
//   GOOGLE_CLIENT_SECRET
//   APP_URL             e.g. https://epaycrm.epaypos.net
//   CALENDAR_TIMEZONE   optional, defaults to America/Detroit
// ---------------------------------------------------------------------------

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

const SCOPES = [
  'https://www.googleapis.com/auth/calendar.events',
  'openid',
  'email',
].join(' ');

// ---------------------------------------------------------------------------
// Access tokens last about an hour; refresh tokens last until revoked. This
// spends the refresh token for a fresh access token when the stored one is
// within a minute of expiring, and writes the new one back so the next call
// does not have to.
// ---------------------------------------------------------------------------
async function accessTokenFor(
  admin: ReturnType<typeof createClient>,
  userId: string,
): Promise<{ token?: string; error?: string }> {
  const { data, error } = await admin.rpc('google_calendar_get_tokens', { p_user_id: userId });
  if (error) return { error: error.message };

  const row = Array.isArray(data) ? data[0] : data;
  if (!row?.refresh_token) return { error: 'This account has no Google Calendar connected.' };

  const expiresAt = row.access_expires_at ? new Date(row.access_expires_at).getTime() : 0;
  if (row.access_token && expiresAt > Date.now() + 60_000) {
    return { token: row.access_token as string };
  }

  const clientId = Deno.env.get('GOOGLE_CLIENT_ID');
  const clientSecret = Deno.env.get('GOOGLE_CLIENT_SECRET');
  if (!clientId || !clientSecret) return { error: 'Google Calendar is not configured on the server.' };

  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: clientId,
      client_secret: clientSecret,
      refresh_token: row.refresh_token as string,
      grant_type: 'refresh_token',
    }),
  });
  const out = await res.json().catch(() => ({}));

  if (!res.ok) {
    // invalid_grant means the user revoked us, changed their password, or the
    // token went unused for six months. It will never work again, so say so
    // plainly rather than letting them retry into the same wall.
    if (out?.error === 'invalid_grant') {
      return { error: 'Google has revoked this link. Disconnect and connect again.' };
    }
    return { error: out?.error_description || out?.error || `Google returned ${res.status}` };
  }

  // update_access_token, not store_tokens: a renewal carries no refresh token,
  // and store_tokens refuses a null one on purpose. See migration 35.
  await admin.rpc('google_calendar_update_access_token', {
    p_user_id:      userId,
    p_access_token: out.access_token,
    p_expires_at:   new Date(Date.now() + ((out.expires_in ?? 3600) * 1000)).toISOString(),
    p_scope:        out.scope ?? null,
  });

  return { token: out.access_token as string };
}

// calendar_events stores date as YYYY-MM-DD, time as HH:MM and duration as a
// plain number of minutes. Google wants RFC3339 plus a zone, and gets the
// zone by name so daylight saving is Google's problem rather than ours.
function toGoogleTimes(date: string, time: string, durationMinutes: number, tz: string) {
  const t = /^\d{2}:\d{2}$/.test(time || '') ? time : '09:00';
  const start = `${date}T${t}:00`;
  const [h, m] = t.split(':').map(Number);
  const end = new Date(Date.UTC(2000, 0, 1, h, m + (durationMinutes || 30)));
  const endTime = `${String(end.getUTCHours()).padStart(2, '0')}:${String(end.getUTCMinutes()).padStart(2, '0')}`;
  // A meeting running past midnight would need the next day's date; nothing
  // in MEETING_TYPES is longer than 90 minutes, so this only has to be right
  // for same-day events and says so rather than pretending otherwise.
  const endDate = (h * 60 + m + (durationMinutes || 30)) >= 1440 ? null : date;
  return endDate
    ? { start: { dateTime: start, timeZone: tz }, end: { dateTime: `${endDate}T${endTime}:00`, timeZone: tz } }
    : { start: { dateTime: start, timeZone: tz }, end: { dateTime: `${date}T23:59:00`, timeZone: tz } };
}

const TYPE_LABELS: Record<string, string> = {
  phone: 'Phone Call',
  zoom_meeting: 'Zoom Meeting',
  zoom_demo: 'Zoom Demo',
  in_person: 'In-Person Install/Training',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return json({ error: 'Expected a JSON body' }, 400);
  }
  const action = String(payload.action ?? '');

  // ---- who is asking -------------------------------------------------------
  const authHeader = req.headers.get('Authorization') ?? '';
  const caller = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: authHeader } } },
  );

  const { data: { user } } = await caller.auth.getUser();
  if (!user) return json({ error: 'Not authenticated' }, 401);

  // The calendar is internal-only, same as the tab it lives on. Checked here
  // rather than trusting the UI to have hidden it.
  const { data: callerRow } = await caller
    .from('users')
    .select('id, name, email, roles!inner(perms)')
    .eq('auth_id', user.id)
    .single();

  const perms = (callerRow as { roles?: { perms?: Record<string, unknown> } })?.roles?.perms ?? {};
  if (perms.fullDashboard !== true) return json({ error: 'Not authorized to use the calendar' }, 403);

  const userId = (callerRow as { id?: string })?.id;
  if (!userId) return json({ error: 'No CRM user record for this login' }, 403);

  const admin = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );
  const tz = Deno.env.get('CALENDAR_TIMEZONE') ?? 'America/Detroit';

  // -------------------------------------------------------------------------
  switch (action) {
    case 'connect_url': {
      const clientId = Deno.env.get('GOOGLE_CLIENT_ID');
      if (!clientId) {
        return json({ error: 'Google Calendar is not configured yet. Set GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET on this function.' }, 500);
      }

      const state = crypto.randomUUID() + '.' + crypto.randomUUID();
      const { error } = await admin.from('google_oauth_states').insert({ state, user_id: userId });
      if (error) return json({ error: error.message }, 500);

      const url = new URL('https://accounts.google.com/o/oauth2/v2/auth');
      url.searchParams.set('client_id', clientId);
      url.searchParams.set('redirect_uri', `${Deno.env.get('SUPABASE_URL')}/functions/v1/google-calendar-callback`);
      url.searchParams.set('response_type', 'code');
      url.searchParams.set('scope', SCOPES);
      // offline + consent together are what produce a refresh token. Without
      // access_type=offline there is none at all, and without prompt=consent
      // Google omits it for an account that has consented before — which is
      // every reconnect.
      url.searchParams.set('access_type', 'offline');
      url.searchParams.set('prompt', 'consent');
      url.searchParams.set('include_granted_scopes', 'true');
      url.searchParams.set('state', state);

      return json({ url: url.toString() }, 200);
    }

    case 'status': {
      const { data } = await admin
        .from('google_calendar_tokens')
        .select('google_email, updated_at, scope')
        .eq('user_id', userId)
        .maybeSingle();
      return json({ connected: !!data, email: data?.google_email ?? null, since: data?.updated_at ?? null }, 200);
    }

    case 'disconnect': {
      // Best effort: tell Google to drop the grant too, so it disappears from
      // the user's own account permissions rather than only from our table.
      const got = await accessTokenFor(admin, userId);
      if (got.token) {
        await fetch(`https://oauth2.googleapis.com/revoke?token=${encodeURIComponent(got.token)}`, {
          method: 'POST',
        }).catch(() => {});
      }
      const { error } = await admin.rpc('google_calendar_disconnect', { p_user_id: userId });
      if (error) return json({ error: error.message }, 500);
      return json({ success: true }, 200);
    }

    case 'push_event': {
      const eventId = String(payload.eventId ?? '');
      if (!eventId) return json({ error: 'eventId is required' }, 400);

      const { data: ev, error: evErr } = await admin
        .from('calendar_events')
        .select('*')
        .eq('id', eventId)
        .single();
      if (evErr || !ev) return json({ error: 'That meeting no longer exists' }, 404);

      const got = await accessTokenFor(admin, userId);
      if (got.error) {
        await admin.from('calendar_events')
          .update({ google_sync_error: got.error }).eq('id', eventId);
        return json({ error: got.error }, 400);
      }

      const times = toGoogleTimes(ev.date as string, ev.time as string, Number(ev.duration) || 30, tz);
      const descriptionParts = [
        TYPE_LABELS[ev.type as string] ? `Type: ${TYPE_LABELS[ev.type as string]}` : null,
        ev.notes ? String(ev.notes) : null,
        'Scheduled from the EPAY POS Control Center.',
      ].filter(Boolean);

      const body: Record<string, unknown> = {
        summary: ev.title,
        description: descriptionParts.join('\n\n'),
        ...times,
      };
      if (ev.zoom_link) body.location = ev.zoom_link;

      const existing = ev.google_event_id as string | null;
      const endpoint = existing
        ? `https://www.googleapis.com/calendar/v3/calendars/primary/events/${encodeURIComponent(existing)}`
        : 'https://www.googleapis.com/calendar/v3/calendars/primary/events';

      const res = await fetch(endpoint, {
        method: existing ? 'PATCH' : 'POST',
        headers: { Authorization: `Bearer ${got.token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      const out = await res.json().catch(() => ({}));

      if (!res.ok) {
        // A 404 on an event we thought we owned means it was deleted in
        // Google. Clearing the id lets the next push create a fresh one
        // instead of failing forever against a ghost.
        const msg = out?.error?.message || `Google returned ${res.status}`;
        await admin.from('calendar_events').update({
          google_sync_error: msg,
          ...(res.status === 404 && existing ? { google_event_id: null } : {}),
        }).eq('id', eventId);
        return json({ error: msg }, 502);
      }

      await admin.from('calendar_events').update({
        google_event_id: out.id,
        google_synced_at: new Date().toISOString(),
        google_sync_error: null,
      }).eq('id', eventId);

      return json({ success: true, googleEventId: out.id, htmlLink: out.htmlLink ?? null }, 200);
    }

    case 'delete_event': {
      const googleEventId = String(payload.googleEventId ?? '');
      if (!googleEventId) return json({ success: true, skipped: 'nothing on Google to remove' }, 200);

      const got = await accessTokenFor(admin, userId);
      if (got.error) return json({ error: got.error }, 400);

      const res = await fetch(
        `https://www.googleapis.com/calendar/v3/calendars/primary/events/${encodeURIComponent(googleEventId)}`,
        { method: 'DELETE', headers: { Authorization: `Bearer ${got.token}` } },
      );
      // 410 Gone / 404 mean it is already not there, which is the outcome we
      // wanted. Only a real failure is worth reporting.
      if (!res.ok && res.status !== 404 && res.status !== 410) {
        const out = await res.json().catch(() => ({}));
        return json({ error: out?.error?.message || `Google returned ${res.status}` }, 502);
      }
      return json({ success: true }, 200);
    }

    default:
      return json({ error: `Unknown action: ${action || '(none)'}` }, 400);
  }
});

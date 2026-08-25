// Supabase Edge Function: google-calendar
// ---------------------------------------------------------------------------
// Deploy with:  supabase functions deploy google-calendar
// (JWT verification ON — every action here is on behalf of a signed-in user.)
//
// Everything the browser is allowed to ask about a Google Calendar link.
// Actions: connect_url | complete_oauth | status | disconnect | push_event |
//          delete_event | import_events
//
// Google redirects to a small page on the CRM's own domain (/oauth/google),
// which hands the code back to the already-signed-in CRM window; that window
// then calls complete_oauth here. There is deliberately NO public callback
// endpoint on this project:
//
//   * Supabase's gateway rejects any function request without a JWT before
//     the function runs, so a public callback needs "Verify JWT" turned off —
//     and that toggle silently turns itself back on every time the function
//     is updated (supabase/supabase#43608). Sign-in would break on some
//     future unrelated edit, with nothing in the logs, because the gateway
//     rejects the call before there is anything to log.
//   * Doing the exchange from an authenticated call is also strictly safer:
//     the OAuth state can be checked against the user actually making the
//     request, which a public callback cannot do.
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

// Must be byte-identical in the consent request and the token exchange, or
// Google rejects the exchange with redirect_uri_mismatch. One function so the
// two cannot drift.
function redirectUri(): string {
  return `${(Deno.env.get('APP_URL') ?? 'https://epaycrm.epaypos.net').replace(/\/+$/, '')}/oauth/google`;
}

// The id_token comes straight back from Google's token endpoint over TLS, in
// response to a request carrying our client secret. That is Google's own
// stated condition for skipping signature verification — this only reads the
// payload, it is not accepting a token from a caller.
function emailFromIdToken(idToken?: string): string | null {
  if (!idToken) return null;
  try {
    const part = idToken.split('.')[1];
    if (!part) return null;
    return (JSON.parse(atob(part.replace(/-/g, '+').replace(/_/g, '/'))) as { email?: string }).email ?? null;
  } catch {
    return null;
  }
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

// Google gives either dateTime (timed) or date (all-day). Everything here
// stays in the calendar's local wall-clock terms, matching how the CRM stores
// dates — a date string and an HH:MM string, no zone.
function fromGoogleEvent(ev: Record<string, any>, calendarId: string, ownerId: string) {
  const s = ev.start ?? {};
  const e = ev.end ?? {};
  const allDay = !!s.date && !s.dateTime;

  const date = allDay ? String(s.date) : String(s.dateTime ?? '').slice(0, 10);
  const time = allDay ? '' : String(s.dateTime ?? '').slice(11, 16);

  let duration = 30;
  if (!allDay && s.dateTime && e.dateTime) {
    const mins = Math.round((new Date(e.dateTime).getTime() - new Date(s.dateTime).getTime()) / 60000);
    // Clamp rather than trust: a malformed pair should not write a negative
    // duration that the UI then tries to render.
    if (Number.isFinite(mins) && mins > 0 && mins <= 60 * 24) duration = mins;
  }

  return {
    title: String(ev.summary ?? '(no title)').slice(0, 300),
    date,
    time,
    duration: String(duration),
    all_day: allDay,
    type: 'external',
    calendar_id: calendarId,
    // Stamped here rather than left to the trigger. These rows are written
    // with the service role, so current_app_user_id() is null at that point —
    // an unowned personal event would be visible to the whole team.
    owner_id: ownerId,
    zoom_link: ev.hangoutLink ?? ev.location ?? null,
    notes: ev.description ? String(ev.description).slice(0, 4000) : null,
    google_event_id: ev.id,
    google_origin: true,
    google_updated_at: ev.updated ?? null,
    google_synced_at: new Date().toISOString(),
    google_sync_error: null,
  };
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
      url.searchParams.set('redirect_uri', redirectUri());
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

    case 'complete_oauth': {
      const code = String(payload.code ?? '');
      const state = String(payload.state ?? '');
      if (!code || !state) return json({ error: 'Google did not return a code' }, 400);

      const clientId = Deno.env.get('GOOGLE_CLIENT_ID');
      const clientSecret = Deno.env.get('GOOGLE_CLIENT_SECRET');
      if (!clientId || !clientSecret) {
        return json({ error: 'Google Calendar is not configured. Set GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET on this function.' }, 500);
      }

      // The state must exist AND belong to the user making this call. Both
      // halves matter: existence stops a forged callback, and the ownership
      // check stops one user completing a flow that another user started.
      const { data: stateRow } = await admin
        .from('google_oauth_states')
        .select('state, user_id, expires_at')
        .eq('state', state)
        .maybeSingle();

      if (!stateRow || stateRow.user_id !== userId) {
        return json({ error: 'This connection request was not recognised. Start again from Settings.' }, 400);
      }
      // Single use — deleted before the exchange so a replay cannot bind twice.
      await admin.from('google_oauth_states').delete().eq('state', state);
      await admin.from('google_oauth_states').delete().lt('expires_at', new Date().toISOString());

      if (new Date(stateRow.expires_at as string).getTime() < Date.now()) {
        return json({ error: 'This connection request expired. Start again from Settings.' }, 400);
      }

      let tok: {
        access_token?: string; refresh_token?: string; expires_in?: number;
        scope?: string; id_token?: string; error?: string; error_description?: string;
      };
      try {
        const res = await fetch('https://oauth2.googleapis.com/token', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({
            code,
            client_id: clientId,
            client_secret: clientSecret,
            redirect_uri: redirectUri(),
            grant_type: 'authorization_code',
          }),
        });
        tok = await res.json();
        if (!res.ok) {
          return json({ error: `Google refused the exchange: ${tok.error_description || tok.error || res.status}` }, 502);
        }
      } catch (e) {
        return json({ error: `Could not reach Google: ${e instanceof Error ? e.message : 'unknown error'}` }, 502);
      }

      // Without a refresh token the link dies within the hour and cannot renew
      // itself. connect_url always forces the consent screen, so reaching here
      // means something is genuinely wrong rather than a routine reconnect.
      if (!tok.refresh_token) {
        return json({ error: 'Google did not return a refresh token, so the link would stop working within the hour. Remove EPAY POS at myaccount.google.com/permissions, then connect again.' }, 400);
      }

      const { error: storeErr } = await admin.rpc('google_calendar_store_tokens', {
        p_user_id:       userId,
        p_refresh_token: tok.refresh_token,
        p_access_token:  tok.access_token ?? null,
        p_expires_at:    new Date(Date.now() + ((tok.expires_in ?? 3600) * 1000)).toISOString(),
        p_scope:         tok.scope ?? null,
        p_google_email:  emailFromIdToken(tok.id_token),
      });
      if (storeErr) return json({ error: `Connected to Google, but saving it here failed: ${storeErr.message}` }, 500);

      return json({ success: true, email: emailFromIdToken(tok.id_token) }, 200);
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
        // Backfills anything created before ownership existed, so a meeting
        // stops being editable by the whole team the first time it syncs.
        owner_id: (ev.owner_id as string | null) ?? userId,
      }).eq('id', eventId);

      return json({ success: true, googleEventId: out.id, htmlLink: out.htmlLink ?? null }, 200);
    }

    case 'import_events': {
      const got = await accessTokenFor(admin, userId);
      if (got.error) return json({ error: got.error }, 400);

      const { data: cal } = await admin
        .from('connected_calendars')
        .select('id, google_sync_token')
        .eq('user_id', userId)
        .maybeSingle();
      if (!cal) return json({ error: 'No Google Calendar is linked to this account.' }, 400);

      const force = payload.full === true;
      let syncToken: string | null = force ? null : (cal.google_sync_token as string | null);
      let pageToken: string | null = null;
      let nextSyncToken: string | null = null;
      const items: Record<string, any>[] = [];

      // Page until Google stops offering a nextPageToken. Capped so a calendar
      // with years of history cannot spin here forever on a first import; the
      // remainder arrives on the next sync.
      for (let page = 0; page < 20; page++) {
        const u = new URL('https://www.googleapis.com/calendar/v3/calendars/primary/events');
        u.searchParams.set('maxResults', '250');
        u.searchParams.set('singleEvents', 'true');       // expand recurrences
        u.searchParams.set('showDeleted', 'true');        // needed to learn about deletions
        if (syncToken) {
          u.searchParams.set('syncToken', syncToken);
        } else {
          // First run, or after an expired token: a bounded window rather than
          // the whole history.
          const from = new Date(); from.setDate(from.getDate() - 30);
          const to = new Date();   to.setDate(to.getDate() + 180);
          u.searchParams.set('timeMin', from.toISOString());
          u.searchParams.set('timeMax', to.toISOString());
          u.searchParams.set('orderBy', 'startTime');
        }
        if (pageToken) u.searchParams.set('pageToken', pageToken);

        const res = await fetch(u.toString(), { headers: { Authorization: `Bearer ${got.token}` } });

        // 410 GONE means the sync token is too old to be useful. Google's
        // documented recovery is to throw it away and do a full sync, which is
        // exactly what clearing it and restarting the loop does.
        if (res.status === 410 && syncToken) {
          syncToken = null; pageToken = null; items.length = 0;
          await admin.from('connected_calendars').update({ google_sync_token: null }).eq('id', cal.id);
          continue;
        }
        if (!res.ok) {
          const out = await res.json().catch(() => ({}));
          return json({ error: out?.error?.message || `Google returned ${res.status}` }, 502);
        }

        const body = await res.json();
        items.push(...(body.items ?? []));
        nextSyncToken = body.nextSyncToken ?? nextSyncToken;
        pageToken = body.nextPageToken ?? null;
        if (!pageToken) break;
      }

      let imported = 0, updated = 0, removed = 0;

      for (const ev of items) {
        if (!ev.id) continue;

        if (ev.status === 'cancelled') {
          // Deleted in Google. Only rows that came FROM Google are removed —
          // a CRM meeting whose Google copy was deleted keeps its own record
          // here, because this system is the source of truth for its own work.
          const { data: gone } = await admin.from('calendar_events')
            .delete()
            .eq('calendar_id', cal.id).eq('google_event_id', ev.id)
            .eq('google_origin', true).eq('owner_id', userId)
            .select('id');
          removed += (gone?.length ?? 0);
          continue;
        }

        const row = fromGoogleEvent(ev, cal.id as string, userId);
        if (!row.date) continue;   // nothing usable to place it on

        const { data: existing } = await admin.from('calendar_events')
          .select('id, google_origin, google_updated_at')
          .eq('calendar_id', cal.id).eq('google_event_id', ev.id)
          .maybeSingle();

        if (!existing) {
          const { error } = await admin.from('calendar_events').insert(row);
          if (!error) imported++;
          continue;
        }

        // A meeting the CRM created and pushed. Google is the mirror, not the
        // master, so its copy does not overwrite the CRM's own fields — only
        // the sync bookkeeping is refreshed.
        if (existing.google_origin !== true) {
          await admin.from('calendar_events')
            .update({ google_synced_at: new Date().toISOString(), google_updated_at: row.google_updated_at })
            .eq('id', existing.id);
          continue;
        }

        // Unchanged since we last saw it — skip the write entirely.
        if (existing.google_updated_at && row.google_updated_at
            && new Date(existing.google_updated_at as string).getTime()
               >= new Date(row.google_updated_at as string).getTime()) {
          continue;
        }

        const { error } = await admin.from('calendar_events').update(row).eq('id', existing.id);
        if (!error) updated++;
      }

      await admin.from('connected_calendars').update({
        google_sync_token: nextSyncToken,
        last_synced_at: new Date().toISOString(),
      }).eq('id', cal.id);

      return json({ success: true, imported, updated, removed, seen: items.length }, 200);
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

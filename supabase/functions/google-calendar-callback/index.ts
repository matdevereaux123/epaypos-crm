// Supabase Edge Function: google-calendar-callback
// ---------------------------------------------------------------------------
// Deploy with:  supabase functions deploy google-calendar-callback --no-verify-jwt
//
// THE --no-verify-jwt MATTERS. Google's browser redirect lands here, and
// Google has no Supabase token to send. With JWT verification left on, every
// connection attempt dies at the door with a 401 and the popup shows nothing
// useful.
//
// That makes this endpoint publicly reachable, so it trusts nothing in the
// URL except a `state` it can find in google_oauth_states — a row this system
// wrote, for a known user, in the last ten minutes, and deletes on use. The
// user id comes from that row and never from the request.
//
// Environment variables (same three as google-calendar):
//   GOOGLE_CLIENT_ID
//   GOOGLE_CLIENT_SECRET
//   APP_URL            e.g. https://epaycrm.epaypos.net
// ---------------------------------------------------------------------------

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// Shown in the popup. It talks to the window that opened it and then closes;
// if it was not opened as a popup, the link is the way back.
function page(ok: boolean, message: string, appUrl: string) {
  const colour = ok ? '#0F9D58' : '#D93025';
  const title = ok ? 'Calendar connected' : 'Could not connect';
  return new Response(
    `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title}</title></head>
<body style="margin:0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;background:#F4F7FB;display:flex;align-items:center;justify-content:center;height:100vh;">
  <div style="background:#fff;border:1px solid #E4E9F2;border-radius:12px;padding:34px 30px;max-width:380px;text-align:center;">
    <div style="font-size:34px;line-height:1;color:${colour};margin-bottom:12px;">${ok ? '&#10003;' : '&#33;'}</div>
    <h1 style="margin:0 0 8px;font-size:18px;color:#142850;">${title}</h1>
    <p style="margin:0 0 18px;font-size:13.5px;line-height:1.55;color:#22406F;">${message}</p>
    <a href="${appUrl}" style="display:inline-block;padding:10px 22px;border-radius:8px;background:#0558D6;color:#fff;text-decoration:none;font-size:13px;font-weight:600;">Back to the CRM</a>
  </div>
  <script>
    try { window.opener && window.opener.postMessage(
      { source:'epay-google-calendar', ok:${ok ? 'true' : 'false'} }, '*'); } catch (e) {}
    ${ok ? 'setTimeout(function(){ try { window.close(); } catch (e) {} }, 1200);' : ''}
  </script>
</body></html>`,
    { status: 200, headers: { 'Content-Type': 'text/html; charset=utf-8' } },
  );
}

// The id_token came straight back from Google's token endpoint over TLS, in
// response to a request carrying our client secret. That is Google's own
// stated condition for skipping signature verification, so this only needs
// to read the payload — it is not accepting a token from a caller.
function emailFromIdToken(idToken?: string): string | null {
  if (!idToken) return null;
  try {
    const part = idToken.split('.')[1];
    if (!part) return null;
    const json = atob(part.replace(/-/g, '+').replace(/_/g, '/'));
    const payload = JSON.parse(json) as { email?: string };
    return payload.email ?? null;
  } catch {
    return null;
  }
}

Deno.serve(async (req) => {
  const appUrl = Deno.env.get('APP_URL') ?? 'https://epaycrm.epaypos.net';
  const url = new URL(req.url);

  const denied = url.searchParams.get('error');
  if (denied) {
    return page(false, denied === 'access_denied'
      ? 'You declined the permission request, so nothing was linked.'
      : `Google returned: ${denied}`, appUrl);
  }

  const code = url.searchParams.get('code');
  const state = url.searchParams.get('state');
  if (!code || !state) {
    return page(false, 'That link is missing part of its response from Google. Start the connection again from Settings.', appUrl);
  }

  const clientId = Deno.env.get('GOOGLE_CLIENT_ID');
  const clientSecret = Deno.env.get('GOOGLE_CLIENT_SECRET');
  if (!clientId || !clientSecret) {
    return page(false, 'Google Calendar is not configured on the server yet. Set GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET on this function.', appUrl);
  }

  const admin = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  // ---- who started this ----------------------------------------------------
  // Single-use: the row is deleted before the token exchange, so replaying a
  // callback URL cannot bind a second account.
  const { data: stateRow } = await admin
    .from('google_oauth_states')
    .select('state, user_id, expires_at')
    .eq('state', state)
    .maybeSingle();

  if (!stateRow) {
    return page(false, 'This connection request was not recognised. It may already have been used. Start again from Settings.', appUrl);
  }
  await admin.from('google_oauth_states').delete().eq('state', state);

  if (new Date(stateRow.expires_at as string).getTime() < Date.now()) {
    return page(false, 'This connection request expired. Start again from Settings.', appUrl);
  }

  // Housekeeping — these rows are worthless once stale.
  await admin.from('google_oauth_states').delete().lt('expires_at', new Date().toISOString());

  // ---- exchange the code ---------------------------------------------------
  const redirectUri = `${Deno.env.get('SUPABASE_URL')}/functions/v1/google-calendar-callback`;

  let tokens: {
    access_token?: string; refresh_token?: string; expires_in?: number;
    scope?: string; id_token?: string; error_description?: string; error?: string;
  };
  try {
    const res = await fetch('https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        code,
        client_id: clientId,
        client_secret: clientSecret,
        redirect_uri: redirectUri,
        grant_type: 'authorization_code',
      }),
    });
    tokens = await res.json();
    if (!res.ok) {
      return page(false, `Google refused the exchange: ${tokens.error_description || tokens.error || res.status}`, appUrl);
    }
  } catch (e) {
    return page(false, `Could not reach Google: ${e instanceof Error ? e.message : 'unknown error'}`, appUrl);
  }

  // Without a refresh token the link dies in an hour and cannot be renewed.
  // That happens when the account has consented before and the consent screen
  // was not forced — which google-calendar's connect_url always does, so
  // reaching here means something is genuinely wrong.
  if (!tokens.refresh_token) {
    return page(false,
      'Google did not return a refresh token, so the link would stop working within the hour. Remove EPAY POS at myaccount.google.com/permissions, then connect again.',
      appUrl);
  }

  const expiresAt = new Date(Date.now() + ((tokens.expires_in ?? 3600) * 1000)).toISOString();

  const { error: storeErr } = await admin.rpc('google_calendar_store_tokens', {
    p_user_id:       stateRow.user_id,
    p_refresh_token: tokens.refresh_token,
    p_access_token:  tokens.access_token ?? null,
    p_expires_at:    expiresAt,
    p_scope:         tokens.scope ?? null,
    p_google_email:  emailFromIdToken(tokens.id_token),
  });

  if (storeErr) {
    return page(false, `Connected to Google, but saving it here failed: ${storeErr.message}`, appUrl);
  }

  return page(true, 'Your Google Calendar is linked. Meetings you schedule in the CRM will appear on it.', appUrl);
});

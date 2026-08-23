// Supabase Edge Function: send-email
// ---------------------------------------------------------------------------
// Deploy with: supabase functions deploy send-email
//
// The CRM's own outbound email — application links, welcome notes, tracking
// updates, newsletters. NOT the auth emails: invites, password resets and
// magic links go through Supabase Auth's own SMTP and its templates, and are
// none of this function's business.
//
// Why a function at all: sending through Resend needs the Resend API key, and
// anything the browser can read is public. app/index.html ships to every
// visitor, so the key lives here as an environment variable and never leaves
// the server.
//
// Set these on the function before deploying:
//   RESEND_API_KEY   your Resend key (starts re_)
//   EMAIL_FROM       e.g. EPAY POS <noreply@mail.epaypos.net>
//                    the domain must be verified in Resend or it will refuse
//
// Every send is recorded in email_log — see database/29_outbound_email.sql —
// so "did that go out?" has an answer that does not depend on Resend's UI.
// ---------------------------------------------------------------------------

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function jsonResponse(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

// A very small allow-list. Sending arbitrary HTML supplied by the browser
// would turn this into an open relay for anyone who can log in — the caller
// picks a kind and supplies values, and the markup is built here.
const ALLOWED_KINDS = [
  'application_link',
  'welcome',
  'tracking',
  'general',
] as const;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return jsonResponse({ error: 'Expected a JSON body' }, 400);
  }

  const { kind, to, subject, heading, body, buttonLabel, buttonUrl, leadId } = payload as {
    kind?: string; to?: string; subject?: string; heading?: string;
    body?: string; buttonLabel?: string; buttonUrl?: string; leadId?: string;
  };

  if (!kind || !ALLOWED_KINDS.includes(kind as typeof ALLOWED_KINDS[number])) {
    return jsonResponse({ error: 'Unknown email kind' }, 400);
  }
  if (!to || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(to)) {
    return jsonResponse({ error: 'A valid recipient is required' }, 400);
  }
  if (!subject || !heading || !body) {
    return jsonResponse({ error: 'subject, heading and body are required' }, 400);
  }

  // ---- who is asking -------------------------------------------------------
  const authHeader = req.headers.get('Authorization') ?? '';
  const callerClient = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: authHeader } } },
  );

  const { data: { user: caller } } = await callerClient.auth.getUser();
  if (!caller) {
    return jsonResponse({ error: 'Not authenticated' }, 401);
  }

  // Anyone who can work leads may send; portal logins may not. Checked here
  // rather than trusting the UI to have hidden the button.
  const { data: callerRow } = await callerClient
    .from('users')
    .select('id, email, name, role, roles!inner(perms)')
    .eq('auth_id', caller.id)
    .single();

  const perms = (callerRow as { roles?: { perms?: Record<string, unknown> } })?.roles?.perms ?? {};
  if (perms.fullDashboard !== true) {
    return jsonResponse({ error: 'Not authorized to send email' }, 403);
  }

  // ---- config --------------------------------------------------------------
  const apiKey = Deno.env.get('RESEND_API_KEY');
  const from = Deno.env.get('EMAIL_FROM');
  if (!apiKey || !from) {
    return jsonResponse({
      error: 'Outbound email is not configured. Set RESEND_API_KEY and EMAIL_FROM on this function.',
    }, 500);
  }

  // ---- markup --------------------------------------------------------------
  // Deliberately the same shape as the auth templates in emails/, so the two
  // families of mail look like they come from one company. Values are escaped;
  // the caller supplies text, never HTML.
  const esc = (v: string) =>
    v.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

  const button = buttonUrl && buttonLabel
    ? `<table role="presentation" cellpadding="0" cellspacing="0" style="margin:8px 0 22px;">
         <tr><td align="center" style="border-radius:8px; background-color:#0558D6;">
           <a href="${esc(buttonUrl)}" target="_blank" style="display:inline-block; padding:13px 30px; font-size:14px; font-weight:bold; color:#ffffff; text-decoration:none; font-family:Arial, Helvetica, sans-serif;">
             ${esc(buttonLabel)} &rarr;
           </a>
         </td></tr>
       </table>`
    : '';

  const html = `<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>${esc(subject)}</title></head>
<body style="margin:0; padding:0; background-color:#F4F7FB; font-family:Arial, Helvetica, sans-serif;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color:#F4F7FB; padding:32px 16px;">
    <tr><td align="center">
      <table role="presentation" width="480" cellpadding="0" cellspacing="0" style="width:480px; max-width:100%; background-color:#ffffff; border-radius:10px; overflow:hidden; border:1px solid #E4E9F2;">
        <tr><td align="center" style="background-color:#ffffff; padding:24px; border-bottom:1px solid #E4E9F2;">
          <img src="https://epaycrm.epaypos.net/email-logo.png" alt="EPAY POS" width="90" style="display:block;">
        </td></tr>
        <tr><td style="padding:30px 26px;">
          <h1 style="margin:0 0 14px; font-size:19px; color:#142850;">${esc(heading)}</h1>
          <p style="margin:0 0 16px; font-size:14px; line-height:1.6; color:#22406F;">${esc(body).replace(/\n/g, '<br>')}</p>
          ${button}
          <p style="margin:0; font-size:14px; line-height:1.6; color:#22406F;">&mdash; The EPAY POS Team</p>
        </td></tr>
        <tr><td align="center" style="background-color:#F4F7FB; padding:16px 24px; font-size:11px; color:#5B6B8C;">
          EPAY POS &middot; 185 E Big Beaver Rd, Troy, MI 48083 &middot; epaypos.net
        </td></tr>
      </table>
    </td></tr>
  </table>
</body></html>`;

  // ---- send ----------------------------------------------------------------
  let sendErr: string | null = null;
  let providerId: string | null = null;

  try {
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ from, to: [to], subject, html }),
    });
    const out = await res.json().catch(() => ({}));
    if (!res.ok) {
      sendErr = out?.message || `Resend returned ${res.status}`;
    } else {
      providerId = out?.id ?? null;
    }
  } catch (e) {
    sendErr = e instanceof Error ? e.message : 'Could not reach Resend';
  }

  // ---- log it either way ---------------------------------------------------
  // Written with the service role so a failure is still recorded — the whole
  // point is being able to answer "did that go out?" afterwards.
  const adminClient = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );
  await adminClient.from('email_log').insert({
    kind,
    to_email: to,
    subject,
    lead_id: leadId ?? null,
    sent_by: (callerRow as { id?: string })?.id ?? null,
    provider_id: providerId,
    status: sendErr ? 'failed' : 'sent',
    error: sendErr,
  });

  if (sendErr) {
    return jsonResponse({ error: sendErr }, 502);
  }
  return jsonResponse({ success: true, id: providerId }, 200);
});

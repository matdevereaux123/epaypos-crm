// Supabase Edge Function: meeting-reminders
// ---------------------------------------------------------------------------
// Deploy with:  supabase functions deploy meeting-reminders
// (JWT verification ON — the only caller is pg_cron, authenticating with the
// real service_role key as its bearer token. See database/64_meeting_reminders.sql
// for the cron.schedule() call that invokes this once a minute.)
//
// Nobody's browser calls this. It has no action dispatch and no per-user
// identity check — it just does one job: find every calendar_events row
// with remind_before = true that is now inside its 30-minute window and has
// not been reminded yet, tell the owner and every attendee (bell + email),
// and stamp reminder_sent_at so the next tick leaves it alone.
//
// Environment variables:
//   RESEND_API_KEY, EMAIL_FROM   same as google-calendar/index.ts
//   CALENDAR_TIMEZONE            optional, defaults to America/Detroit
// ---------------------------------------------------------------------------

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

const TYPE_LABELS: Record<string, string> = {
  phone: 'Phone Call',
  zoom_meeting: 'Zoom Meeting',
  zoom_demo: 'Zoom Demo',
  in_person: 'In-Person Install/Training',
};

// Same double-conversion trick every zone-aware "is this due yet" check
// needs without a timezone library: format a guessed UTC instant back
// through the target zone, see how far off the wall-clock reading is, and
// correct by that difference. DST-safe because it reads the real offset for
// this specific date from Intl, not a fixed hour offset.
function zonedTimeToUtc(dateStr: string, timeStr: string, tz: string): Date {
  const [y, mo, d] = dateStr.split('-').map(Number);
  const [h, mi] = timeStr.split(':').map(Number);
  const guess = new Date(Date.UTC(y, mo - 1, d, h, mi));
  const fmt = new Intl.DateTimeFormat('en-US', {
    timeZone: tz, hour12: false,
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  });
  const parts = Object.fromEntries(fmt.formatToParts(guess).map(p => [p.type, p.value])) as Record<string, string>;
  const shownAsUtc = Date.UTC(
    Number(parts.year), Number(parts.month) - 1, Number(parts.day),
    Number(parts.hour) % 24, Number(parts.minute), Number(parts.second),
  );
  return new Date(guess.getTime() + (guess.getTime() - shownAsUtc));
}

function esc(v: string): string {
  return v.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

// Same 480px branded shell as google-calendar/index.ts's buildBrandedEmailHtml
// — duplicated rather than imported, since these are two separate Deno
// runtimes with no shared module between edge functions in this project.
function buildEmailHtml(heading: string, bodyText: string): string {
  return `<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>${esc(heading)}</title></head>
<body style="margin:0; padding:0; background-color:#F4F7FB; font-family:Arial, Helvetica, sans-serif;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color:#F4F7FB; padding:32px 16px;">
    <tr><td align="center">
      <table role="presentation" width="480" cellpadding="0" cellspacing="0" style="width:480px; max-width:100%; background-color:#ffffff; border-radius:10px; overflow:hidden; border:1px solid #E4E9F2;">
        <tr><td align="center" style="background-color:#ffffff; padding:24px; border-bottom:1px solid #E4E9F2;">
          <img src="https://epaycrm.epaypos.net/email-logo.png" alt="EPAY POS" width="90" style="display:block;">
        </td></tr>
        <tr><td style="padding:30px 26px;">
          <h1 style="margin:0 0 14px; font-size:19px; color:#142850;">${esc(heading)}</h1>
          <p style="margin:0; font-size:14px; line-height:1.6; color:#22406F;">${esc(bodyText).replace(/\n/g, '<br>')}</p>
          <p style="margin:16px 0 0; font-size:14px; line-height:1.6; color:#22406F;">&mdash; The EPAY POS Team</p>
        </td></tr>
        <tr><td align="center" style="background-color:#F4F7FB; padding:16px 24px; font-size:11px; color:#5B6B8C;">
          EPAY POS &middot; 185 E Big Beaver Rd, Troy, MI 48083 &middot; epaypos.net
        </td></tr>
      </table>
    </td></tr>
  </table>
</body></html>`;
}

async function sendEmail(
  admin: ReturnType<typeof createClient>,
  kind: string,
  to: string,
  subject: string,
  heading: string,
  bodyText: string,
) {
  const apiKey = Deno.env.get('RESEND_API_KEY');
  const from = Deno.env.get('EMAIL_FROM');
  if (!apiKey || !from || !to) return;

  let sendErr: string | null = null;
  let providerId: string | null = null;
  try {
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ from, to: [to], subject, html: buildEmailHtml(heading, bodyText) }),
    });
    const out = await res.json().catch(() => ({}));
    if (!res.ok) sendErr = out?.message || `Resend returned ${res.status}`;
    else providerId = out?.id ?? null;
  } catch (e) {
    sendErr = e instanceof Error ? e.message : 'Could not reach Resend';
  }

  await admin.from('email_log').insert({
    kind, to_email: to, subject, provider_id: providerId,
    status: sendErr ? 'failed' : 'sent', error: sendErr,
  });
}

Deno.serve(async (_req) => {
  const admin = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );
  const tz = Deno.env.get('CALENDAR_TIMEZONE') ?? 'America/Detroit';
  const now = new Date();

  // Bounded to today/tomorrow (in the calendar's own timezone) rather than
  // the whole table — a meeting further out than that can't be inside a
  // 30-minute window yet, and this runs every single minute.
  const todayLocal = new Intl.DateTimeFormat('en-CA', { timeZone: tz }).format(now); // en-CA => YYYY-MM-DD
  const tomorrowLocal = new Intl.DateTimeFormat('en-CA', { timeZone: tz })
    .format(new Date(now.getTime() + 24 * 60 * 60 * 1000));

  const { data: candidates, error } = await admin
    .from('calendar_events')
    .select('*')
    .eq('remind_before', true)
    .is('reminder_sent_at', null)
    .in('date', [todayLocal, tomorrowLocal]);

  if (error) return json({ error: error.message }, 500);
  if (!candidates || !candidates.length) return json({ due: 0 }, 200);

  let due = 0;
  for (const ev of candidates) {
    if (!ev.time || ev.all_day) continue; // "30 minutes before" needs an actual time
    const start = zonedTimeToUtc(ev.date as string, ev.time as string, tz);
    const minutesOut = (start.getTime() - now.getTime()) / 60000;
    if (minutesOut <= 0 || minutesOut > 30) continue; // not due yet, or already started

    due++;
    const recipientIds = Array.from(new Set([
      ev.owner_id as string | null,
      ...((Array.isArray(ev.attendee_user_ids) ? ev.attendee_user_ids : []) as string[]),
    ].filter((id): id is string => !!id)));

    if (recipientIds.length) {
      const { data: recipients } = await admin
        .from('users').select('id, name, email').in('id', recipientIds);

      const meetingLabel = TYPE_LABELS[ev.type as string] || 'meeting';
      const timeStr = ev.time as string;
      const [h, m] = timeStr.split(':').map(Number);
      const hr = h % 12 === 0 ? 12 : h % 12;
      const prettyTime = `${hr}:${String(m).padStart(2, '0')} ${h >= 12 ? 'PM' : 'AM'}`;

      const notifRows = (recipients ?? []).map((u: { id: string }) => ({
        user_id: u.id,
        type: 'meeting_reminder',
        title: `"${ev.title}" starts in 30 minutes`,
        body: `${meetingLabel} at ${prettyTime}${ev.zoom_link ? ` — ${ev.zoom_link}` : ''}`,
        link_view: 'calendar',
        link_id: ev.id,
      }));
      if (notifRows.length) await admin.from('notifications').insert(notifRows);

      for (const u of (recipients ?? []) as { id: string; name?: string; email?: string }[]) {
        if (!u.email) continue;
        await sendEmail(
          admin, 'meeting_reminder', u.email,
          `Starting soon: ${ev.title}`,
          'Starting in 30 minutes',
          `${ev.title} (${meetingLabel}) starts at ${prettyTime} today.${ev.zoom_link ? `\n\nJoin: ${ev.zoom_link}` : ''}`,
        );
      }
    }

    await admin.from('calendar_events').update({ reminder_sent_at: new Date().toISOString() }).eq('id', ev.id);
  }

  return json({ due }, 200);
});

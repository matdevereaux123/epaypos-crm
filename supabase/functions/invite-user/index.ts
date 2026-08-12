// Supabase Edge Function: invite-user
// ---------------------------------------------------------------------------
// Deploy with: supabase functions deploy invite-user
//
// This is what the app's "Send invite" / "Resend invite" button should
// call once real auth is wired in — replacing the current behavior of
// just marking invite_sent = true locally. This function:
//   1. Confirms the CALLER is logged in and has manageUsers permission
//      (only an admin can invite people — enforced here, not just hidden
//      in the UI).
//   2. Uses the service role key (safe here — this code runs on Supabase's
//      server, never in the browser) to send a real Supabase Auth invite
//      email to the target user.
//   3. Marks invite_sent/invite_sent_at on their public.users row.
//
// The person receives a real email with a secure link. Clicking it lands
// them on a "set your password" page in the app (see Step 4 below) — once
// they set one, the auth-link trigger from supabase_auth_link.sql connects
// their new login to their existing users row automatically.
//
// CORS: this is called directly from the browser (app/index.html), so it
// needs to handle the browser's preflight OPTIONS request and send back
// Access-Control-Allow-Origin on every response — without this, the browser
// blocks the request before it ever reaches the code above and supabase-js
// just reports a generic "Failed to send a request to the Edge Function".
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

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  const { userId } = await req.json();
  if (!userId) {
    return jsonResponse({ error: 'userId is required' }, 400);
  }

  // Client scoped to the CALLER's own auth token — used only to check who's
  // asking and whether they're allowed to invite people.
  const authHeader = req.headers.get('Authorization') ?? '';
  const callerClient = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: authHeader } } }
  );

  const { data: { user: caller } } = await callerClient.auth.getUser();
  if (!caller) {
    return jsonResponse({ error: 'Not authenticated' }, 401);
  }

  const { data: callerRow } = await callerClient
    .from('users')
    .select('role, roles!inner(perms)')
    .eq('auth_id', caller.id)
    .single();

  const canManageUsers = callerRow?.roles?.perms?.manageUsers === true;
  if (!canManageUsers) {
    return jsonResponse({ error: 'Not authorized to send invites' }, 403);
  }

  // Admin client — the service role key only ever lives here, server-side.
  const adminClient = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  );

  const { data: targetUser, error: targetErr } = await adminClient
    .from('users')
    .select('email, name')
    .eq('id', userId)
    .single();

  if (targetErr || !targetUser) {
    return jsonResponse({ error: 'User not found' }, 404);
  }

  const { error: inviteErr } = await adminClient.auth.admin.inviteUserByEmail(
    targetUser.email,
    { data: { name: targetUser.name, first_name: targetUser.name.split(' ')[0] } }  // available in the template as {{ .Data.first_name }}
  );

  if (inviteErr) {
    return jsonResponse({ error: inviteErr.message }, 500);
  }

  await adminClient
    .from('users')
    .update({ invite_sent: true, invite_sent_at: new Date().toISOString().slice(0, 10) })
    .eq('id', userId);

  return jsonResponse({ success: true }, 200);
});

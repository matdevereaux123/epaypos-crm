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
// ---------------------------------------------------------------------------

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

Deno.serve(async (req) => {
  const { userId } = await req.json();
  if (!userId) {
    return new Response(JSON.stringify({ error: 'userId is required' }), { status: 400 });
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
    return new Response(JSON.stringify({ error: 'Not authenticated' }), { status: 401 });
  }

  const { data: callerRow } = await callerClient
    .from('users')
    .select('role, roles!inner(perms)')
    .eq('auth_id', caller.id)
    .single();

  const canManageUsers = callerRow?.roles?.perms?.manageUsers === true;
  if (!canManageUsers) {
    return new Response(JSON.stringify({ error: 'Not authorized to send invites' }), { status: 403 });
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
    return new Response(JSON.stringify({ error: 'User not found' }), { status: 404 });
  }

  const { error: inviteErr } = await adminClient.auth.admin.inviteUserByEmail(
    targetUser.email,
    { data: { name: targetUser.name, first_name: targetUser.name.split(' ')[0] } }  // available in the template as {{ .Data.first_name }}
  );

  if (inviteErr) {
    return new Response(JSON.stringify({ error: inviteErr.message }), { status: 500 });
  }

  await adminClient
    .from('users')
    .update({ invite_sent: true, invite_sent_at: new Date().toISOString().slice(0, 10) })
    .eq('id', userId);

  return new Response(JSON.stringify({ success: true }), { status: 200 });
});

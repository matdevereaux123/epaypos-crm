// Supabase Edge Function: delete-user
// ---------------------------------------------------------------------------
// Deploy with: supabase functions deploy delete-user
//
// Deleting someone from Settings > Users used to remove their public.users
// row and leave their Supabase Auth account untouched. That account kept
// working: the person could still sign in, land on an app with no users row
// behind them, and the only sign anything was wrong was the broken state
// they arrived in. Revoking access has to mean revoking the login.
//
// Removing an auth user needs the service role, which can never be in
// app/index.html — hence a function. It does both halves here, in one place,
// so the browser cannot complete one and fail the other.
//
// ORDER MATTERS. The auth account goes first:
//   - auth first, row second: a failure after the auth delete leaves a users
//     row whose owner can no longer log in. Visible, harmless, retryable.
//   - row first, auth second: a failure leaves a working login with no users
//     row — exactly the state this function exists to prevent, and invisible
//     until that person next tries to sign in.
//
// public.users.auth_id is `references auth.users(id) on delete set null`, so
// deleting the auth account does NOT drag the users row with it. Both steps
// are deliberate.
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

  let userId: string | undefined;
  try {
    ({ userId } = await req.json());
  } catch {
    return jsonResponse({ error: 'Expected a JSON body' }, 400);
  }
  if (!userId) return jsonResponse({ error: 'userId is required' }, 400);

  // ---- who is asking -------------------------------------------------------
  const authHeader = req.headers.get('Authorization') ?? '';
  const callerClient = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: authHeader } } },
  );

  const { data: { user: caller } } = await callerClient.auth.getUser();
  if (!caller) return jsonResponse({ error: 'Not authenticated' }, 401);

  const { data: callerRow } = await callerClient
    .from('users')
    .select('id, role, roles!inner(perms)')
    .eq('auth_id', caller.id)
    .single();

  const perms = (callerRow as { roles?: { perms?: Record<string, unknown> } })?.roles?.perms ?? {};
  if (perms.manageUsers !== true) {
    return jsonResponse({ error: 'Not authorized to delete users' }, 403);
  }

  // Checked here as well as in the UI. Deleting your own login mid-session
  // logs you out of an account that no longer exists, and if you were the
  // only admin nobody can undo it.
  if ((callerRow as { id?: string })?.id === userId) {
    return jsonResponse({ error: 'You cannot delete the account you are signed in as.' }, 400);
  }

  const adminClient = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  const { data: target, error: targetErr } = await adminClient
    .from('users')
    .select('id, name, email, auth_id, role')
    .eq('id', userId)
    .single();

  if (targetErr || !target) return jsonResponse({ error: 'That user no longer exists.' }, 404);

  // ---- never remove the last way in ---------------------------------------
  // A CRM with no one holding manageUsers cannot create another admin from
  // inside itself — recovering means going into Supabase directly. Cheap to
  // check, expensive to get wrong.
  const { data: admins } = await adminClient
    .from('users')
    .select('id, roles!inner(perms)')
    .eq('roles.perms->>manageUsers', 'true');

  const adminIds = (admins ?? []).map((a: { id: string }) => a.id);
  if (adminIds.includes(userId) && adminIds.length <= 1) {
    return jsonResponse({
      error: `${target.name} is the only account that can manage users. Give someone else that role first, or the CRM would be left with no way to add one.`,
    }, 400);
  }

  // ---- 1. the auth account -------------------------------------------------
  let authDeleted = false;

  // auth_id is normally set by the on_auth_user_created trigger at invite
  // time. If it is missing, the account may still exist — an invite that was
  // sent before the trigger existed, or a row edited by hand. Falling back to
  // the email address is what stops this leaving a working orphan login.
  let authId: string | null = (target.auth_id as string | null) ?? null;

  if (!authId && target.email) {
    try {
      const { data: page } = await adminClient.auth.admin.listUsers({ page: 1, perPage: 1000 });
      const match = (page?.users ?? []).find(
        (u) => (u.email ?? '').toLowerCase() === String(target.email).toLowerCase(),
      );
      if (match) authId = match.id;
    } catch {
      // Not fatal on its own — reported below only if it leaves us unable to
      // remove a login we know about.
    }
  }

  if (authId) {
    const { error: authErr } = await adminClient.auth.admin.deleteUser(authId);
    // "not found" means the login is already gone, which is the outcome we
    // wanted. Anything else stops the whole thing: better a user who still
    // exists than one whose record is gone and whose login still works.
    if (authErr && !/not.?found/i.test(authErr.message)) {
      return jsonResponse({
        error: `Could not remove their Supabase login, so nothing was deleted: ${authErr.message}`,
      }, 500);
    }
    authDeleted = true;
  }

  // ---- 2. the CRM row ------------------------------------------------------
  const { error: rowErr } = await adminClient.from('users').delete().eq('id', userId);
  if (rowErr) {
    return jsonResponse({
      error: authDeleted
        ? `Their login was removed, but their user record could not be deleted: ${rowErr.message}. They can no longer sign in — delete the record again to finish.`
        : `Could not delete: ${rowErr.message}`,
    }, 500);
  }

  return jsonResponse({
    success: true,
    authDeleted,
    // false here means there was no login to remove — the person was added
    // but never invited. Worth telling the UI so it does not claim otherwise.
    name: target.name,
  }, 200);
});

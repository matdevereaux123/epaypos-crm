// =============================================================================
// pos-admin — may this person open the EPAY admin portal, and who are they?
//
// ADR-0016 serves the admin portal from this CRM at /admin, on the CRM's own
// origin, so it signs in with the Control Center session somebody already has.
// This is the thing that answers whether that session is allowed in.
//
// WHAT IT DOES NOT DO, YET
// It does not board merchants or move stations. Those are routes on the POS
// API, which has no deployment until the hosting decision is made, and a
// proxy to nothing would be a worse lie than an honest gap. This is the gate;
// the rest arrives behind the same door.
//
// WHY A FUNCTION AND NOT A QUERY FROM THE PAGE
// The portal could read users.epay_admin directly with the caller's own token
// — RLS would even allow it, since everybody may read their own row. But a
// check the page performs is a check the page can be persuaded to skip. This
// runs somewhere the browser cannot reach, and it is where the POS API's
// credential will live when there is one.
//
// REVOCATION IS IMMEDIATE
// Read live, every call, never cached and never copied into the session. Untick
// somebody while they are looking at the portal and their next request is
// refused. That was the explicit ask: it is what you want the day somebody
// leaves, and a flag baked into a twelve-hour session is not.
//
// Modelled on invite-user, including the two clients: one scoped to the
// caller's own token for deciding who is asking, one with the service role
// that never leaves the server.
// =============================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

/*
 * Same origin as the CRM in a deployment, so '*' is wider than it needs to
 * be. It stays wide because this answers with a yes/no about the caller's own
 * account and nothing else — there is nothing here worth stealing with a
 * cross-origin read, and a wrong origin list is a support call on the day of
 * the cutover.
 */
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

  // Scoped to the CALLER's own token: this decides who is asking, so it must
  // not be able to see further than they can.
  const authHeader = req.headers.get('Authorization') ?? '';
  const callerClient = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: authHeader } } }
  );

  const { data: { user: caller } } = await callerClient.auth.getUser();
  if (!caller) {
    return jsonResponse({ allowed: false, error: 'Not signed in' }, 401);
  }

  const { data: row, error } = await callerClient
    .from('users')
    .select('id, name, email, role, epay_admin')
    .eq('auth_id', caller.id)
    .single();

  /*
   * A Control Center login with no users row is somebody mid-invite, or a
   * row that was deleted while they were signed in. Refused the same way as
   * an unticked one: one answer for every no, so the refusal says nothing
   * about which accounts exist or what state they are in.
   */
  if (error || !row || row.epay_admin !== true) {
    return jsonResponse({ allowed: false, error: 'No admin access' }, 403);
  }

  return jsonResponse(
    {
      allowed: true,
      user: {
        id: row.id,
        name: row.name,
        email: row.email,
        role: row.role,
      },
    },
    200
  );
});

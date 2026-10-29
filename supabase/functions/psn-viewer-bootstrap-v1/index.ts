import { createClient } from 'npm:@supabase/supabase-js@2.57.0'

const allowedOrigins = new Set([
  'https://risingphnxhq.github.io',
])

function responseHeaders(origin: string | null): HeadersInit {
  const headers: Record<string, string> = {
    'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Cache-Control': 'no-store',
    'Content-Type': 'application/json; charset=utf-8',
    'Vary': 'Origin',
  }
  if (origin && allowedOrigins.has(origin)) headers['Access-Control-Allow-Origin'] = origin
  return headers
}

function json(status: number, body: Record<string, unknown>, origin: string | null) {
  return new Response(JSON.stringify(body), { status, headers: responseHeaders(origin) })
}

function secretFromEnv(jsonName: string, legacyName: string): string {
  const bundle = Deno.env.get(jsonName)
  if (bundle) {
    try {
      const parsed = JSON.parse(bundle) as Record<string, string>
      if (parsed.default) return parsed.default
    } catch {
      // Fall through to legacy env for projects that have not migrated keys.
    }
  }
  return Deno.env.get(legacyName) ?? ''
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get('Origin')
  if (req.method === 'OPTIONS') {
    if (origin && !allowedOrigins.has(origin)) return new Response(null, { status: 403, headers: responseHeaders(null) })
    return new Response(null, { status: 204, headers: responseHeaders(origin) })
  }
  if (req.method !== 'POST') return json(405, { error: 'method_not_allowed' }, origin)
  if (origin && !allowedOrigins.has(origin)) return json(403, { error: 'origin_not_allowed' }, null)

  const authorization = req.headers.get('Authorization')
  const token = authorization?.match(/^Bearer\s+(.+)$/i)?.[1]
  if (!token) return json(401, { error: 'authentication_required' }, origin)

  const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? ''
  const publishableKey = secretFromEnv('SUPABASE_PUBLISHABLE_KEYS', 'SUPABASE_ANON_KEY')
  const serviceKey = secretFromEnv('SUPABASE_SECRET_KEYS', 'SUPABASE_SERVICE_ROLE_KEY')
  if (!supabaseUrl || !publishableKey || !serviceKey) {
    return json(503, { error: 'viewer_service_unavailable' }, origin)
  }

  const authClient = createClient(supabaseUrl, publishableKey, {
    auth: { autoRefreshToken: false, persistSession: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  })
  const { data: authData, error: authError } = await authClient.auth.getUser(token)
  const user = authData.user
  if (authError || !user) return json(401, { error: 'invalid_session' }, origin)
  if (!user.email || !user.email_confirmed_at) {
    return json(403, { error: 'verified_email_required' }, origin)
  }

  let displayName: string | null = null
  const suppliedName = user.user_metadata?.full_name ?? user.user_metadata?.name
  if (typeof suppliedName === 'string') {
    const cleanName = suppliedName.trim().replace(/[\u0000-\u001f\u007f]/g, '').slice(0, 80)
    displayName = cleanName || null
  }

  const serviceClient = createClient(supabaseUrl, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  })
  const { data: account, error: accountError } = await serviceClient
    .from('psn_viewer_accounts')
    .upsert({
      viewer_id: user.id,
      email: user.email.toLowerCase(),
      display_name: displayName,
    }, { onConflict: 'viewer_id' })
    .select('viewer_id,display_name,subscription_status,access_tier')
    .single()

  if (accountError || !account) {
    // Do not disclose whether the email is already attached to a different viewer.
    const duplicateEmail = accountError?.code === '23505'
    return json(duplicateEmail ? 409 : 500, {
      error: duplicateEmail ? 'viewer_account_link_conflict' : 'viewer_account_unavailable',
    }, origin)
  }

  return json(200, {
    account: {
      viewer_id: account.viewer_id,
      display_name: account.display_name,
      subscription_status: account.subscription_status,
      access_tier: account.access_tier,
    },
  }, origin)
})

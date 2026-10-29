import { createClient } from 'npm:@supabase/supabase-js@2.57.0'

const allowedOrigins = new Set(['https://risingphnxhq.github.io'])
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

function headers(origin: string | null): HeadersInit {
  const result: Record<string, string> = {
    'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Cache-Control': 'no-store',
    'Content-Type': 'application/json; charset=utf-8',
    'Vary': 'Origin',
  }
  if (origin && allowedOrigins.has(origin)) result['Access-Control-Allow-Origin'] = origin
  return result
}

function json(status: number, body: Record<string, unknown>, origin: string | null) {
  return new Response(JSON.stringify(body), { status, headers: headers(origin) })
}

function envKey(bundleName: string, legacyName: string): string {
  const bundle = Deno.env.get(bundleName)
  if (bundle) {
    try {
      const parsed = JSON.parse(bundle) as Record<string, string>
      if (parsed.default) return parsed.default
    } catch {
      // Support projects which still expose the legacy key variables.
    }
  }
  return Deno.env.get(legacyName) ?? ''
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get('Origin')
  if (req.method === 'OPTIONS') {
    if (origin && !allowedOrigins.has(origin)) return new Response(null, { status: 403, headers: headers(null) })
    return new Response(null, { status: 204, headers: headers(origin) })
  }
  if (req.method !== 'POST') return json(405, { error: 'method_not_allowed' }, origin)
  if (origin && !allowedOrigins.has(origin)) return json(403, { error: 'origin_not_allowed' }, null)

  const authorization = req.headers.get('Authorization')
  const token = authorization?.match(/^Bearer\s+(.+)$/i)?.[1]
  if (!token) return json(401, { error: 'authentication_required' }, origin)

  let payload: unknown
  try {
    payload = await req.json()
  } catch {
    return json(400, { error: 'invalid_request' }, origin)
  }
  const episodeId = (payload as { episode_id?: unknown } | null)?.episode_id
  if (typeof episodeId !== 'string' || !uuidPattern.test(episodeId)) {
    return json(400, { error: 'valid_episode_id_required' }, origin)
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? ''
  const publishableKey = envKey('SUPABASE_PUBLISHABLE_KEYS', 'SUPABASE_ANON_KEY')
  const serviceKey = envKey('SUPABASE_SECRET_KEYS', 'SUPABASE_SERVICE_ROLE_KEY')
  if (!supabaseUrl || !publishableKey || !serviceKey) {
    return json(503, { error: 'playback_service_unavailable' }, origin)
  }

  const authClient = createClient(supabaseUrl, publishableKey, {
    auth: { autoRefreshToken: false, persistSession: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  })
  const { data: authData, error: authError } = await authClient.auth.getUser(token)
  const user = authData.user
  if (authError || !user) return json(401, { error: 'invalid_session' }, origin)
  if (!user.email || !user.email_confirmed_at) return json(403, { error: 'verified_email_required' }, origin)

  const service = createClient(supabaseUrl, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  })

  const { data: episode, error: episodeError } = await service
    .from('psn_episodes')
    .select('episode_id,status,access_tier')
    .eq('episode_id', episodeId)
    .maybeSingle()
  if (episodeError) return json(503, { error: 'episode_lookup_unavailable' }, origin)
  if (!episode || episode.status !== 'live') return json(404, { error: 'episode_not_available' }, origin)

  const { data: account, error: accountError } = await service
    .from('psn_viewer_accounts')
    .select('subscription_status,access_tier')
    .eq('viewer_id', user.id)
    .maybeSingle()
  if (accountError) return json(503, { error: 'viewer_lookup_unavailable' }, origin)
  if (!account) return json(403, { error: 'viewer_account_required' }, origin)

  const episodeTier = String(episode.access_tier ?? '').toLowerCase()
  const viewerTier = String(account.access_tier ?? '').toLowerCase()
  const subscriptionStatus = String(account.subscription_status ?? '').toLowerCase()
  if (['subscriber', 'subscriber_only', 'premium'].includes(episodeTier)) {
    const entitled = ['subscriber', 'premium'].includes(viewerTier) && ['active', 'trialing'].includes(subscriptionStatus)
    if (!entitled) return json(403, { error: 'subscription_required' }, origin)
  } else if (!['free', 'public', 'open'].includes(episodeTier)) {
    return json(403, { error: 'episode_access_tier_unavailable' }, origin)
  }

  const { data: releaseAsset, error: assetError } = await service
    .from('psn_release_assets')
    .select('bucket_id,object_path,mime_type,approval_receipt_id')
    .eq('episode_id', episodeId)
    .eq('asset_role', 'full')
    .eq('status', 'released')
    .maybeSingle()
  if (assetError) return json(503, { error: 'release_lookup_unavailable' }, origin)
  if (!releaseAsset || releaseAsset.bucket_id !== 'pmf-animation-private' || releaseAsset.mime_type !== 'video/mp4' || !releaseAsset.approval_receipt_id) {
    return json(404, { error: 'released_video_not_available' }, origin)
  }

  const { data: signed, error: signingError } = await service.storage
    .from('pmf-animation-private')
    .createSignedUrl(releaseAsset.object_path, 1800)
  if (signingError || !signed?.signedUrl) return json(503, { error: 'playback_link_unavailable' }, origin)

  return json(200, {
    episode_id: episodeId,
    playback_url: signed.signedUrl,
    expires_in_seconds: 1800,
    mime_type: 'video/mp4',
  }, origin)
})

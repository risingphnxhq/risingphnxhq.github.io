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
      // Support projects that have not migrated to key bundles.
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

  const token = req.headers.get('Authorization')?.match(/^Bearer\s+(.+)$/i)?.[1]
  if (!token) return json(401, { error: 'authentication_required' }, origin)

  let payload: unknown
  try {
    payload = await req.json()
  } catch {
    return json(400, { error: 'invalid_request' }, origin)
  }

  const request = payload as Record<string, unknown> | null
  const episodeId = request?.episode_id
  const certificateId = request?.pcc_certificate_id
  const cepJobId = request?.cep_job_id
  const pmfExecutionId = request?.pmf_execution_id
  if (typeof episodeId !== 'string' || !uuidPattern.test(episodeId)
      || typeof cepJobId !== 'string' || !uuidPattern.test(cepJobId)
      || typeof pmfExecutionId !== 'string' || !uuidPattern.test(pmfExecutionId)
      || typeof certificateId !== 'string' || certificateId.trim().length < 1 || certificateId.trim().length > 200) {
    return json(400, { error: 'release_receipt_fields_invalid' }, origin)
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? ''
  const publishableKey = envKey('SUPABASE_PUBLISHABLE_KEYS', 'SUPABASE_ANON_KEY')
  const serviceKey = envKey('SUPABASE_SECRET_KEYS', 'SUPABASE_SERVICE_ROLE_KEY')
  if (!supabaseUrl || !publishableKey || !serviceKey) {
    return json(503, { error: 'release_service_unavailable' }, origin)
  }

  const auth = createClient(supabaseUrl, publishableKey, {
    auth: { autoRefreshToken: false, persistSession: false },
    global: { headers: { Authorization: 'Bearer ' + token } },
  })
  const { data, error } = await auth.auth.getUser(token)
  if (error || !data.user) return json(401, { error: 'invalid_session' }, origin)
  if (!data.user.email || !data.user.email_confirmed_at) return json(403, { error: 'verified_email_required' }, origin)

  const actorId = data.user.app_metadata?.pcc_actor_id
  if (typeof actorId !== 'string' || !actorId.trim()) {
    return json(403, { error: 'pcc_release_authority_required' }, origin)
  }

  const service = createClient(supabaseUrl, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  })
  const { data: result, error: releaseError } = await service.rpc('psn_release_approved_episode_v1', {
    p_actor_id: actorId,
    p_episode_id: episodeId,
    p_certificate_id: certificateId.trim(),
    p_cep_job_id: cepJobId,
    p_pmf_execution_id: pmfExecutionId,
  })
  if (releaseError || !result || result.ok !== true) {
    return json(409, { error: 'release_evidence_not_eligible' }, origin)
  }
  return json(200, result as Record<string, unknown>, origin)
})
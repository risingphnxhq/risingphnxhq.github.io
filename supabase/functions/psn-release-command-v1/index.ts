import { createClient } from 'npm:@supabase/supabase-js@2.57.0'

const allowedOrigins = new Set([
  'https://risingphnxhq.github.io',
  'https://phoenix-builder-runner.tsteelefpa.workers.dev',
])
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

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

function json(status: number, body: Record<string, unknown>, origin: string | null): Response {
  return new Response(JSON.stringify(body), { status, headers: responseHeaders(origin) })
}

function keyFrom(bundleName: string, legacyName: string): string {
  const bundle = Deno.env.get(bundleName)
  if (bundle) {
    try {
      const parsed = JSON.parse(bundle) as Record<string, string>
      if (parsed.default) return parsed.default
    } catch {
      // Older secret layouts use a single named environment variable.
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

  const token = req.headers.get('Authorization')?.match(/^Bearer\s+(.+)$/i)?.[1]
  if (!token) return json(401, { error: 'authentication_required' }, origin)

  let body: unknown
  try {
    body = await req.json()
  } catch {
    return json(400, { error: 'invalid_request' }, origin)
  }
  const input = body as Record<string, unknown> | null
  const episodeId = input?.episode_id
  const certificateId = input?.pcc_certificate_id
  const cepJobId = input?.cep_job_id
  const pmfExecutionId = input?.pmf_execution_id
  if (typeof episodeId !== 'string' || !uuidPattern.test(episodeId)
      || typeof cepJobId !== 'string' || !uuidPattern.test(cepJobId)
      || typeof pmfExecutionId !== 'string' || !uuidPattern.test(pmfExecutionId)
      || typeof certificateId !== 'string' || certificateId.trim().length < 1 || certificateId.trim().length > 200) {
    return json(400, { error: 'release_command_fields_invalid' }, origin)
  }

  const url = Deno.env.get('SUPABASE_URL') ?? ''
  const publishableKey = keyFrom('SUPABASE_PUBLISHABLE_KEYS', 'SUPABASE_ANON_KEY')
  const serviceKey = keyFrom('SUPABASE_SECRET_KEYS', 'SUPABASE_SERVICE_ROLE_KEY')
  if (!url || !publishableKey || !serviceKey) return json(503, { error: 'release_service_unavailable' }, origin)

  const auth = createClient(url, publishableKey, {
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

  const service = createClient(url, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  })
  const { data: queued, error: enqueueError } = await service.rpc('psn_release_enqueue_v1', {
    p_actor_id: actorId,
    p_episode_id: episodeId,
    p_certificate_id: certificateId.trim(),
    p_cep_job_id: cepJobId,
    p_pmf_execution_id: pmfExecutionId,
  })
  if (enqueueError || !queued || queued.ok !== true) {
    return json(409, { error: 'release_evidence_not_eligible' }, origin)
  }

  const { data: result, error: processError } = await service.rpc('psn_release_process_v1', {
    p_cep_job_id: cepJobId,
    p_worker_id: 'phnx-phanimation-release-worker-v1',
  })
  if (processError || !result || result.ok !== true) {
    return json(409, { error: 'release_evidence_not_eligible' }, origin)
  }
  return json(200, result as Record<string, unknown>, origin)
})
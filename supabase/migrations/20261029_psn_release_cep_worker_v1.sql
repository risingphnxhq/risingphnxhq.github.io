-- Purpose-specific PHNX Phanimation release queue and CEP worker.
-- All IDs are supplied before certificate issuance so the PCC evidence manifest
-- can bind the exact CEP job that will process this release.
create or replace function public.psn_release_enqueue_v1(
  p_actor_id text,
  p_episode_id uuid,
  p_certificate_id text,
  p_cep_job_id uuid,
  p_pmf_execution_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, storage, pcc_institutional
as $function$
declare
  v_episode public.psn_episodes%rowtype;
  v_certificate pcc_institutional.certificates_of_approval%rowtype;
  v_pmf_job pcc_institutional.pmf_animation_jobs%rowtype;
  v_storage_path text;
  v_artifact_bytes integer;
  v_artifact_sha text;
  v_storage_mime text;
  v_storage_bytes bigint;
  v_params jsonb;
  v_existing public.cep_v2_jobs%rowtype;
begin
  if p_actor_id is null or p_actor_id = '' then
    raise exception 'release_authority_required' using errcode = '42501';
  end if;
  if not exists (
    select 1
    from pcc_institutional.actors a
    join pcc_institutional.authority_assignments aa on aa.actor_id = a.actor_id
    where a.actor_id = p_actor_id
      and a.status = 'ACTIVE'
      and aa.status = 'ACTIVE'
      and aa.authority_code = 'RPE-SOVEREIGN'
      and aa.capabilities ? 'FINAL_AUTHORITY'
      and (aa.valid_from is null or aa.valid_from <= now())
      and (aa.valid_until is null or aa.valid_until > now())
  ) then
    raise exception 'release_authority_required' using errcode = '42501';
  end if;

  select * into v_episode
  from public.psn_episodes
  where episode_id = p_episode_id;
  if not found or v_episode.status not in ('draft','pending','live') then
    raise exception 'episode_not_releasable' using errcode = 'P0001';
  end if;

  select * into v_certificate
  from pcc_institutional.certificates_of_approval
  where certificate_id = p_certificate_id;
  if not found
     or v_certificate.state is distinct from 'ISSUED'
     or v_certificate.disposition is distinct from 'PASS'
     or v_certificate.system_code is distinct from 'PHNX_PHANIMATION'
     or v_certificate.market_ready is distinct from true
     or coalesce(v_certificate.readiness_percent,0) < 100
     or coalesce(v_certificate.blocking_issue_count,1) <> 0
     or coalesce(v_certificate.critical_high_blocker_count,1) <> 0
     or v_certificate.revoked_at is not null
     or (v_certificate.expires_at is not null and v_certificate.expires_at <= now())
     or not exists (
       select 1 from jsonb_array_elements(coalesce(v_certificate.evidence_manifest,'[]'::jsonb)) e
       where e->>'episode_id' = p_episode_id::text
         and e->>'pmf_execution_id' = p_pmf_execution_id::text
         and e->>'cep_job_id' = p_cep_job_id::text
     )
  then
    raise exception 'pcc_release_certificate_invalid' using errcode = 'P0001';
  end if;

  select * into v_pmf_job
  from pcc_institutional.pmf_animation_jobs
  where execution_id = p_pmf_execution_id;
  if not found
     or upper(coalesce(v_pmf_job.mode,'')) <> 'PRODUCTION'
     or coalesce(v_pmf_job.frame_count,0) <= 0
     or v_pmf_job.result->'quality_approved' is distinct from 'true'::jsonb
     or v_pmf_job.result#>>'{video,mime_type}' is distinct from 'video/mp4'
  then
    raise exception 'pmf_production_qa_not_approved' using errcode = 'P0001';
  end if;

  select storage_path,bytes,sha256
    into v_storage_path,v_artifact_bytes,v_artifact_sha
  from pcc_institutional.pmf_animation_artifacts
  where execution_id = p_pmf_execution_id and artifact_key = 'video';
  if not found
     or v_storage_path is null
     or v_artifact_bytes is null or v_artifact_bytes <= 0
     or v_artifact_sha is null
     or v_pmf_job.result#>>'{video,sha256}' is distinct from v_artifact_sha
     or v_pmf_job.result#>>'{video,storage_ref}' is distinct from ('pmf-animation-private/' || v_storage_path)
  then
    raise exception 'pmf_video_artifact_mismatch' using errcode = 'P0001';
  end if;

  select metadata->>'mimetype',nullif(metadata->>'size','')::bigint
    into v_storage_mime,v_storage_bytes
  from storage.objects
  where bucket_id = 'pmf-animation-private' and name = v_storage_path;
  if not found or v_storage_mime is distinct from 'video/mp4' or v_storage_bytes is distinct from v_artifact_bytes::bigint then
    raise exception 'private_video_object_unavailable' using errcode = 'P0001';
  end if;

  v_params := jsonb_build_object(
    'release_target','PHNX_PHANIMATION',
    'episode_id',p_episode_id::text,
    'pcc_certificate_id',p_certificate_id,
    'pmf_execution_id',p_pmf_execution_id::text,
    'requested_by_actor_id',p_actor_id
  );

  select * into v_existing from public.cep_v2_jobs where id = p_cep_job_id for update;
  if found then
    if v_existing.cep_id = 'PHNX-PHANIMATION-PSN-RELEASE-V1'
       and v_existing.domain = 'psn_release'
       and v_existing.params = v_params
    then
      return jsonb_build_object('ok',true,'state',v_existing.status,'cep_job_id',p_cep_job_id,'idempotent',true);
    end if;
    raise exception 'cep_job_id_conflict' using errcode = 'P0001';
  end if;

  insert into public.cep_v2_jobs(id,cep_id,domain,params,priority,scheduled_at,status)
  values(p_cep_job_id,'PHNX-PHANIMATION-PSN-RELEASE-V1','psn_release',v_params,10,now(),'QUEUED');

  return jsonb_build_object('ok',true,'state','QUEUED','cep_job_id',p_cep_job_id);
end
$function$;

create or replace function public.psn_release_process_v1(
  p_cep_job_id uuid,
  p_worker_id text default 'phnx-phanimation-release-worker-v1'
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, storage, pcc_institutional
as $function$
declare
  v_job public.cep_v2_jobs%rowtype;
  v_episode_id uuid;
  v_certificate_id text;
  v_pmf_execution_id uuid;
  v_actor_id text;
  v_video_path text;
  v_video_sha text;
  v_video_bytes integer;
  v_cep_artifact_id uuid;
  v_release jsonb;
  v_error text;
begin
  if p_worker_id is null or length(trim(p_worker_id)) < 3 then
    raise exception 'worker_identity_required' using errcode = '42501';
  end if;

  select * into v_job
  from public.cep_v2_jobs
  where id = p_cep_job_id
  for update;

  if not found
     or v_job.cep_id is distinct from 'PHNX-PHANIMATION-PSN-RELEASE-V1'
     or v_job.domain is distinct from 'psn_release'
  then
    raise exception 'psn_release_job_not_found' using errcode = 'P0001';
  end if;

  if v_job.status = 'DONE' then
    v_episode_id := (v_job.params->>'episode_id')::uuid;
    v_certificate_id := v_job.params->>'pcc_certificate_id';
    v_pmf_execution_id := (v_job.params->>'pmf_execution_id')::uuid;
    v_actor_id := v_job.params->>'requested_by_actor_id';
    return public.psn_release_approved_episode_v1(v_actor_id,v_episode_id,v_certificate_id,p_cep_job_id,v_pmf_execution_id);
  end if;

  if v_job.status is distinct from 'QUEUED' then
    raise exception 'psn_release_job_not_queued' using errcode = 'P0001';
  end if;

  update public.cep_v2_jobs
  set status='PROCESSING',locked_at=now(),locked_by=p_worker_id,started_at=coalesce(started_at,now()),updated_at=now()
  where id=p_cep_job_id;

  begin
    v_episode_id := (v_job.params->>'episode_id')::uuid;
    v_certificate_id := v_job.params->>'pcc_certificate_id';
    v_pmf_execution_id := (v_job.params->>'pmf_execution_id')::uuid;
    v_actor_id := v_job.params->>'requested_by_actor_id';

    if v_job.params->>'release_target' is distinct from 'PHNX_PHANIMATION' then
      raise exception 'psn_release_target_invalid';
    end if;

    select storage_path,sha256,bytes
      into v_video_path,v_video_sha,v_video_bytes
    from pcc_institutional.pmf_animation_artifacts
    where execution_id=v_pmf_execution_id and artifact_key='video';
    if not found or v_video_path is null or v_video_sha is null or v_video_bytes is null then
      raise exception 'pmf_video_artifact_missing';
    end if;

    insert into public.cep_v2_artifacts(job_id,artifact_type,title,storage_path,content_hash,metadata)
    values(
      p_cep_job_id,
      'psn_release_receipt',
      'PHNX Phanimation approved episode release receipt',
      'receipt://psn_release/' || p_cep_job_id::text,
      v_video_sha,
      jsonb_build_object(
        'episode_id',v_episode_id::text,
        'pcc_certificate_id',v_certificate_id,
        'pmf_execution_id',v_pmf_execution_id::text,
        'video_sha256',v_video_sha,
        'video_bytes',v_video_bytes,
        'worker_id',p_worker_id,
        'release_target','PHNX_PHANIMATION'
      )
    )
    returning id into v_cep_artifact_id;

    update public.cep_v2_jobs
    set status='DONE',completed_at=now(),updated_at=now()
    where id=p_cep_job_id;

    v_release := public.psn_release_approved_episode_v1(
      v_actor_id,v_episode_id,v_certificate_id,p_cep_job_id,v_pmf_execution_id
    );

    return jsonb_build_object(
      'ok',true,
      'state',coalesce(v_release->>'state','released'),
      'cep_job_id',p_cep_job_id,
      'cep_artifact_id',v_cep_artifact_id,
      'episode_id',v_episode_id,
      'release_asset_id',v_release->>'release_asset_id'
    );
  exception when others then
    get stacked diagnostics v_error = message_text;
    update public.cep_v2_jobs
    set status='FAILED',
        completed_at=now(),
        error_code='PSN_RELEASE_EVIDENCE_REJECTED',
        error_message=left(coalesce(v_error,'release evidence rejected'),500),
        updated_at=now()
    where id=p_cep_job_id;
    return jsonb_build_object('ok',false,'state','FAILED','cep_job_id',p_cep_job_id,'error','release_evidence_not_eligible');
  end;
end
$function$;

revoke all on function public.psn_release_enqueue_v1(text,uuid,text,uuid,uuid) from public,anon,authenticated;
grant execute on function public.psn_release_enqueue_v1(text,uuid,text,uuid,uuid) to service_role;
revoke all on function public.psn_release_process_v1(uuid,text) from public,anon,authenticated;
grant execute on function public.psn_release_process_v1(uuid,text) to service_role;
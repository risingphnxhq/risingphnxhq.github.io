create or replace function public.psn_release_approved_episode_v1(
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
  v_cep_job public.cep_v2_jobs%rowtype;
  v_storage_path text;
  v_artifact_bytes integer;
  v_artifact_sha text;
  v_storage_mime text;
  v_storage_bytes bigint;
  v_video_sha text;
  v_receipt_asset_id uuid;
  v_existing public.psn_release_assets%rowtype;
begin
  if p_actor_id is null or p_actor_id = '' then
    raise exception 'release_authority_required' using errcode = '42501';
  end if;
  if not exists (
    select 1 from pcc_institutional.actors a
    join pcc_institutional.authority_assignments aa on aa.actor_id = a.actor_id
    where a.actor_id = p_actor_id and a.status = 'ACTIVE' and aa.status = 'ACTIVE'
      and aa.authority_code = 'RPE-SOVEREIGN' and aa.capabilities ? 'FINAL_AUTHORITY'
      and (aa.valid_from is null or aa.valid_from <= now())
      and (aa.valid_until is null or aa.valid_until > now())
  ) then raise exception 'release_authority_required' using errcode = '42501'; end if;

  select * into v_episode from public.psn_episodes where episode_id = p_episode_id for update;
  if not found or v_episode.status not in ('draft','pending','live') then
    raise exception 'episode_not_releasable' using errcode = 'P0001';
  end if;

  select * into v_certificate from pcc_institutional.certificates_of_approval where certificate_id = p_certificate_id;
  if not found or v_certificate.state is distinct from 'ISSUED'
     or v_certificate.disposition is distinct from 'PASS'
     or v_certificate.system_code is distinct from 'PHNX_PHANIMATION'
     or v_certificate.market_ready is distinct from true
     or coalesce(v_certificate.readiness_percent, 0) < 100
     or coalesce(v_certificate.blocking_issue_count, 1) <> 0
     or coalesce(v_certificate.critical_high_blocker_count, 1) <> 0
     or v_certificate.revoked_at is not null
     or (v_certificate.expires_at is not null and v_certificate.expires_at <= now())
     or not exists (
       select 1 from jsonb_array_elements(coalesce(v_certificate.evidence_manifest, '[]'::jsonb)) evidence
       where evidence->>'episode_id' = p_episode_id::text
         and evidence->>'pmf_execution_id' = p_pmf_execution_id::text
         and evidence->>'cep_job_id' = p_cep_job_id::text
     ) then raise exception 'pcc_release_certificate_invalid' using errcode = 'P0001'; end if;

  select * into v_pmf_job from pcc_institutional.pmf_animation_jobs where execution_id = p_pmf_execution_id;
  if not found or upper(coalesce(v_pmf_job.mode,'')) <> 'PRODUCTION'
     or coalesce(v_pmf_job.frame_count, 0) <= 0
     or v_pmf_job.result->'quality_approved' is distinct from 'true'::jsonb
     or v_pmf_job.result#>>'{video,mime_type}' is distinct from 'video/mp4'
    then raise exception 'pmf_production_qa_not_approved' using errcode = 'P0001'; end if;

  select storage_path, bytes, sha256 into v_storage_path, v_artifact_bytes, v_artifact_sha
  from pcc_institutional.pmf_animation_artifacts
  where execution_id = p_pmf_execution_id and artifact_key = 'video';
  if not found or v_storage_path is null or v_artifact_bytes is null or v_artifact_bytes <= 0
     or v_artifact_sha is null
     or v_pmf_job.result#>>'{video,sha256}' is distinct from v_artifact_sha
     or v_pmf_job.result#>>'{video,storage_ref}' is distinct from ('pmf-animation-private/' || v_storage_path)
    then raise exception 'pmf_video_artifact_mismatch' using errcode = 'P0001'; end if;

  select metadata->>'mimetype', nullif(metadata->>'size','')::bigint
    into v_storage_mime, v_storage_bytes from storage.objects
  where bucket_id = 'pmf-animation-private' and name = v_storage_path;
  if not found or v_storage_mime is distinct from 'video/mp4'
     or v_storage_bytes is distinct from v_artifact_bytes::bigint
    then raise exception 'private_video_object_unavailable' using errcode = 'P0001'; end if;

  v_video_sha := v_artifact_sha;
  select * into v_cep_job from public.cep_v2_jobs where id = p_cep_job_id;
  if not found or v_cep_job.status is distinct from 'DONE'
     or v_cep_job.domain is distinct from 'psn_release'
     or v_cep_job.params->>'release_target' is distinct from 'PHNX_PHANIMATION'
     or v_cep_job.params->>'episode_id' is distinct from p_episode_id::text
     or v_cep_job.params->>'pcc_certificate_id' is distinct from p_certificate_id
     or v_cep_job.params->>'pmf_execution_id' is distinct from p_pmf_execution_id::text
     or not exists (
       select 1 from public.cep_v2_artifacts ca
       where ca.job_id = p_cep_job_id and ca.artifact_type = 'psn_release_receipt'
         and ca.metadata->>'episode_id' = p_episode_id::text
         and ca.metadata->>'pcc_certificate_id' = p_certificate_id
         and ca.metadata->>'pmf_execution_id' = p_pmf_execution_id::text
         and ca.metadata->>'video_sha256' = v_video_sha
     ) then raise exception 'cep_release_receipt_invalid' using errcode = 'P0001'; end if;

  select * into v_existing from public.psn_release_assets
  where episode_id = p_episode_id and asset_role = 'full' and status = 'released';
  if found then
    if v_existing.cep_job_id is not distinct from p_cep_job_id
       and v_existing.approval_receipt_id = p_certificate_id
       and v_existing.source_asset_id = p_pmf_execution_id::text || ':video'
       and v_existing.sha256 = v_video_sha then
      return jsonb_build_object('ok', true, 'state', 'already_released',
        'episode_id', p_episode_id, 'release_asset_id', v_existing.release_asset_id);
    end if;
    raise exception 'episode_has_different_released_asset' using errcode = 'P0001';
  end if;

  insert into public.psn_release_assets (
    episode_id, source_system, source_asset_id, cep_job_id, bucket_id, object_path,
    asset_role, mime_type, approval_receipt_id, sha256, status, released_at
  ) values (
    p_episode_id, 'PMF', p_pmf_execution_id::text || ':video', p_cep_job_id,
    'pmf-animation-private', v_storage_path, 'full', 'video/mp4',
    p_certificate_id, v_video_sha, 'released', now()
  ) returning release_asset_id into v_receipt_asset_id;

  update public.psn_episodes set status = 'live' where episode_id = p_episode_id;
  return jsonb_build_object('ok', true, 'state', 'released',
    'episode_id', p_episode_id, 'release_asset_id', v_receipt_asset_id);
end
$function$;

revoke all on function public.psn_release_approved_episode_v1(text,uuid,text,uuid,uuid) from public, anon, authenticated;
grant execute on function public.psn_release_approved_episode_v1(text,uuid,text,uuid,uuid) to service_role;
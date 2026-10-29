create table if not exists public.psn_release_assets (
  release_asset_id uuid primary key default gen_random_uuid(),
  episode_id uuid not null references public.psn_episodes(episode_id) on delete restrict,
  source_system text not null check (source_system in ('PCC','PMF','PVE','PNG','CEP')),
  source_asset_id text not null check (length(btrim(source_asset_id)) between 1 and 200),
  bucket_id text not null default 'pmf-animation-private' check (bucket_id = 'pmf-animation-private'),
  object_path text not null check (
    length(btrim(object_path)) between 1 and 1024
    and object_path !~ '(^|/)\.\.(/|$)'
    and left(object_path, 1) <> '/'
  ),
  asset_role text not null check (asset_role in ('full','preview','poster','captions')),
  mime_type text not null check (mime_type in ('video/mp4','image/jpeg','image/png','text/vtt','application/x-subrip')),
  approval_receipt_id text not null check (length(btrim(approval_receipt_id)) between 1 and 200),
  sha256 text check (sha256 is null or sha256 ~ '^[0-9a-fA-F]{64}$'),
  status text not null default 'pending' check (status in ('pending','released','withdrawn')),
  created_at timestamptz not null default now(),
  released_at timestamptz,
  constraint psn_release_assets_release_time_check
    check ((status = 'released' and released_at is not null) or status <> 'released')
);

create unique index if not exists psn_one_released_full_asset_per_episode
  on public.psn_release_assets (episode_id)
  where asset_role = 'full' and status = 'released';

create index if not exists psn_release_assets_episode_state_idx
  on public.psn_release_assets (episode_id, asset_role, status);

alter table public.psn_release_assets enable row level security;
revoke all on table public.psn_release_assets from public, anon, authenticated;
grant select, insert, update, delete on table public.psn_release_assets to service_role;

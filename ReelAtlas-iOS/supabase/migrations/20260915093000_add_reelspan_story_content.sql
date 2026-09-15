-- ReelSpan story-content schema.
-- The pre-existing public.movies table is the TMDB metadata cache and is
-- intentionally left unchanged.

begin;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create table if not exists public.story_targets (
  target_qid text primary key,
  target_kind text not null,
  name_en text not null,
  name_zh text not null,
  labels jsonb not null default '{}'::jsonb,
  admin1_qid text,
  admin1_name_en text,
  country_qid text not null,
  country_name_en text not null,
  film_count integer not null,
  candidate_count integer not null,
  updated_at timestamptz not null default now(),
  is_deleted boolean not null default false
);

create table if not exists public.story_movies (
  movie_qid text primary key,
  legacy_id bigint not null unique,
  tmdb_id bigint,
  imdb_id text,
  updated_at timestamptz not null default now(),
  is_deleted boolean not null default false
);

create table if not exists public.story_places (
  place_qid text primary key,
  name_en text not null,
  name_zh text not null,
  labels jsonb not null default '{}'::jsonb,
  type_qids jsonb not null default '[]'::jsonb,
  p131_qids jsonb not null default '[]'::jsonb,
  location_qids jsonb not null default '[]'::jsonb,
  country_qids jsonb not null default '[]'::jsonb,
  present_day_qids jsonb not null default '[]'::jsonb,
  replaced_by_qids jsonb not null default '[]'::jsonb,
  followed_by_qids jsonb not null default '[]'::jsonb,
  coordinate text,
  latitude double precision,
  longitude double precision,
  dissolved_date text,
  updated_at timestamptz not null default now(),
  is_deleted boolean not null default false,
  constraint story_places_valid_latitude
    check (latitude is null or latitude between -90 and 90),
  constraint story_places_valid_longitude
    check (longitude is null or longitude between -180 and 180)
);

create table if not exists public.story_movie_target_matches (
  movie_qid text not null references public.story_movies(movie_qid) on delete cascade,
  target_qid text not null references public.story_targets(target_qid) on delete cascade,
  target_kind text not null,
  matched_raw_location_count integer not null,
  matched_raw_place_qids jsonb not null default '[]'::jsonb,
  best_confidence double precision not null,
  updated_at timestamptz not null default now(),
  is_deleted boolean not null default false,
  primary key (movie_qid, target_qid)
);

create table if not exists public.story_movie_locations (
  id bigint primary key,
  source_target_qid text references public.story_targets(target_qid) on delete cascade,
  movie_qid text not null references public.story_movies(movie_qid) on delete cascade,
  is_target_match boolean,
  raw_place_qid text not null references public.story_places(place_qid),
  raw_place_name_en text not null,
  raw_place_name_zh text not null,
  raw_place_labels jsonb not null default '{}'::jsonb,
  historical_capital_qid text references public.story_places(place_qid),
  historical_capital_name_en text,
  modern_place_qid text references public.story_places(place_qid),
  modern_place_name_en text,
  city_qid text references public.story_places(place_qid),
  city_name_en text,
  city_name_zh text,
  admin1_qid text references public.story_places(place_qid),
  admin1_name_en text,
  admin1_name_zh text,
  country_qid text references public.story_places(place_qid),
  country_name_en text,
  country_name_zh text,
  normalization_method text not null,
  normalization_path text,
  confidence double precision not null,
  status text not null,
  notes text,
  updated_at timestamptz not null default now(),
  is_deleted boolean not null default false
);

create table if not exists public.story_movie_periods (
  movie_qid text not null references public.story_movies(movie_qid) on delete cascade,
  period_qid text not null,
  period_name_en text not null,
  period_name_zh text not null,
  period_labels jsonb not null default '{}'::jsonb,
  start_year integer,
  end_year integer,
  interval_method text not null,
  confidence smallint not null default 100
    check (confidence between 0 and 100),
  updated_at timestamptz not null default now(),
  is_deleted boolean not null default false,
  primary key (movie_qid, period_qid),
  constraint story_periods_valid_year_range
    check (start_year is null or end_year is null or end_year >= start_year)
);

create table if not exists public.story_normalization_issues (
  id bigint primary key,
  source_target_qid text references public.story_targets(target_qid) on delete cascade,
  movie_qid text not null references public.story_movies(movie_qid) on delete cascade,
  raw_place_qid text not null references public.story_places(place_qid),
  raw_place_name_en text not null,
  raw_place_name_zh text not null,
  issue_type text not null,
  status text not null,
  confidence double precision not null,
  notes text,
  updated_at timestamptz not null default now(),
  is_deleted boolean not null default false
);

create table if not exists public.dataset_meta (
  dataset_name text primary key,
  version bigint not null default 1,
  source_version text,
  row_counts jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  is_deleted boolean not null default false
);

create index if not exists story_movies_tmdb_id_idx
  on public.story_movies(tmdb_id) where tmdb_id is not null;
create index if not exists story_targets_names_idx
  on public.story_targets(name_en, name_zh);
create index if not exists story_places_names_idx
  on public.story_places(name_en, name_zh);
create index if not exists story_movie_target_matches_target_idx
  on public.story_movie_target_matches(target_qid, movie_qid)
  where is_deleted = false;
create index if not exists story_movie_locations_movie_idx
  on public.story_movie_locations(movie_qid, raw_place_qid)
  where is_deleted = false;
create index if not exists story_movie_locations_raw_place_idx
  on public.story_movie_locations(raw_place_qid, movie_qid)
  where is_deleted = false;
create index if not exists story_movie_locations_updated_at_idx
  on public.story_movie_locations(updated_at);
create index if not exists story_movie_periods_years_idx
  on public.story_movie_periods(start_year, end_year, movie_qid)
  where is_deleted = false;
create index if not exists story_movie_periods_updated_at_idx
  on public.story_movie_periods(updated_at);

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'story_targets', 'story_movies', 'story_places',
    'story_movie_target_matches', 'story_movie_locations',
    'story_movie_periods', 'story_normalization_issues', 'dataset_meta'
  ] loop
    execute format('drop trigger if exists %I_set_updated_at on public.%I', table_name, table_name);
    execute format(
      'create trigger %I_set_updated_at before update on public.%I for each row execute function public.set_updated_at()',
      table_name, table_name
    );
  end loop;
end;
$$;

alter table public.story_targets enable row level security;
alter table public.story_movies enable row level security;
alter table public.story_places enable row level security;
alter table public.story_movie_target_matches enable row level security;
alter table public.story_movie_locations enable row level security;
alter table public.story_movie_periods enable row level security;
alter table public.story_normalization_issues enable row level security;
alter table public.dataset_meta enable row level security;

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'story_targets', 'story_movies', 'story_places',
    'story_movie_target_matches', 'story_movie_locations',
    'story_movie_periods', 'dataset_meta'
  ] loop
    execute format('drop policy if exists public_read on public.%I', table_name);
    execute format(
      'create policy public_read on public.%I for select to anon, authenticated using (is_deleted = false)',
      table_name
    );
    execute format('grant select on public.%I to anon, authenticated', table_name);
    execute format('revoke insert, update, delete on public.%I from anon, authenticated', table_name);
  end loop;
end;
$$;

revoke all on public.story_normalization_issues from anon, authenticated;

insert into public.dataset_meta (dataset_name, version)
values ('reelspan_story_content', 1)
on conflict (dataset_name) do nothing;

commit;

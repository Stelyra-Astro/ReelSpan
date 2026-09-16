-- Proposal-only inbox: existing story tables cannot be changed by anonymous clients.
-- The random per-install token is a bearer credential: only its SHA-256 hash is stored.
CREATE TABLE IF NOT EXISTS public.reelspan_contribution_submissions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 token_hash text NOT NULL,
 submission_kind text NOT NULL CHECK (submission_kind IN ('new','existing')),
 movie_qid text,
 tmdb_id bigint,
 title text,
 imdb_id text,
 time_entries jsonb NOT NULL DEFAULT '[]'::jsonb,
 place_entries jsonb NOT NULL DEFAULT '[]'::jsonb,
 concept_entries jsonb NOT NULL DEFAULT '[]'::jsonb,
 status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','accepted','rejected')),
 moderation_note text,
 submitted_at timestamptz NOT NULL DEFAULT now(),
 reviewed_at timestamptz,
 CHECK (jsonb_typeof(time_entries)='array' AND jsonb_typeof(place_entries)='array' AND jsonb_typeof(concept_entries)='array')
);
CREATE INDEX IF NOT EXISTS reelspan_submissions_queue_idx ON public.reelspan_contribution_submissions(status,submitted_at DESC);
CREATE INDEX IF NOT EXISTS reelspan_submissions_owner_idx ON public.reelspan_contribution_submissions(token_hash,submitted_at DESC);
ALTER TABLE public.reelspan_contribution_submissions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.reelspan_contribution_submissions FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.reelspan_submit_contribution(p_payload jsonb,p_token uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE
 k text; movie text; tmdb bigint; title_value text; imdb text;
 ts jsonb; ps jsonb; cs jsonb; entry jsonb; result uuid; owner_hash text;
BEGIN
 IF p_token IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN RAISE EXCEPTION 'Invalid submission'; END IF;
 owner_hash := encode(extensions.digest(convert_to(p_token::text,'UTF8'),'sha256'),'hex');
 k := p_payload->>'kind'; movie := nullif(trim(coalesce(p_payload->>'movie_qid','')),'');
 title_value := nullif(trim(coalesce(p_payload->>'title','')),'');
 imdb := nullif(trim(coalesce(p_payload->>'imdb_id','')),'');
 ts := coalesce(p_payload->'time_entries','[]'::jsonb);
 ps := coalesce(p_payload->'place_entries','[]'::jsonb);
 cs := coalesce(p_payload->'concept_entries','[]'::jsonb);
 IF k IS NULL OR k NOT IN ('new','existing') OR jsonb_typeof(ts)<>'array' OR jsonb_typeof(ps)<>'array' OR jsonb_typeof(cs)<>'array'
    OR jsonb_array_length(ts)>12 OR jsonb_array_length(ps)>12 OR jsonb_array_length(cs)>12 THEN
   RAISE EXCEPTION 'Invalid contribution fields';
 END IF;
 FOR entry IN SELECT value FROM jsonb_array_elements(ts||ps||cs) LOOP
   IF jsonb_typeof(entry)<>'string' OR length(trim(entry #>> '{}')) NOT BETWEEN 1 AND 160 THEN
     RAISE EXCEPTION 'Time, place and tag entries must be text up to 160 characters';
   END IF;
 END LOOP;
 IF k='existing' THEN
   IF movie IS NULL OR NOT EXISTS (SELECT 1 FROM public.story_movies m WHERE m.movie_qid=movie AND m.is_deleted=false)
      OR jsonb_array_length(ts)+jsonb_array_length(ps)=0 OR jsonb_array_length(cs)>0
      OR title_value IS NOT NULL OR nullif(p_payload->>'tmdb_id','') IS NOT NULL OR imdb IS NOT NULL THEN
     RAISE EXCEPTION 'Existing film submissions accept only time and place corrections';
   END IF;
 ELSE
   IF movie IS NOT NULL OR title_value IS NULL OR length(title_value)>200
      OR jsonb_array_length(ts)=0 OR jsonb_array_length(ps)=0
      OR (imdb IS NOT NULL AND imdb !~ '^tt[0-9]{7,10}$') THEN
     RAISE EXCEPTION 'New films require title, time and place';
   END IF;
   IF nullif(trim(coalesce(p_payload->>'tmdb_id','')),'') IS NOT NULL THEN
     IF p_payload->>'tmdb_id' !~ '^[1-9][0-9]{0,11}$' THEN RAISE EXCEPTION 'Invalid TMDB ID'; END IF;
     tmdb := (p_payload->>'tmdb_id')::bigint;
     IF EXISTS (SELECT 1 FROM public.story_movies m WHERE m.tmdb_id=tmdb AND m.is_deleted=false) THEN
       RAISE EXCEPTION 'Film already in ReelSpan; submit a correction instead';
     END IF;
   END IF;
 END IF;
 IF (SELECT count(*) FROM public.reelspan_contribution_submissions
      WHERE token_hash=owner_hash AND submitted_at>now()-interval '1 hour')>=5
    OR (SELECT count(*) FROM public.reelspan_contribution_submissions
      WHERE token_hash=owner_hash AND submitted_at>now()-interval '1 day')>=15 THEN
   RAISE EXCEPTION 'Contribution limit reached; please try again later';
 END IF;
 INSERT INTO public.reelspan_contribution_submissions(token_hash,submission_kind,movie_qid,tmdb_id,title,imdb_id,time_entries,place_entries,concept_entries)
 VALUES(owner_hash,k,movie,tmdb,title_value,imdb,ts,ps,cs) RETURNING id INTO result;
 RETURN result;
END;
$fn$;
REVOKE ALL ON FUNCTION public.reelspan_submit_contribution(jsonb,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reelspan_submit_contribution(jsonb,uuid) TO anon,authenticated;

CREATE OR REPLACE FUNCTION public.reelspan_my_contributions(p_token uuid)
RETURNS TABLE(id uuid,submission_kind text,movie_qid text,tmdb_id bigint,title text,
              time_entries jsonb,place_entries jsonb,concept_entries jsonb,status text,
              moderation_note text,submitted_at timestamptz,reviewed_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $fn$
 SELECT s.id,s.submission_kind,s.movie_qid,s.tmdb_id,s.title,s.time_entries,s.place_entries,
        s.concept_entries,s.status,s.moderation_note,s.submitted_at,s.reviewed_at
 FROM public.reelspan_contribution_submissions s
 WHERE p_token IS NOT NULL
   AND s.token_hash=encode(extensions.digest(convert_to(p_token::text,'UTF8'),'sha256'),'hex')
 ORDER BY s.submitted_at DESC LIMIT 200;
$fn$;
REVOKE ALL ON FUNCTION public.reelspan_my_contributions(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reelspan_my_contributions(uuid) TO anon,authenticated;

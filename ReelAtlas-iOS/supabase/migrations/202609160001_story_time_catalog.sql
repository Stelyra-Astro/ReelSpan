-- Executed after validating the 2026-09-16 pre-change snapshot.
CREATE TABLE public.story_time_concepts (
  concept_qid text PRIMARY KEY,
  category text NOT NULL CHECK (category IN ('calendar','person','event','regime','era')),
  name_en text NOT NULL,
  name_zh text NOT NULL DEFAULT '',
  labels jsonb NOT NULL DEFAULT '{}'::jsonb,
  start_year integer,
  end_year integer,
  source text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  is_deleted boolean NOT NULL DEFAULT false,
  CONSTRAINT valid_period CHECK (start_year IS NULL OR end_year IS NULL OR start_year <= end_year)
);
ALTER TABLE public.story_time_concepts ENABLE ROW LEVEL SECURITY;
CREATE POLICY public_read ON public.story_time_concepts FOR SELECT TO anon, authenticated USING (is_deleted=false);
GRANT SELECT ON public.story_time_concepts TO anon, authenticated;
CREATE INDEX story_time_concepts_category_idx ON public.story_time_concepts(category,name_en);

-- Correct only unambiguous English century/decade Wikidata labels, preserving the original period QIDs.
UPDATE public.story_movie_periods
SET start_year = ((substring(period_name_en from '^([0-9]+)')::integer - 1) * 100 + 1),
    end_year = (substring(period_name_en from '^([0-9]+)')::integer * 100),
    interval_method = 'normalized_century', updated_at = now()
WHERE is_deleted=false AND period_name_en ~ '^[0-9]+(st|nd|rd|th) century$'
  AND substring(period_name_en from '^([0-9]+)')::integer BETWEEN 1 AND 30;
UPDATE public.story_movie_periods
SET start_year = substring(period_name_en from '^([0-9]{3,4})')::integer,
    end_year = substring(period_name_en from '^([0-9]{3,4})')::integer + 9,
    interval_method = 'normalized_decade', updated_at = now()
WHERE is_deleted=false AND period_name_en ~ '^[0-9]{3,4}s$';

INSERT INTO public.story_time_concepts(concept_qid,category,name_en,name_zh,labels,start_year,end_year,source)
SELECT period_qid,
  CASE WHEN max(period_name_en) ~ '^([0-9]+(st|nd|rd|th) century|[0-9]{3,4}s|[0-9]{1,4})$' THEN 'calendar'
       WHEN max(period_name_en) ~* '(empire|dynasty|kingdom|republic|caliphate|monarchy|sultanate|shogunate|occupation)' THEN 'regime'
       WHEN max(period_name_en) ~* '(war|revolution|battle|election|assassination|coronation|invasion|uprising)' THEN 'event'
       ELSE 'era' END,
  (array_agg(period_name_en ORDER BY period_name_en))[1],
  (array_agg(period_name_zh ORDER BY period_name_zh))[1],
  coalesce((array_agg(period_labels ORDER BY period_name_en))[1], '{}'::jsonb),
  min(start_year),max(end_year),'story_movie_periods'
FROM public.story_movie_periods WHERE is_deleted=false AND period_qid IS NOT NULL
GROUP BY period_qid;

-- Manchukuo is a historical time concept, not a modern Where polygon.
INSERT INTO public.story_time_concepts(concept_qid,category,name_en,name_zh,labels,start_year,end_year,source)
SELECT place_qid,'regime',name_en,name_zh,labels,1932,1945,'story_places/Wikidata-Q30623'
FROM public.story_places WHERE place_qid='Q30623' AND is_deleted=false
ON CONFLICT (concept_qid) DO NOTHING;

CREATE TABLE public.story_movie_concept_tags (
  movie_qid text NOT NULL REFERENCES public.story_movies(movie_qid) ON DELETE CASCADE,
  concept_qid text NOT NULL REFERENCES public.story_time_concepts(concept_qid) ON DELETE CASCADE,
  relation_kind text NOT NULL CHECK (relation_kind IN ('depicts','mentions','setting')),
  evidence_source text NOT NULL,
  confidence smallint CHECK (confidence BETWEEN 0 AND 100),
  updated_at timestamptz NOT NULL DEFAULT now(),
  is_deleted boolean NOT NULL DEFAULT false,
  PRIMARY KEY(movie_qid,concept_qid,relation_kind,evidence_source)
);
ALTER TABLE public.story_movie_concept_tags ENABLE ROW LEVEL SECURITY;
CREATE POLICY public_read ON public.story_movie_concept_tags FOR SELECT TO anon, authenticated USING (is_deleted=false);
GRANT SELECT ON public.story_movie_concept_tags TO anon, authenticated;
CREATE INDEX story_movie_concept_tags_concept_idx ON public.story_movie_concept_tags(concept_qid,movie_qid) WHERE is_deleted=false;
INSERT INTO public.story_movie_concept_tags(movie_qid,concept_qid,relation_kind,evidence_source,confidence)
SELECT DISTINCT movie_qid,'Q30623','setting','story_movie_locations',90
FROM public.story_movie_locations WHERE raw_place_qid='Q30623' AND is_deleted=false
ON CONFLICT DO NOTHING;

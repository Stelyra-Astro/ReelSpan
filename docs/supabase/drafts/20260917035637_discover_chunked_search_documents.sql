-- Hold source writes only for consistent backfill; reads remain available.
LOCK TABLE public.movies,public.reelatlas_search_index IN SHARE ROW EXCLUSIVE MODE;
-- All searchable fields are split into inline text blocks. 79-character overlap
-- preserves every allowed (<=80 character) literal match, including block boundaries.
CREATE TABLE reelspan_private.search_chunks (
 owner_kind text NOT NULL CHECK(owner_kind IN ('m','s')),owner_id text NOT NULL,
 field_name text NOT NULL,score integer NOT NULL,chunk_no integer NOT NULL,
 is_full_field boolean NOT NULL,chunk_text text NOT NULL,
 PRIMARY KEY(owner_kind,owner_id,field_name,chunk_no)
);
ALTER TABLE reelspan_private.search_chunks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON reelspan_private.search_chunks FROM PUBLIC,anon,authenticated;
CREATE FUNCTION reelspan_private.literal_pair_terms(input text) RETURNS text[]
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE SET search_path='' AS $terms$
 SELECT coalesce(array_agg(DISTINCT term),'{}'::text[])
 FROM generate_series(1,char_length(input)) n
 CROSS JOIN LATERAL (VALUES (substr(input,n,1)),(substr(input,n,2))) t(term);
$terms$;
REVOKE ALL ON FUNCTION reelspan_private.literal_pair_terms(text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION reelspan_private.refresh_search_chunks() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $trigger$
DECLARE kind text; doc_id text;
BEGIN
 kind:=CASE WHEN TG_TABLE_NAME='movies' THEN 'm' ELSE 's' END;
 IF TG_OP<>'INSERT' THEN
   IF kind='m' THEN doc_id:=OLD.tmdb_id::text; ELSE doc_id:=OLD.movie_qid; END IF;
   DELETE FROM reelspan_private.search_chunks WHERE owner_kind=kind AND owner_id=doc_id;
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 IF kind='m' THEN
   doc_id:=NEW.tmdb_id::text;
   INSERT INTO reelspan_private.search_chunks
   SELECT kind,doc_id,f.name,f.score,n,n=1 AND char_length(f.value)<=384,substr(f.value,n,384)
   FROM (VALUES
   ('title',110,lower(coalesce(NEW.title,''))),
   ('original_title',110,lower(coalesce(NEW.original_title,''))),
   ('genres',65,lower(coalesce(NEW.genres::text,''))),
   ('director',65,lower(coalesce(NEW.director::text,''))),
   ('cast_members',65,lower(coalesce(NEW.cast_members::text,''))),
   ('overview',45,lower(coalesce(NEW.overview,'')))) f(name,score,value)
   CROSS JOIN LATERAL generate_series(1,char_length(f.value),305) n;
 ELSE
   doc_id:=NEW.movie_qid;
   INSERT INTO reelspan_private.search_chunks
   SELECT kind,doc_id,f.name,f.score,n,n=1 AND char_length(f.value)<=384,substr(f.value,n,384)
   FROM (VALUES ('period',100,coalesce(NEW.period_search,'')),('place',95,coalesce(NEW.place_search,''))) f(name,score,value)
   CROSS JOIN LATERAL generate_series(1,char_length(f.value),305) n;
 END IF;
 RETURN NEW;
END;
$trigger$;
REVOKE ALL ON FUNCTION reelspan_private.refresh_search_chunks() FROM PUBLIC,anon,authenticated;
INSERT INTO reelspan_private.search_chunks
 SELECT 'm',md.tmdb_id::text,f.name,f.score,n,n=1 AND char_length(f.value)<=384,substr(f.value,n,384)
 FROM reelspan_private.movie_search md CROSS JOIN LATERAL (VALUES
 ('title',110,md.title),('original_title',110,md.original_title),('genres',65,md.genres),
 ('director',65,md.director),('cast_members',65,md.cast_members),('overview',45,md.overview)) f(name,score,value)
 CROSS JOIN LATERAL generate_series(1,char_length(f.value),305) n;
INSERT INTO reelspan_private.search_chunks
 SELECT 's',idx.movie_qid,f.name,f.score,n,n=1 AND char_length(f.value)<=384,substr(f.value,n,384)
 FROM public.reelatlas_search_index idx CROSS JOIN LATERAL (VALUES
 ('period',100,coalesce(idx.period_search,'')),('place',95,coalesce(idx.place_search,''))) f(name,score,value)
 CROSS JOIN LATERAL generate_series(1,char_length(f.value),305) n;
CREATE TRIGGER reelspan_movie_chunks_refresh AFTER INSERT OR UPDATE OF tmdb_id,title,original_title,genres,director,cast_members,overview OR DELETE
 ON public.movies FOR EACH ROW EXECUTE FUNCTION reelspan_private.refresh_search_chunks();
CREATE TRIGGER reelspan_story_chunks_refresh AFTER INSERT OR UPDATE OF movie_qid,period_search,place_search OR DELETE
 ON public.reelatlas_search_index FOR EACH ROW EXECUTE FUNCTION reelspan_private.refresh_search_chunks();

ANALYZE reelspan_private.search_chunks;

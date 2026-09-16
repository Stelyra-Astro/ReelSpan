-- Accurate per-owner totals without exposing anyone else's submissions; history lists remain capped for performance.
CREATE OR REPLACE FUNCTION public.reelspan_my_contribution_counts(p_token uuid)
RETURNS TABLE(status text,total bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $fn$
  SELECT s.status,count(*)::bigint
  FROM public.reelspan_contribution_submissions s
  WHERE p_token IS NOT NULL AND s.token_hash=encode(extensions.digest(convert_to(p_token::text,'UTF8'),'sha256'),'hex')
  GROUP BY s.status;
$fn$;
REVOKE ALL ON FUNCTION public.reelspan_my_contribution_counts(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reelspan_my_contribution_counts(uuid) TO anon,authenticated;

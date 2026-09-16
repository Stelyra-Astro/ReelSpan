-- Correct temporal *cataloguing* only. Do not infer a film depicts a person from a shared time interval.
-- Astronomical year numbering: 1 BCE = 0, 100 BCE = -99, 1300 BCE = -1299.
WITH parsed AS (
 SELECT concept_qid, (substring(name_en from '^([0-9]+)'))::integer AS century
 FROM public.story_time_concepts
 WHERE is_deleted=false AND name_en ~* '^[0-9]+(st|nd|rd|th) century (BC|BCE)$'
)
UPDATE public.story_time_concepts t
SET category='calendar', start_year=1 - 100 * p.century, end_year=100 - 100 * p.century,updated_at=now()
FROM parsed p WHERE t.concept_qid=p.concept_qid AND p.century BETWEEN 1 AND 40;

-- Source movie-year rows must be corrected too, or filtering/grouping still sees one-year centuries.
WITH parsed AS (
 SELECT period_qid, (substring(max(period_name_en) from '^([0-9]+)'))::integer AS century
 FROM public.story_movie_periods
 WHERE is_deleted=false AND period_name_en ~* '^[0-9]+(st|nd|rd|th) century (BC|BCE)$'
 GROUP BY period_qid
)
UPDATE public.story_movie_periods p
SET start_year=1 - 100 * parsed.century,
    end_year=100 - 100 * parsed.century,
    interval_method='normalized_bce_century',updated_at=now()
FROM parsed WHERE p.period_qid=parsed.period_qid AND p.is_deleted=false
 AND parsed.century BETWEEN 1 AND 40;

-- An extracted date is not a historical era or movement. Retain the QID and its source evidence.
UPDATE public.story_time_concepts
SET category='calendar',updated_at=now()
WHERE is_deleted=false AND category IN ('era','event','regime') AND (
 name_en ~* '^[0-9]{1,5} (BC|BCE|AD|CE)$'
 OR name_en ~* '^[0-9]+(st|nd|rd|th) century( (BC|BCE))?$'
 OR name_en ~* '^[0-9]{3,4}s$'
 OR name_en ~* '^(January|February|March|April|May|June|July|August|September|October|November|December) ([0-9]{1,2},? )?[0-9]{3,4}$'
);

-- Additional well-defined Wikidata biography identities, human lifetimes not reigns/careers.
-- BCE span uses astronomical year numbering. No automatic movie-person tags are created.
INSERT INTO public.story_time_concepts
 (concept_qid,category,name_en,name_zh,labels,start_year,end_year,source)
VALUES
 ('Q33772','person','Du Fu','杜甫','{"en":"Du Fu","zh":"杜甫","alias_en":"Tu Fu"}'::jsonb,712,770,'Wikidata Q33772'),
 ('Q692','person','William Shakespeare','威廉·莎士比亚','{"en":"William Shakespeare","zh":"威廉·莎士比亚","alias_en":"Shakespeare"}'::jsonb,1564,1616,'Wikidata Q692'),
 ('Q517','person','Napoleon Bonaparte','拿破仑·波拿巴','{"en":"Napoleon Bonaparte","zh":"拿破仑·波拿巴","alias_en":"Napoleon"}'::jsonb,1769,1821,'Wikidata Q517'),
 ('Q635','person','Cleopatra VII','克利奥帕特拉七世','{"en":"Cleopatra VII","zh":"克利奥帕特拉七世","alias_en":"Cleopatra"}'::jsonb,-68,-29,'Wikidata Q635'),
 ('Q9439','person','Queen Victoria','维多利亚女王','{"en":"Queen Victoria","zh":"维多利亚女王","alias_en":"Victoria"}'::jsonb,1819,1901,'Wikidata Q9439'),
 ('Q937','person','Albert Einstein','阿尔伯特·爱因斯坦','{"en":"Albert Einstein","zh":"阿尔伯特·爱因斯坦","alias_en":"Einstein"}'::jsonb,1879,1955,'Wikidata Q937'),
 ('Q91','person','Abraham Lincoln','亚伯拉罕·林肯','{"en":"Abraham Lincoln","zh":"亚伯拉罕·林肯","alias_en":"Lincoln"}'::jsonb,1809,1865,'Wikidata Q91'),
 ('Q762','person','Leonardo da Vinci','列奥纳多·达·芬奇','{"en":"Leonardo da Vinci","zh":"列奥纳多·达·芬奇","alias_en":"Da Vinci"}'::jsonb,1452,1519,'Wikidata Q762'),
 ('Q7186','person','Marie Curie','玛丽·居里','{"en":"Marie Curie","zh":"玛丽·居里","alias_en":"Madame Curie"}'::jsonb,1867,1934,'Wikidata Q7186'),
 ('Q8016','person','Winston Churchill','温斯顿·丘吉尔','{"en":"Winston Churchill","zh":"温斯顿·丘吉尔","alias_en":"Churchill"}'::jsonb,1874,1965,'Wikidata Q8016'),
 ('Q255','person','Ludwig van Beethoven','路德维希·范·贝多芬','{"en":"Ludwig van Beethoven","zh":"路德维希·范·贝多芬","alias_en":"Beethoven"}'::jsonb,1770,1827,'Wikidata Q255'),
 ('Q132537','person','J. Robert Oppenheimer','罗伯特·奥本海默','{"en":"J. Robert Oppenheimer","zh":"罗伯特·奥本海默","alias_en":"Oppenheimer"}'::jsonb,1904,1967,'Wikidata Q132537'),
 ('Q352','person','Adolf Hitler','阿道夫·希特勒','{"en":"Adolf Hitler","zh":"阿道夫·希特勒","alias_en":"Hitler"}'::jsonb,1889,1945,'Wikidata Q352'),
 ('Q5582','person','Vincent van Gogh','文森特·梵高','{"en":"Vincent van Gogh","zh":"文森特·梵高","alias_en":"Van Gogh"}'::jsonb,1853,1890,'Wikidata Q5582'),
 ('Q4583','person','Anne Frank','安妮·弗兰克','{"en":"Anne Frank","zh":"安妮·弗兰克","alias_en":"Anne Frank"}'::jsonb,1929,1945,'Wikidata Q4583')
ON CONFLICT (concept_qid) DO NOTHING;

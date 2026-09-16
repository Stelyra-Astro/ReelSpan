-- Explicitly sourced seed examples. This is NOT a full people/era knowledge base.
-- Living people's upper bound is the data-release year and must be refreshed on future releases.
INSERT INTO public.story_time_concepts
(concept_qid,category,name_en,name_zh,labels,start_year,end_year,source)
VALUES
('Q7071','person','Li Bai','李白','{"en":"Li Bai","zh":"李白","alias_en":"Li Po"}'::jsonb,701,762,'Wikidata Q7071'),
('Q8027','person','Martin Luther King Jr.','马丁·路德·金','{"en":"Martin Luther King Jr.","zh":"马丁·路德·金","alias_en":"MLK"}'::jsonb,1929,1968,'Wikidata Q8027'),
('Q43274','person','Charles III','查理三世','{"en":"Charles III","zh":"查理三世","alias_en":"King Charles III"}'::jsonb,1948,2026,'Wikidata Q43274; living person, current-year endpoint, refresh annually'),
('Q8733','regime','Qing dynasty','清朝','{"en":"Qing dynasty","zh":"清朝"}'::jsonb,1644,1912,'Wikidata Q8733; conventional Chinese dynastic period'),
('Q205662','regime','Tokugawa shogunate','德川幕府','{"en":"Tokugawa shogunate","zh":"德川幕府","ja":"徳川幕府"}'::jsonb,1603,1868,'Wikidata Q205662; conventional period'),
('Q48249','event','Falklands War','马岛战争','{"en":"Falklands War","zh":"马岛战争","es":"Guerra de las Malvinas"}'::jsonb,1982,1982,'Wikidata Q48249'),
('Q6148003','era','Rule of Wen and Jing','文景之治','{"en":"Rule of Wen and Jing","zh":"文景之治"}'::jsonb,-180,-141,'Wikidata Q6148003')
ON CONFLICT (concept_qid) DO NOTHING;

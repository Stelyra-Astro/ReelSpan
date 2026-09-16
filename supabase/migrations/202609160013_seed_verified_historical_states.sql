-- Historically bounded concepts, independently usable as When only (never inferred modern Where geography).
INSERT INTO public.story_time_concepts
(concept_qid,category,name_en,name_zh,labels,start_year,end_year,source)
VALUES
('Q12560','regime','Ottoman Empire','奥斯曼帝国','{"en":"Ottoman Empire","zh":"奥斯曼帝国","alias_en":"Ottoman State"}'::jsonb,1299,1922,'Wikidata Q12560; conventional boundaries'),
('Q15180','regime','Soviet Union','苏联','{"en":"Soviet Union","zh":"苏联","alias_en":"USSR"}'::jsonb,1922,1991,'Wikidata Q15180'),
('Q4948','regime','Republic of Venice','威尼斯共和国','{"en":"Republic of Venice","zh":"威尼斯共和国","alias_en":"Venetian Republic"}'::jsonb,697,1797,'Wikidata Q4948; conventional boundaries')
ON CONFLICT (concept_qid) DO NOTHING;

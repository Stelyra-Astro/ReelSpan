"""Build a static, reviewed country→continent name lookup for the Where cache.
Source: bundled countryinfo country metadata (region/subregion); no online requests.
This is only applied to Wikidata entities with type Q6256 (country).
"""
import glob,json,os
import countryinfo
from pathlib import Path
root=Path(os.path.dirname(countryinfo.__file__))/'data'
name_to_continent={}
for path in glob.glob(str(root/'*.json')):
    record=json.loads(Path(path).read_text())
    continent=record.get('region','')
    if continent=='Americas':
        continent='South America' if record.get('subregion')=='South America' else 'North America'
    if continent not in ('Africa','Asia','Europe','North America','South America','Oceania'):continue
    for name in [record.get('name',''),*record.get('altSpellings',[])]:
        if name and len(name)>3 and not (len(name)<5 and name.isupper()):
            name_to_continent.setdefault(name.casefold(),continent)
# Explicit label variants from the Wikidata country catalog; do not add empires or imaginary places.
name_to_continent.update({
 'ivory coast':'Africa','côte d’ivoire':'Africa','the gambia':'Africa','the bahamas':'North America',
 'czech republic':'Europe','timor-leste':'Asia','north korea':'Asia','south korea':'Asia',
 'north macedonia':'Europe','democratic republic of the congo':'Africa','republic of the congo':'Africa',
 'federated states of micronesia':'Oceania','palestine':'Asia','taiwan':'Asia',
 'kosovo':'Europe','cape verde':'Africa','vatican city':'Europe','turkey':'Asia',
 'russia':'Europe','georgia':'Asia','armenia':'Asia','azerbaijan':'Asia','kazakhstan':'Asia',
 'cyprus':'Asia','fiji':'Oceania','united states':'North America',
 'united kingdom':'Europe','people\'s republic of china':'Asia',
})
header='-- CountryInfo bundled region/subregion data; match Wikidata country entities by English label.\n'
values=',\n'.join('    (\'%s\',\'%s\')'%(n.replace("'","''"),c) for n,c in sorted(name_to_continent.items()))
Path('supabase/migrations/202609160008_country_seed_values.sql').write_text(header+'INSERT INTO public.reelspan_country_continents(country_qid,continent)\nSELECT p.place_qid,v.continent FROM (VALUES\n'+values+'\n) AS v(name,continent)\nJOIN public.story_places p ON lower(p.name_en)=v.name AND p.is_deleted=false AND p.type_qids ? \'Q6256\'\nON CONFLICT (country_qid) DO UPDATE SET continent=excluded.continent;\n')
print('Generated',len(name_to_continent),'country name mappings')

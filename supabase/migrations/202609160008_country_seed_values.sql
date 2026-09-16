-- Manually reviewed labels for modern countries represented in ReelSpan.
-- Border-spanning countries are assigned one navigation continent for the current UI.
WITH seed(continent, names) AS (VALUES
('Africa',$$Algeria|Angola|Benin|Botswana|Burkina Faso|Burundi|Cameroon|Cape Verde|Central African Republic|Chad|Democratic Republic of the Congo|Djibouti|Egypt|Equatorial Guinea|Eritrea|Ethiopia|Gabon|The Gambia|Ghana|Guinea|Guinea-Bissau|Ivory Coast|Kenya|Lesotho|Liberia|Libya|Madagascar|Malawi|Mali|Mauritania|Mauritius|Morocco|Mozambique|Namibia|Niger|Nigeria|Republic of the Congo|Rwanda|São Tomé and Príncipe|Senegal|Seychelles|Sierra Leone|Somalia|South Africa|South Sudan|Sudan|Tanzania|Togo|Tunisia|Uganda|Zambia|Zimbabwe$$),
('Asia',$$Afghanistan|Armenia|Azerbaijan|Bahrain|Bangladesh|Bhutan|Cambodia|People's Republic of China|Georgia|India|Indonesia|Iran|Iraq|Israel|Japan|Jordan|Kazakhstan|Kuwait|Kyrgyzstan|Laos|Lebanon|Malaysia|Maldives|Mongolia|Myanmar|Nepal|North Korea|Oman|Pakistan|Palestine|Philippines|Qatar|Saudi Arabia|Singapore|South Korea|Sri Lanka|Syria|Taiwan|Tajikistan|Thailand|Timor-Leste|Turkey|Turkmenistan|United Arab Emirates|Uzbekistan|Vietnam|Yemen$$),
('Europe',$$Albania|Andorra|Austria|Belarus|Belgium|Bosnia and Herzegovina|Bulgaria|Croatia|Cyprus|Czech Republic|Denmark|Estonia|Finland|France|Germany|Greece|Hungary|Iceland|Ireland|Italy|Kosovo|Latvia|Lithuania|Luxembourg|Malta|Moldova|Monaco|Montenegro|Netherlands|North Macedonia|Norway|Poland|Portugal|Romania|Russia|Serbia|Slovakia|Slovenia|Spain|Sweden|Switzerland|Ukraine|United Kingdom|Vatican City$$),
('North America',$$Barbados|Belize|Canada|Costa Rica|Cuba|Curaçao|Dominica|Dominican Republic|El Salvador|Greenland|Grenada|Guatemala|Haiti|Honduras|Jamaica|Mexico|Nicaragua|Panama|The Bahamas|Trinidad and Tobago|United States$$),
('South America',$$Argentina|Bolivia|Brazil|Chile|Colombia|Ecuador|Guyana|Paraguay|Peru|Suriname|Uruguay|Venezuela$$),
('Oceania',$$Australia|Fiji|Federated States of Micronesia|Kiribati|Marshall Islands|New Zealand|Papua New Guinea|Samoa|Solomon Islands|Tonga|Tuvalu|Vanuatu$$)
), candidates AS (SELECT s.continent,unnest(string_to_array(s.names,'|')) AS name FROM seed s)
INSERT INTO public.reelspan_country_continents(country_qid,continent)
SELECT p.place_qid,c.continent FROM candidates c
JOIN public.story_places p ON lower(p.name_en)=lower(c.name) AND p.is_deleted=false AND p.type_qids ? 'Q6256'
ON CONFLICT(country_qid) DO UPDATE SET continent=excluded.continent;

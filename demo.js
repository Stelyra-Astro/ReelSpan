/** ReelSpan's GitHub Pages preview. Illustrative in-memory data; NO live requests or submissions. */
(() => {
  'use strict';
  const root = document.getElementById('reelspan-demo');
  if (!root) return;
  const search = document.getElementById('demo-search');
  const result = document.getElementById('demo-results');
  const overlay = document.getElementById('demo-overlay');
  const group = document.getElementById('demo-group');
  const places = [
    {continent:'Asia',country:'China',city:'Beijing'}, {continent:'Asia',country:'China',city:'Shanghai'},
    {continent:'Asia',country:'Japan',city:'Kyoto'}, {continent:'Europe',country:'France',city:'Paris'},
    {continent:'Europe',country:'Italy',city:'Rome'}, {continent:'Europe',country:'Poland',city:'Warsaw'},
    {continent:'Africa',country:'Morocco',city:'Casablanca'}, {continent:'North America',country:'United States',city:'New York'},
    {continent:'North America',country:'United States',city:'Washington, D.C.'},
  ];
  const films = [
    {id:1,title:'The Last Emperor',release:1987,years:[1908,1967],country:'China',city:'Beijing',continent:'Asia',genre:'History',person:'Puyi',tags:['Qing dynasty','Manchukuo'],director:'Bernardo Bertolucci',cast:'John Lone',tone:'#625a62'},
    {id:2,title:'Midnight in Paris',release:2011,years:[1920,2010],country:'France',city:'Paris',continent:'Europe',genre:'Comedy',person:'',tags:['1920s'],director:'Woody Allen',cast:'Owen Wilson',tone:'#2b5d70'},
    {id:3,title:'Casablanca',release:1942,years:[1941,1942],country:'Morocco',city:'Casablanca',continent:'Africa',genre:'Drama',person:'',tags:['World War II'],director:'Michael Curtiz',cast:'Humphrey Bogart',tone:'#6b4b38'},
    {id:4,title:'Gladiator',release:2000,years:[180,180],country:'Italy',city:'Rome',continent:'Europe',genre:'Action',person:'Marcus Aurelius',tags:['Roman Empire'],director:'Ridley Scott',cast:'Russell Crowe',tone:'#655947'},
    {id:5,title:'Hidden Figures',release:2016,years:[1961,1969],country:'United States',city:'Washington, D.C.',continent:'North America',genre:'Drama',person:'Katherine Johnson',tags:['Space Race'],director:'Theodore Melfi',cast:'Taraji P. Henson',tone:'#534c76'},
    {id:6,title:'Amélie',release:2001,years:[1997,1997],country:'France',city:'Paris',continent:'Europe',genre:'Romance',person:'',tags:['1990s'],director:'Jean-Pierre Jeunet',cast:'Audrey Tautou',tone:'#733b4a'},
    {id:7,title:'Seven Samurai',release:1954,years:[1586,1586],country:'Japan',city:'Kyoto',continent:'Asia',genre:'Action',person:'',tags:['Sengoku period'],director:'Akira Kurosawa',cast:'Toshiro Mifune',tone:'#414d52'},
    {id:8,title:'The Pianist',release:2002,years:[1939,1945],country:'Poland',city:'Warsaw',continent:'Europe',genre:'Drama',person:'',tags:['World War II'],director:'Roman Polanski',cast:'Adrien Brody',tone:'#333f51'},
    {id:9,title:'A Poet in the Tang Dynasty',release:0,years:[712,759],country:'China',city:'Shanghai',continent:'Asia',genre:'History',person:'Du Fu',tags:['Tang dynasty','Li Bai'],director:'Illustrative demo',cast:'',tone:'#3e675e',fictional:true},
  ];
  // These are mock contribution exercises, not actual missing entries in the live film catalog.
  const contributionTasks = {
    'missing-place': {title:'Demo film · missing story place',known:'Known story time: 1940–1945'},
    'missing-time': {title:'Demo film · missing story time',known:'Known story place: Paris, France'},
    'missing-both': {title:'Demo film · missing both',known:'Time and place are both unmarked'}
  };
  const eras = {
    'People':[['Li Bai',701,762],['Du Fu',712,770],['Martin Luther King Jr.',1929,1968]],
    'Historical events':[['World War II',1939,1945],['Space Race',1957,1975]],
    'Dynasties & states':[['Tang dynasty',618,907],['Manchukuo',1932,1945],['Roman Empire',-26,395],['Qing dynasty',1644,1912]],
    'Eras & movements':[['Renaissance',1300,1600],['Victorian era',1837,1901],['Sengoku period',1467,1615]]
  };
  const continents = ['Africa','Asia','Europe','North America','South America','Oceania'];
  const state = {view:'list',query:'',where:null,when:null,genre:null,sort:'nearby',group:'all',favorites:new Set(),favoritesOnly:false,panel:null,level:0,continent:null,country:null,category:null,century:null,detail:null,contribPage:null,contribTask:null,history:[]};
  const esc = text => String(text ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const century = year => year > 0 ? Math.floor((year - 1)/100)+1 : -(Math.floor(-year/100)+1);
  const centuryText = c => `${Math.abs(c)}${Math.abs(c)%100>=11 && Math.abs(c)%100<=13?'th':({1:'st',2:'nd',3:'rd'}[Math.abs(c)%10]||'th')} century${c<0?' BCE':''}`;
  const centuries = film => {let set=new Set(); for(let year=century(film.years[0]);year<=century(film.years[1]);year++) if(year) set.add(year);return [...set];};
  const inWhen = f => !state.when || f.years[0]<=state.when[2] && f.years[1]>=state.when[1];
  function filtered() {
    const term=state.query.trim().toLowerCase();
    return films.filter(f => (!state.where || f.country===state.where || f.city===state.where) &&
      (!state.genre || f.genre===state.genre) && inWhen(f) && (!state.favoritesOnly || state.favorites.has(f.id)) &&
      (!term || [f.title,f.country,f.city,f.continent,f.genre,f.person,f.director,f.cast,...f.tags,...f.years.map(String)].join(' ').toLowerCase().includes(term)))
      .sort((a,b) => {
        if(term){const score=f=> f.title.toLowerCase().includes(term)?3:f.tags.some(x=>x.toLowerCase().includes(term))?2:1; const diff=score(b)-score(a);if(diff)return diff;}
        if(state.sort==='title')return a.title.localeCompare(b.title);
        if(state.sort==='newest')return b.release-a.release;
        if(state.sort==='oldest')return a.release-b.release;
        return Number(b.country==='United States')-Number(a.country==='United States') || a.title.localeCompare(b.title);
      });
  }
  function filmRow(f){return `<article class="demo-film"><div class="demo-poster" style="--tone:${f.tone}">${esc(f.title)}</div><div class="demo-film-info"><button type="button" class="demo-film-name" data-film="${f.id}" style="border:0;background:none;text-align:left;padding:0">${esc(f.title)}</button><div class="demo-film-sub">${f.release||'Demo'} · ${esc(f.genre)}${f.fictional?' · Fictional demo film':''}</div><div class="demo-film-tags"><span>⌖ ${esc(f.city)}, ${esc(f.country)}</span><span>◷ ${esc(f.years.join('–'))}</span></div><div class="demo-film-actions"><button type="button" data-film="${f.id}">Details →</button><button type="button" data-correct="${f.id}">✎ Correct</button><button type="button" data-favorite="${f.id}" aria-label="${state.favorites.has(f.id)?'Remove favorite':'Add favorite'}">${state.favorites.has(f.id)?'♥':'♡'} Favorite</button></div></div></article>`;}
  function renderResults(){
    const found=filtered();document.getElementById('demo-count').textContent=`${found.length} demo films · ${state.where||'All places'}${state.when?' · '+state.when[0]:''}`;
    group.value=state.group;
    document.querySelectorAll('[data-view]').forEach(b=>b.classList.toggle('active',b.dataset.view===state.view));
    for(const type of ['where','when','genre','sort']){let b=document.getElementById(`demo-${type}-button`);b.classList.toggle('selected',!!(type==='where'?state.where:type==='when'?state.when:type==='genre'?state.genre:state.sort!=='nearby'));b.textContent=type==='where'?(state.where||'Where')+' ⌄':type==='when'?(state.when?.[0]||'When')+' ⌄':type==='genre'?(state.genre||'Genre')+' ⌄':state.sort==='nearby'?'Sort ⌄':state.sort+' ⌄';}
    if(state.view==='map'){
      const pins=[...new Set(found.map(f=>f.country))].slice(0,6);
      result.innerHTML=`<div class="demo-map">${pins.map((country,i)=>`<button type="button" class="demo-pin" data-map-country="${esc(country)}" style="left:${12+(i*29)%72}%;top:${17+(i*19)%60}%" aria-label="Films set in ${esc(country)}">⌖</button>`).join('')}<div class="demo-map-note">Illustrative map · Select a pin to filter ${found.length} film${found.length===1?'':'s'} by country.</div></div>`;
      return;
    }
    if(!found.length){result.innerHTML='<div class="demo-empty">No matching demo films.<br/>Try Reset or another filter.</div>';return;}
    if(state.group==='all'){result.innerHTML=found.map(filmRow).join('');return;}
    if(state.group==='place'){
      const continentsGrouped=new Map();
      for(const film of found){
        if(!continentsGrouped.has(film.continent)) continentsGrouped.set(film.continent,new Map());
        const countries=continentsGrouped.get(film.continent);
        if(!countries.has(film.country)) countries.set(film.country,new Map());
        countries.get(film.country).set(film.id,film);
      }
      result.innerHTML=[...continentsGrouped].sort(([a],[b])=>a.localeCompare(b)).map(([continent,countries])=>
        `<div class="demo-group-label demo-continent-label">◎ ${esc(continent)}</div>`+
        [...countries].sort(([a],[b])=>a.localeCompare(b)).map(([country,filmMap])=>
          `<div class="demo-group-label demo-country-label">⌖ ${esc(country)} · ${filmMap.size}</div>${[...filmMap.values()].map(filmRow).join('')}`).join('')).join('');return;
    }
    const groups=new Map();for(const film of found)for(const c of centuries(film)){if(!groups.has(c))groups.set(c,[]);groups.get(c).push(film);}
    result.innerHTML=[...groups].sort(([a],[b])=>b-a).map(([c,arr])=>`<div class="demo-group-label">◷ ${centuryText(c)} · ${arr.length}</div>${arr.map(filmRow).join('')}`).join('');
  }
  function head(title,close='Close'){return `<div class="demo-sheet-head"><span>${esc(title)}</span><button type="button" data-close aria-label="${esc(close)}">×</button></div>`;}
  function option(label,attrs='',trailing='›'){return `<button type="button" class="demo-option" ${attrs}><span>${esc(label)}</span><small>${esc(trailing)}</small></button>`;}
  function renderPanel(){
    if(!state.panel){overlay.hidden=true;overlay.innerHTML='';return;}
    overlay.hidden=false;
    let body='';const panel=state.panel;
    if(panel==='where'){
      body=head('Where');body+=option('Anywhere · All places','data-select-where=""','✓');
      if(state.continent){body+=`<button type="button" class="demo-back" data-back-where>← Back</button>`;}
      if(!state.continent){body+=continents.filter(c=>places.some(p=>p.continent===c)).map(c=>option(c,`data-continent="${esc(c)}"`)).join('');}
      else if(!state.country){body+=[...new Set(places.filter(p=>p.continent===state.continent).map(p=>p.country))].sort().map(c=>option(c,`data-country="${esc(c)}"`)).join('');}
      else {body+=option('All of '+state.country,`data-select-where="${esc(state.country)}"`,'Select');body+=[...new Set(places.filter(p=>p.country===state.country).map(p=>p.city))].sort().map(c=>option(c,`data-select-where="${esc(c)}"`,'Select')).join('');}
    } else if(panel==='when'){
      body=head('When')+option('Any story time','data-select-when=""','✓');
      if(state.category)body+='<button type="button" class="demo-back" data-back-when>← Back</button>';
      if(!state.category){body+=['Years & decades','People','Historical events','Dynasties & states','Eras & movements'].map(cat=>option(cat,`data-category="${esc(cat)}"`)).join('');}
      else if(state.category==='Years & decades' && state.century===null){let c=[...new Set(films.flatMap(centuries))].sort((a,b)=>b-a);body+=c.map(n=>option(centuryText(n),`data-century="${n}"`)).join('');}
      else if(state.category==='Years & decades'){
        const n=state.century;const from=n>0?(n-1)*100+1:n*100+1,to=n>0?n*100:(n+1)*100;
        body+=option('All of '+centuryText(n),`data-when-years="${from}:${to}"`,'Select');
        const decades=[...new Set(films.flatMap(f=>f.years).filter(y=>y>=from&&y<=to).map(y=>Math.floor(y/10)*10))];
        body+=decades.sort((a,b)=>a-b).map(d=>option(`${d}s`,`data-when-years="${d}:${d+9}"`,'Select')).join('');
      } else body+=eras[state.category].map(([label,from,to])=>option(label,`data-when-years="${from}:${to}" data-when-label="${esc(label)}"`,'Select')).join('');
    } else if(panel==='genre')body=head('Genre')+option('All genres','data-genre=""','✓')+[...new Set(films.map(f=>f.genre))].sort().map(g=>option(g,`data-genre="${esc(g)}"`)).join('');
    else if(panel==='sort')body=head('Sort')+[['nearby','Nearby story settings first'],['newest','Newest releases'],['oldest','Oldest releases'],['title','Title A–Z']].map(([s,l])=>option(l,`data-sort="${s}"`)).join('');
    else if(panel==='detail'){
      const f=films.find(f=>f.id===state.detail);body=head(f.title)+`<p class="demo-note">Illustrative film details · ${esc(f.years.join('–'))}</p><p><strong>Story location</strong><br>${esc(f.city)}, ${esc(f.country)}</p><p><strong>Story time</strong><br>${esc(f.years.join('–'))}</p><p><strong>Director / cast</strong><br>${esc(f.director)} · ${esc(f.cast)}</p><p><strong>Historical tags</strong><br>${esc(f.tags.join(' · '))}</p>${option('Suggest a time or place correction',`data-correct="${f.id}"`,'✎')}`;
    } else if(panel==='contribute'){
      overlay.innerHTML=`<div class="demo-page" role="dialog" aria-modal="true" aria-label="Contribution preview"><div class="demo-sheet-head"><span>Contribute to ReelSpan</span><button type="button" data-close aria-label="Close">×</button></div>${contributeBody()}</div>`;return;
    }
    overlay.innerHTML=`<section class="demo-sheet" role="dialog" aria-modal="true" aria-label="${esc(panel)} filter">${body}</section>`;
  }
  function contributeBody(){
    if(state.contribPage==='new'||state.contribPage==='correct'){
      const f=state.contribTask||films.find(f=>f.id===state.detail);const isNew=state.contribPage==='new';
      return `<button type="button" class="demo-back" data-contrib-back>← Contribution home</button><form id="demo-contribution-form"><p class="demo-note">Demo form only. No data is transmitted or saved after this page is closed.</p>${isNew?'<label>Film title *<input name="title" required maxlength="160" placeholder="Film name"></label><label>TMDB ID · optional<input name="tmdb" inputmode="numeric"></label><label>IMDb ID · optional<input name="imdb" placeholder="tt…"></label>':`<p><strong>${esc(f.title)}</strong><br>${esc(f.known||'Existing films: suggest time or place changes only.')}</p>`}<label>Story time ${isNew?'*':''}<textarea name="time" ${isNew?'required':''} placeholder="One period, year or range per line (historical or modern)"></textarea></label><label>Story place ${isNew?'*':''}<textarea name="place" ${isNew?'required':''} placeholder="One historical or modern location per line"></textarea></label>${isNew?'<label>Historical tags · optional<textarea name="tags" placeholder="One tag per line"></textarea></label>':''}<button class="demo-submit" type="submit">Simulate submission</button></form>`;
    }
    if(state.contribPage==='history')return `<button type="button" class="demo-back" data-contrib-back>← Contribution home</button><h3>My contributions</h3>${state.history.length?state.history.map(h=>`<div class="demo-history"><strong>${esc(h.title)}</strong><br>${esc(h.time||'—')} · ${esc(h.place||'—')}<br><small>Status: In review · demo only</small></div>`).join(''):'<p class="demo-note">No demo contributions yet.</p>'}`;
    const count=state.history.length;
    return `<p class="demo-note">Suggest missing or corrected story time and place. Real submissions are reviewed in the iOS app.</p><div class="demo-counter"><span><b>${count}</b>Total</span><span><b>${count}</b>In review</span><span><b>0</b>Accepted</span><span><b>0</b>Rejected</span></div>${option('My contribution history','data-contrib-page="history"')}${option('Add a film missing from ReelSpan','data-contrib-page="new"')}${option('Has time, missing story place','data-contrib-page="missing-place"')}${option('Has place, missing story time','data-contrib-page="missing-time"')}${option('Missing both story time and place','data-contrib-page="missing-both"')}<p class="demo-note">These are illustrative contribution paths; no submission is sent to Supabase.</p>`;
  }
  function render(){renderResults();renderPanel();}
  root.addEventListener('click',e=>{
    const b=e.target.closest('button');if(!b)return;
    if(b.hasAttribute('data-close')){state.panel=null;state.contribPage=null;render();return;}
    if(b.dataset.view){state.view=b.dataset.view;renderResults();return;}
    if(b.dataset.panel){state.panel=b.dataset.panel;state.continent=null;state.country=null;state.category=null;state.century=null;renderPanel();return;}
    if(b.dataset.action==='reset'){state.query='';search.value='';state.where=null;state.when=null;state.genre=null;state.sort='nearby';state.favoritesOnly=false;state.group='all';state.view='list';render();return;}
    if(b.dataset.action==='favorites'){state.favoritesOnly=!state.favoritesOnly;renderResults();return;}
    if(b.dataset.action==='contribute'){state.panel='contribute';state.contribPage=null;state.detail=null;state.contribTask=null;renderPanel();return;}
    if(b.dataset.continent){state.continent=b.dataset.continent;renderPanel();return;}
    if(b.dataset.country){state.country=b.dataset.country;renderPanel();return;}
    if(b.hasAttribute('data-back-where')){state.country?state.country=null:state.continent=null;renderPanel();return;}
    if(b.hasAttribute('data-select-where')){state.where=b.dataset.selectWhere||null;state.panel=null;render();return;}
    if(b.dataset.mapCountry){state.where=b.dataset.mapCountry;state.view='list';render();return;}
    if(b.dataset.category){state.category=b.dataset.category;state.century=null;renderPanel();return;}
    if(b.hasAttribute('data-century')){state.century=Number(b.dataset.century);renderPanel();return;}
    if(b.hasAttribute('data-back-when')){state.century!==null?state.century=null:state.category=null;renderPanel();return;}
    if(b.hasAttribute('data-select-when')){state.when=null;state.panel=null;render();return;}
    if(b.dataset.whenYears){const [from,to]=b.dataset.whenYears.split(':').map(Number);state.when=[b.dataset.whenLabel||`${from}–${to}`,from,to];state.panel=null;render();return;}
    if(b.hasAttribute('data-genre')){state.genre=b.dataset.genre||null;state.panel=null;render();return;}
    if(b.dataset.sort){state.sort=b.dataset.sort;state.panel=null;render();return;}
    if(b.dataset.film){state.detail=Number(b.dataset.film);state.panel='detail';renderPanel();return;}
    if(b.dataset.favorite){const id=Number(b.dataset.favorite);state.favorites.has(id)?state.favorites.delete(id):state.favorites.add(id);renderResults();return;}
    if(b.dataset.correct){state.detail=Number(b.dataset.correct);state.contribTask=null;state.panel='contribute';state.contribPage='correct';renderPanel();return;}
    if(b.dataset.contribPage){const isMissing=b.dataset.contribPage.startsWith('missing-');state.contribTask=isMissing?contributionTasks[b.dataset.contribPage]:null;state.contribPage=isMissing?'correct':b.dataset.contribPage;renderPanel();return;}
    if(b.hasAttribute('data-contrib-back')){state.contribPage=null;renderPanel();}
  });
  search.addEventListener('input',e=>{state.query=e.target.value;renderResults();});
  group.addEventListener('change',e=>{state.group=e.target.value;renderResults();});
  root.addEventListener('submit',e=>{
    if(e.target.id!=='demo-contribution-form')return;e.preventDefault();
    const fields=new FormData(e.target);const isNew=state.contribPage==='new';const title=isNew?String(fields.get('title')||'').trim():(state.contribTask||films.find(f=>f.id===state.detail)).title;
    const time=String(fields.get('time')||'').trim(),place=String(fields.get('place')||'').trim();
    if(!title||(isNew&&(!time||!place))||(!isNew&&!time&&!place))return;
    state.history.unshift({title,time,place});state.contribPage='history';renderPanel();
  });
  render();
})();

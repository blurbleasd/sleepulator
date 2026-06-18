import React, { useState } from 'react';
import { useAppContext } from '../context/AppContext.jsx';
import { NATIVE_MEDIA_VOLUME_LOCK } from '../utils/core.js';
import LucideIcon from './LucideIcon.jsx';
import EpisodeList from './EpisodeList.jsx';
import NowPlayingBar from './NowPlayingBar.jsx';
import PodcastSettings from './PodcastSettings.jsx';
import PodcastEffects from './PodcastEffects.jsx';
import ImportOpmlButton from './ImportOpmlButton.jsx';

// Full-screen podcast experience with a clear hierarchy:
//   library  -> your saved podcasts + the Up-Next queue + add a podcast
//   podcast  -> one feed's episodes (clean list; controls live in settings)
//   queue    -> the Up-Next list, reorderable
//   settings -> playback options + feed proxy / Sleep Safe / backup / effects
// Replaces the old single-screen "tabs + every control at once" mess.
export default function PodcastScreen({ show, onClose }) {
  const {
    c_head, c_sub, c_dim, c_bord, c_inner, c_text,
    subs, setSubs, playlist, episodes, loading, feedErr,
    loadFeed, rssUrl, setRssUrl, subName,
    playEp, addEpisodesToPlaylist, saveCurrentPlaylist, setShowPlaylistLibrary,
    podVol, setPodVol, autoPlay, setAutoPlay, shuffle, setShuffle,
    preloadNext, setPreloadNext, podSpeed, setPodSpeed,
  } = useAppContext() || {};

  const [view, setView] = useState('library');     // library | podcast | queue | settings
  const [feed, setFeed] = useState(null);          // the sub being viewed
  const [adding, setAdding] = useState(false);

  if (!show) return null;

  const goBack = () => (view === 'library' ? onClose() : setView('library'));
  const openPodcast = (sub) => { setFeed(sub); if (sub?.url) loadFeed(sub.url); setView('podcast'); };
  const removeFeed = (sub) => {
    if (typeof window !== 'undefined' && !window.confirm(`Remove "${sub.name}" from your podcasts?`)) return;
    setSubs(prev => prev.filter(x => x.url !== sub.url));
  };

  const titles = { library: 'Podcasts', podcast: feed?.name || subName || 'Podcast', queue: 'Up next', settings: 'Podcast settings' };

  const headerBtn = {}; // Replaced by class
  const pill = (active=false) => ({ padding:'.55rem .9rem',borderRadius:'.7rem',border:`1px solid ${c_bord}`,fontSize:'.78rem',fontWeight:700,cursor:'pointer',background:active?'var(--c-accent-strong)':'rgba(230,178,119,.14)',color:active?'var(--c-bg)':'#e6b277' });

  return (
    <div className="overlay" style={{zIndex:150,paddingTop:'var(--top-clearance)',overflowY:'auto'}}>
      <div style={{maxWidth:500,margin:'0 auto',paddingLeft:'1rem',paddingRight:'1rem'}} className="pad-bottom">

        {/* Header */}
        <div className="screen-header">
          <button onClick={goBack} className="" aria-label="Back" className="btn-icon header-btn">
            <LucideIcon name={view==='library' ? 'X' : 'ChevronLeft'} size={20}/>
          </button>
          <span className="screen-title">{titles[view]}</span>
          {view==='library' && (
            <button onClick={()=>setView('settings')} aria-label="Settings" className="btn-icon header-btn">
              <LucideIcon name="Settings2" size={18}/>
            </button>
          )}
        </div>

        <NowPlayingBar onOpen={()=>setView('queue')} />

        {/* ── Library ── */}
        {view==='library' && (
          <>
            <button onClick={()=>setView('queue')} className="card"
              style={{display:'flex',alignItems:'center',justifyContent:'space-between',width:'100%',textAlign:'left',cursor:'pointer',border:`1px solid ${playlist.length?'rgba(230,178,119,.25)':'var(--c-border)'}`,marginBottom:'1.25rem'}}>
              <span style={{display:'flex',alignItems:'center',gap:'.6rem'}}>
                <LucideIcon name="BookMarked" size={20} color="#e6b277"/>
                <span>
                  <span style={{display:'block',fontSize:'1rem',fontWeight:700,color:c_head}}>Up next</span>
                  <span style={{display:'block',fontSize:'.72rem',color:c_sub}}>{playlist.length ? `${playlist.length} episode${playlist.length===1?'':'s'} queued` : 'Your sleep queue is empty'}</span>
                </span>
              </span>
              <span style={{fontSize:'1.3rem',lineHeight:1,color:c_dim}}>›</span>
            </button>

            <div className="section-label" style={{marginBottom:'.6rem'}}>Your podcasts</div>
            {subs.length===0 ? (
              <div style={{fontSize:'.8rem',color:c_sub,lineHeight:1.6,padding:'.25rem 0 1rem'}}>No podcasts yet. Add one below, or import your subscriptions from Overcast.</div>
            ) : (
              <div style={{display:'flex',flexDirection:'column',gap:'.6rem',marginBottom:'1rem'}}>
                {subs.map((s,i)=>(
                  <div key={i} className="card" className="panel-row">
                    <button onClick={()=>openPodcast(s)}
                      style={{flex:1,minWidth:0,display:'flex',alignItems:'center',gap:'.75rem',background:'transparent',border:'none',padding:0,textAlign:'left',cursor:'pointer',color:'inherit'}}>
                      <span className="sub-icon">
                        <LucideIcon name="Rss" size={20}/>
                      </span>
                      <span style={{flex:1,minWidth:0}}>
                        <span style={{display:'block',fontSize:'.9rem',color:c_head,overflow:'hidden',textOverflow:'ellipsis',whiteSpace:'nowrap'}}>{s.name}</span>
                        <span style={{display:'block',fontSize:'.7rem',color:c_sub}}>{s.episodeCount ? `${s.episodeCount} episodes` : 'Tap to load'}</span>
                      </span>
                      <span style={{fontSize:'1.2rem',lineHeight:1,color:c_dim}}>›</span>
                    </button>
                    <button onClick={()=>removeFeed(s)} aria-label={`Remove ${s.name}`} className="btn-icon"
                      style={{width:40,height:40,minWidth:40,minHeight:40,background:'transparent',color:c_dim,flexShrink:0}}>
                      <LucideIcon name="Trash2" size={16}/>
                    </button>
                  </div>
                ))}
              </div>
            )}

            {adding ? (
              <div className="card" style={{padding:'.875rem',marginBottom:'1rem'}}>
                <div style={{display:'flex',gap:'.5rem'}}>
                  <input type="url" value={rssUrl} onChange={e=>setRssUrl(e.target.value)} placeholder="Paste podcast feed URL…"
                    style={{flex:1,background:c_inner,border:`1px solid ${c_bord}`,borderRadius:'.625rem',padding:'.5rem .75rem',color:c_text,fontSize:'14px'}}/>
                  <button onClick={()=>{ if(rssUrl.trim()){ loadFeed(); setAdding(false); setFeed(null); setView('podcast'); } }} disabled={!rssUrl.trim()||loading}
                    style={{padding:'.5rem 1rem',borderRadius:'.625rem',background:rssUrl.trim()?'var(--c-accent-strong)':'#4a3a1e',color:rssUrl.trim()?'var(--c-bg)':'#fff',border:'none',fontWeight:700,cursor:rssUrl.trim()?'pointer':'default',whiteSpace:'nowrap'}}>
                    {loading?'…':'Load'}
                  </button>
                </div>
                <div style={{borderTop:`1px solid ${c_bord}`,margin:'.75rem 0 0',paddingTop:'.75rem'}}>
                  <ImportOpmlButton />
                </div>
              </div>
            ) : (
              <button onClick={()=>setAdding(true)}
                style={{width:'100%',display:'flex',alignItems:'center',justifyContent:'center',gap:'.5rem',padding:'.85rem',borderRadius:'.85rem',background:'transparent',border:`1px dashed rgba(230,178,119,.4)`,color:'#e6b277',fontSize:'.85rem',fontWeight:700,cursor:'pointer',marginBottom:'1rem'}}>
                <LucideIcon name="Plus" size={18}/> Add a podcast
              </button>
            )}
          </>
        )}

        {/* ── Podcast detail (one feed's episodes) ── */}
        {view==='podcast' && (
          <>
            {feedErr && <p style={{color:'#f87171',fontSize:'.8rem',marginBottom:'.75rem'}}>{feedErr}</p>}
            {loading && !episodes.length ? (
              <div style={{textAlign:'center',padding:'2.5rem',color:c_sub,fontSize:'.85rem'}}>Loading episodes…</div>
            ) : (
              <>
                {episodes.length>0 && (
                  <div style={{display:'flex',gap:'.5rem',marginBottom:'.875rem',flexWrap:'wrap'}}>
                    <button onClick={()=>playEp(episodes[0],'feed')} style={pill(true)}>Play latest</button>
                    <button onClick={()=>addEpisodesToPlaylist(episodes)} style={pill()}>Add all to queue</button>
                  </div>
                )}
                <EpisodeList list={episodes} mode="feed" emptyText="No episodes found for this feed." />
              </>
            )}
          </>
        )}

        {/* ── Queue (Up next) ── */}
        {view==='queue' && (
          <>
            {playlist.length>0 && (
              <div style={{display:'flex',gap:'.5rem',marginBottom:'.875rem',flexWrap:'wrap'}}>
                <button onClick={()=>playEp(playlist[0],'playlist')} style={pill(true)}>Play queue</button>
                <button onClick={saveCurrentPlaylist} style={pill()}>Save</button>
                <button onClick={()=>setShowPlaylistLibrary(true)} style={{...pill(),background:'transparent',color:c_sub}}>Saved queues</button>
              </div>
            )}
            <EpisodeList list={playlist} mode="queue" emptyText={"Your queue is empty.\nOpen a podcast and tap + to add episodes."} />
          </>
        )}

        {/* ── Settings ── */}
        {view==='settings' && (
          <>
            <div className="card-inner" style={{marginBottom:'.875rem',display:'flex',flexDirection:'column',gap:'.875rem'}}>
              <div className="section-label" style={{margin:0}}>Playback</div>
              {!NATIVE_MEDIA_VOLUME_LOCK && (
                <div style={{display:'flex',alignItems:'center',gap:'.75rem'}}>
                  <LucideIcon name="Volume2" size={16} color="#e6b277"/>
                  <span style={{fontSize:'.72rem',fontWeight:700,color:c_sub,whiteSpace:'nowrap'}}>Volume</span>
                  <input type="range" min="0" max="1" step=".01" value={podVol} className="purple" onChange={e=>setPodVol(+e.target.value)} style={{flex:1}}/>
                </div>
              )}
              <div style={{display:'flex',gap:'1.25rem',alignItems:'center',flexWrap:'wrap'}}>
                <label style={{display:'flex',alignItems:'center',gap:'.375rem',fontSize:'.72rem',color:c_sub,cursor:'pointer'}}>
                  <input type="checkbox" checked={autoPlay} onChange={e=>setAutoPlay(e.target.checked)}/> Auto-play
                </label>
                <label style={{display:'flex',alignItems:'center',gap:'.375rem',fontSize:'.72rem',color:c_sub,cursor:'pointer'}}>
                  <input type="checkbox" checked={shuffle} onChange={e=>setShuffle(e.target.checked)}/> Shuffle
                </label>
                <label style={{display:'flex',alignItems:'center',gap:'.375rem',fontSize:'.72rem',color:c_sub,cursor:'pointer'}} title="Download the next episode ahead of time (uses data)">
                  <input type="checkbox" checked={preloadNext} onChange={e=>setPreloadNext(e.target.checked)}/> Preload next
                </label>
              </div>
              <div>
                <div className="section-label">Playback speed</div>
                <div style={{display:'flex',gap:'.375rem'}}>
                  {[1,.85,.75].map(s=>(
                    <button key={s} onClick={()=>setPodSpeed(s)} className={`speed-chip${podSpeed===s?' on':''}`}>{s===1?'Normal':`${s}×`}</button>
                  ))}
                </div>
              </div>
            </div>
            <PodcastSettings />
            <PodcastEffects />
          </>
        )}

      </div>
    </div>
  );
}

import React from 'react';
import { useAppContext } from './context/AppContext.jsx';
import { fmtTime } from './utils/core.js';
import LucideIcon from './components/LucideIcon.jsx';
import EpisodeBrowser from './components/EpisodeBrowser.jsx';
import SleepTimer from './components/SleepTimer.jsx';
import MixerPanel from './components/MixerPanel.jsx';
import Header from './components/Header.jsx';
import AmbientBinaural from './components/AmbientBinaural.jsx';
import PodcastSettings from './components/PodcastSettings.jsx';
import NowPlayingBar from './components/NowPlayingBar.jsx';
import ImportOpmlButton from './components/ImportOpmlButton.jsx';
import PodcastEffects from './components/PodcastEffects.jsx';

export default function AppLayout() {
  const {
    bm,
    setBm,
    muted,
    setMuted,
    breathMode,
    setBreathMode,
    masterVol,
    setMasterVol,
    ambientOn,
    setAmbientOn,
    ambientVol,
    setAmbientVol,
    noiseType,
    setNoiseType,
    ambientBypass,
    setAmbientBypass,
    binOn,
    setBinOn,
    binVol,
    setBinVol,
    binPreset,
    setBinPreset,
    binBypass,
    setBinBypass,
    timerMins,
    setTimerMins,
    timerActive,
    setTimerActive,
    timeLeft,
    setTimeLeft,
    episodes,
    setEpisodes,
    playlist,
    setPlaylist,
    activeTab,
    setActiveTab,
    playingSrc,
    setPlayingSrc,
    curEp,
    setCurEp,
    podPlaying,
    setPodPlaying,
    podVol,
    setPodVol,
    podSpeed,
    setPodSpeed,
    autoPlay,
    setAutoPlay,
    shuffle,
    setShuffle,
    rssUrl,
    setRssUrl,
    loading,
    setLoading,
    feedErr,
    setFeedErr,
    feedNote,
    setFeedNote,
    feedProxyUrl,
    setFeedProxyUrl,
    audioProxyUrl,
    setAudioProxyUrl,
    sleepSafeAudio,
    setSleepSafeAudio,
    feedDebug,
    setFeedDebug,
    showFeedDebug,
    setShowFeedDebug,
    forceAudioTeardown,
    getAudioDiagnostics,
    subs,
    setSubs,
    showSubs,
    setShowSubs,
    subName,
    setSubName,
    savedPlaylists,
    setSavedPlaylists,
    eqOn, setEqOn,
    compOn, setCompOn,
    panOn, setPanOn,
    mixPresets,
    setMixPresets,
    saveCurrentMix,
    loadMix,
    deleteMix,
    cachedEpisodes,
    downloadProgress,
    downloadEpisode,
    deleteEpisode,
    showPlaylistLibrary,
    setShowPlaylistLibrary,
    playlistName,
    setPlaylistName,
    expandedEp,
    setExpandedEp,
    epFilter,
    setEpFilter,
    podProgress,
    setPodProgress,
    timerEndRef,
    timerTickRef,
    v,
    leg,
    stored,
    dragSrcRef,
    normalizedAudioProxyUrl,
    sleepSafeConfigured,
    ambientAudio,
    binAudio,
    podAudio,
    playNextRef,
    progInterval,
    wakeLock,
    iosAdvanceLock,
    podStateRef,
    iosPwaAudio,
    ambientManagedUrl,
    binManagedUrl,
    ambientSourceKey,
    binSourceKey,
    ambientLoopMeta,
    binLoopMeta,
    ambientWrapLock,
    binWrapLock,
    setNativeAudioLevel,
    swapManagedLoopSource,
    currentSrc,
    previousManaged,
    wasPlaying,
    previousTime,
    resumeAt,
    restore,
    syncPodVolume,
    syncAmbientVolume,
    audio,
    gain,
    preservePosition,
    allowSourceRebuild,
    baseSourceKey,
    managed,
    sourceKey,
    nextUrl,
    syncBinVolume,
    setPlaybackAudioSession,
    syncMediaPositionState,
    resumeSoundscapeAudio,
    pauseSoundscapeAudio,
    show,
    hide,
    anyPlaying,
    handler,
    devs,
    hasHP,
    btn,
    icon,
    iconData,
    children,
    paths,
    aStr,
    label,
    sub,
    m,
    list,
    idx,
    ensureAmbientAudio,
    ensureBinAudio,
    startAmbient,
    stopAmbient,
    toggleAmbient,
    startBin,
    stopBin,
    toggleBin,
    upsertFeedSub,
    normalizedUrl,
    index,
    existing,
    entry,
    next,
    addEpisodesToPlaylist,
    additions,
    existingIds,
    uniqueAdditions,
    getDefaultPlaylistName,
    fromLibrary,
    fromFeed,
    base,
    saveCurrentPlaylist,
    name,
    existingIndex,
    nextEntry,
    loadSavedPlaylist,
    savedEpisodes,
    loadFeed,
    requestedUrl,
    configuredProxyUrl,
    normalized,
    currentUrl,
    resolvedFeedUrl,
    lastError,
    debugState,
    hop,
    sources,
    raw,
    sourceLabel,
    attempt,
    response,
    responseText,
    embeddedFeed,
    attemptError,
    parsedFeed,
    nextEpisodes,
    existingSub,
    nextFeedName,
    message,
    addToPlaylist,
    removeFromPlaylist,
    saveSub,
    url,
    ensurePodAudio,
    state,
    remaining,
    playEp,
    iosHandoff,
    useSleepSafeAudio,
    playbackUrl,
    activeAudioUrl,
    sourceChangedForEpisode,
    prog,
    onMeta,
    maxTime,
    nextIdx,
    nextEp,
    p,
    skipPod,
    tickTimer,
    rem,
    r,
    toggleTimer,
    bumpTimer,
    fmt,
    BC,
    bc,
    c_text,
    c_sub,
    c_dim,
    c_head,
    c_card,
    c_bord,
    c_inner,
  } = useAppContext() || {}; // fallback for safety

  const [showPodcasts, setShowPodcasts] = React.useState(false);

  return (
    <div className="app-container" style={{minHeight:'100dvh', color:c_text}}>
      <div className="mesh-bg" />

      {/* ── Breathing overlay ── */}
      {breathMode && bc && (
        <div className="overlay" style={{background:bm?'#000':'rgba(3,7,18,.97)',alignItems:'center',justifyContent:'center'}}>
          <button onClick={()=>setBreathMode(null)}
            style={{position:'absolute',top:'var(--top-clearance)',right:'1.25rem',background:'#1e293b',border:'none',borderRadius:'50%',width:44,height:44,display:'flex',alignItems:'center',justifyContent:'center',cursor:'pointer',color:'#b39b80'}}>
            <LucideIcon name="X" size={20}/>
          </button>
          <div style={{display:'flex',gap:'.75rem',marginBottom:'2rem'}}>
            {['478','box'].map(m=>(
              <button key={m} onClick={()=>setBreathMode(m)}
                style={{padding:'.5rem 1.25rem',borderRadius:'9999px',border:'none',fontWeight:700,fontSize:'.8rem',cursor:'pointer',
                  background:breathMode===m?(bm?'#2a2114':'#b8813a'):(bm?'#111':'#1e293b'),
                  color:breathMode===m?'#fff':(bm?'#8a7860':'#b39b80')}}>
                {m==='478'?'4-7-8':'Box 4-4-4-4'}
              </button>
            ))}
          </div>
          <h2 style={{fontSize:'1.2rem',fontWeight:800,letterSpacing:'.08em',color:bm?'#b39b80':bc.col,marginBottom:'.25rem'}}>{bc.label}</h2>
          <p style={{fontSize:'.85rem',color:c_sub,marginBottom:'5rem',textAlign:'center',padding:'0 2rem'}}>{bc.sub}</p>
          <div style={{position:'relative',width:220,height:220,display:'flex',alignItems:'center',justifyContent:'center'}}>
            <div style={{position:'absolute',inset:0,borderRadius:'50%',background:bc.col,opacity:.1}}/>
            <div className={bc.cls} style={{width:'100%',height:'100%',borderRadius:'50%',background:bc.col,opacity:.85,boxShadow:bm?'none':`0 0 60px ${bc.col}40`}}/>
          </div>
        </div>
      )}

      {/* ── Saved feeds overlay ── */}
      {showSubs && (
        <div className="overlay" style={{background:bm?'#000':'#15110b',paddingTop:'var(--top-clearance)'}}>
          <div style={{display:'flex',alignItems:'center',justifyContent:'space-between',padding:'1.25rem'}}>
            <h2 style={{fontSize:'1.1rem',fontWeight:800,color:c_head,margin:0}}>Saved Feeds</h2>
            <button onClick={()=>setShowSubs(false)}
              style={{background:'#1e293b',border:'none',borderRadius:'50%',width:44,height:44,display:'flex',alignItems:'center',justifyContent:'center',cursor:'pointer',color:'#b39b80'}}>
              <LucideIcon name="X" size={18}/>
            </button>
          </div>

          <div className="card" style={{margin:'0 1rem 1rem',padding:'1rem'}}>
            <p style={{fontSize:'.7rem',color:c_sub,margin:'0 0 .5rem'}}>Loaded feeds are saved automatically. Use this to rename the current feed if you want.</p>
            <div style={{display:'flex',gap:'.5rem'}}>
              <input type="text" value={subName} onChange={e=>setSubName(e.target.value)} placeholder={rssUrl.trim() ? "Current feed name…" : "Load a feed to rename it…"}
                style={{flex:1,background:c_inner,border:`1px solid ${c_bord}`,borderRadius:'.5rem',padding:'.5rem .75rem',color:c_text,fontSize:'14px'}}/>
              <button onClick={saveSub} disabled={!rssUrl.trim()}
                style={{padding:'.5rem 1rem',borderRadius:'.5rem',background:rssUrl.trim()?'#b8813a':'#4a3a1e',color:'#fff',border:'none',fontWeight:700,cursor:rssUrl.trim()?'pointer':'default',whiteSpace:'nowrap',opacity:rssUrl.trim()?1:.55}}>
                Update
              </button>
            </div>
            <div style={{borderTop:`1px solid ${c_bord}`,margin:'.875rem 0 0',paddingTop:'.875rem'}}>
              <p style={{fontSize:'.7rem',color:c_sub,margin:'0 0 .5rem'}}>Bring in your subscriptions from Overcast or another app.</p>
              <ImportOpmlButton />
            </div>
          </div>

          <div className="scroll-y" style={{flex:1,padding:'0 1rem',display:'flex',flexDirection:'column',gap:'.5rem'}}>
            {subs.length===0 && <p style={{textAlign:'center',padding:'2rem',color:c_sub,fontSize:'.85rem'}}>No saved feeds yet.</p>}
            {subs.map((s,i)=>(
              <div key={i} className="card" style={{padding:'1rem',display:'flex',alignItems:'center',gap:'.75rem'}}>
                <div style={{flex:1,minWidth:0}}>
                  <p style={{margin:0,fontSize:'.85rem',fontWeight:600,color:c_head,overflow:'hidden',textOverflow:'ellipsis',whiteSpace:'nowrap'}}>{s.name}</p>
                  <p style={{margin:0,fontSize:'.7rem',color:c_sub,overflow:'hidden',textOverflow:'ellipsis',whiteSpace:'nowrap'}}>{s.url}</p>
                  {!!s.episodeCount && (
                    <p style={{margin:'.25rem 0 0',fontSize:'.65rem',color:c_dim}}>{s.episodeCount} episode{s.episodeCount===1?'':'s'} cached from last load</p>
                  )}
                </div>
                <button onClick={()=>{ setSubName(s.name || ''); loadFeed(s.url, { closeLibrary: true }); }}
                  style={{padding:'.4rem .875rem',borderRadius:'.5rem',background:'rgba(230,178,119,.2)',color:'#e6b277',border:'none',fontSize:'.75rem',fontWeight:700,cursor:'pointer',whiteSpace:'nowrap'}}>
                  Load
                </button>
                <button onClick={()=>{ setSubName(s.name || ''); loadFeed(s.url, { autoplay: true, closeLibrary: true }); }}
                  style={{padding:'.4rem .875rem',borderRadius:'.5rem',background:'#b8813a',color:'#fff',border:'none',fontSize:'.75rem',fontWeight:700,cursor:'pointer',whiteSpace:'nowrap'}}>
                  Play
                </button>
                <button onClick={()=>setSubs(prev=>prev.filter(x=>x.url!==s.url))}
                  style={{background:'none',border:'none',cursor:'pointer',color:'#6b5d48',padding:'.25rem',display:'flex',alignItems:'center'}}
                  onMouseOver={e=>e.currentTarget.style.color='#f87171'}
                  onMouseOut={e=>e.currentTarget.style.color='#6b5d48'}>
                  <LucideIcon name="Trash2" size={16}/>
                </button>
              </div>
            ))}
          </div>
        </div>
      )}

      {showPlaylistLibrary && (
        <div className="overlay" style={{background:bm?'#000':'#15110b',paddingTop:'var(--top-clearance)'}}>
          <div style={{display:'flex',alignItems:'center',justifyContent:'space-between',padding:'1.25rem'}}>
            <h2 style={{fontSize:'1.1rem',fontWeight:800,color:c_head,margin:0}}>Saved Playlists</h2>
            <button onClick={()=>setShowPlaylistLibrary(false)}
              style={{background:'#1e293b',border:'none',borderRadius:'50%',width:44,height:44,display:'flex',alignItems:'center',justifyContent:'center',cursor:'pointer',color:'#b39b80'}}>
              <LucideIcon name="X" size={18}/>
            </button>
          </div>

          <div className="card" style={{margin:'0 1rem 1rem',padding:'1rem'}}>
            <p style={{fontSize:'.7rem',color:c_sub,margin:'0 0 .5rem'}}>Save the current queue under a reusable name.</p>
            <div style={{display:'flex',gap:'.5rem'}}>
              <input type="text" value={playlistName} onChange={e=>setPlaylistName(e.target.value)} placeholder="Playlist name…"
                style={{flex:1,background:c_inner,border:`1px solid ${c_bord}`,borderRadius:'.5rem',padding:'.5rem .75rem',color:c_text,fontSize:'14px'}}/>
              <button onClick={saveCurrentPlaylist} disabled={!playlist.length}
                style={{padding:'.5rem 1rem',borderRadius:'.5rem',background:playlist.length?'#b8813a':'#4a3a1e',color:'#fff',border:'none',fontWeight:700,cursor:playlist.length?'pointer':'default',whiteSpace:'nowrap',opacity:playlist.length?1:.55}}>
                Save
              </button>
            </div>
          </div>

          <div className="scroll-y" style={{flex:1,padding:'0 1rem',display:'flex',flexDirection:'column',gap:'.5rem'}}>
            {savedPlaylists.length===0 && <p style={{textAlign:'center',padding:'2rem',color:c_sub,fontSize:'.85rem'}}>No saved playlists yet.</p>}
            {savedPlaylists.map(saved => (
              <div key={saved.id || saved.name} className="card" style={{padding:'1rem',display:'flex',alignItems:'center',gap:'.75rem'}}>
                <div style={{flex:1,minWidth:0}}>
                  <p style={{margin:0,fontSize:'.85rem',fontWeight:600,color:c_head,overflow:'hidden',textOverflow:'ellipsis',whiteSpace:'nowrap'}}>{saved.name}</p>
                  <p style={{margin:'.2rem 0 0',fontSize:'.68rem',color:c_sub}}>
                    {(saved.count || saved.episodes?.length || 0)} episode{(saved.count || saved.episodes?.length || 0)===1?'':'s'}
                    {saved.updatedAt ? ` · Updated ${new Date(saved.updatedAt).toLocaleDateString()}` : ''}
                  </p>
                </div>
                <button onClick={()=>loadSavedPlaylist(saved)}
                  style={{padding:'.4rem .875rem',borderRadius:'.5rem',background:'rgba(230,178,119,.2)',color:'#e6b277',border:'none',fontSize:'.75rem',fontWeight:700,cursor:'pointer',whiteSpace:'nowrap'}}>
                  Load
                </button>
                <button onClick={()=>loadSavedPlaylist(saved, { autoplay: true })}
                  style={{padding:'.4rem .875rem',borderRadius:'.5rem',background:'#b8813a',color:'#fff',border:'none',fontSize:'.75rem',fontWeight:700,cursor:'pointer',whiteSpace:'nowrap'}}>
                  Play
                </button>
                <button onClick={()=>setSavedPlaylists(prev=>prev.filter(entry=>(entry.id || entry.name)!==(saved.id || saved.name)))}
                  style={{background:'none',border:'none',cursor:'pointer',color:'#6b5d48',padding:'.25rem',display:'flex',alignItems:'center'}}
                  onMouseOver={e=>e.currentTarget.style.color='#f87171'}
                  onMouseOut={e=>e.currentTarget.style.color='#6b5d48'}>
                  <LucideIcon name="Trash2" size={16}/>
                </button>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* ── Main ── */}
      <div style={{maxWidth:500,margin:'0 auto',paddingLeft:'1rem',paddingRight:'1rem'}} className="pad-top pad-bottom">

        {/* Header */}
        <Header />

        <NowPlayingBar onOpen={()=>setShowPodcasts(true)} />

        <div style={{display:'flex',flexDirection:'column',gap:'1rem'}}>

          {/* Sounds — the primary choice, first */}
          <AmbientBinaural />

          {/* Sleep Timer */}
          <SleepTimer />

          {/* Master volume + saved mixes */}
          <MixerPanel />

          {/* Podcasts entry — opens the podcast screen */}
          <button onClick={()=>setShowPodcasts(true)} className="card" style={{display:'flex',alignItems:'center',justifyContent:'space-between',cursor:'pointer',width:'100%',textAlign:'left',border:'1px solid var(--c-border)'}}>
            <span style={{display:'flex',alignItems:'center',gap:'.6rem',fontWeight:700,fontSize:'1rem',color:c_head}}>
              <LucideIcon name="Rss" size={20} color={bm?'#a9762f':'#e6b277'}/> Podcasts
            </span>
            <span style={{display:'flex',alignItems:'center',gap:'.5rem',color:c_sub,fontSize:'.85rem'}}>
              Browse &amp; play
              <span style={{fontSize:'1.3rem',lineHeight:1,color:c_dim}}>›</span>
            </span>
          </button>

          {/* Install hint */}
          <div style={{textAlign:'center',fontSize:'.7rem',color:c_sub,padding:'.5rem 0 .25rem',lineHeight:1.7}}>
            <p style={{margin:0}}><strong style={{color:c_sub}}>iPhone:</strong> Safari → Share → "Add to Home Screen"</p>
            <p style={{margin:0}}><strong style={{color:c_sub}}>Android:</strong> Chrome → ⋮ → "Add to Home Screen"</p>
          </div>
        </div>

        {/* Podcast screen */}
        {showPodcasts && (
        <div className="overlay" style={{zIndex:150,paddingTop:'var(--top-clearance)',overflowY:'auto'}}>
          <div style={{maxWidth:500,margin:'0 auto',paddingLeft:'1rem',paddingRight:'1rem'}} className="pad-bottom">
            <div style={{display:'flex',alignItems:'center',gap:'.5rem',padding:'0 0 1rem'}}>
              <button onClick={()=>setShowPodcasts(false)} className="btn-icon" title="Back"><LucideIcon name="X" size={20}/></button>
              <span style={{fontSize:'1.1rem',fontWeight:800,color:c_head}}>Podcasts</span>
            </div>

          {/* Podcast */}
          <div className="card" style={{position:'relative',overflow:'hidden'}}>
            {podPlaying && !bm && <div className="glow-purple" style={{position:'absolute',top:0,left:0,width:3,height:'100%',background:'#e6b277',borderRadius:2}}/>}

            <div style={{display:'flex',alignItems:'center',justifyContent:'space-between',marginBottom:'1rem'}}>
              <div style={{display:'flex',alignItems:'center',gap:'.5rem',color:bm?'#a9762f':'#e6b277'}}>
                <LucideIcon name="Rss" size={18}/>
                <span style={{fontWeight:700,fontSize:'.9rem'}}>Podcast Stream</span>
              </div>
              <button onClick={()=>setShowSubs(true)} className="btn-icon" title="Saved Feeds">
                <LucideIcon name="BookMarked" size={16}/>
              </button>
            </div>

            {/* URL input */}
            <div style={{display:'flex',gap:'.5rem',marginBottom:'.875rem'}}>
              <input type="url" value={rssUrl} onChange={e=>setRssUrl(e.target.value)}
                onKeyDown={e=>{ if(e.key==='Enter'){ e.target.blur(); loadFeed(); } }}
                placeholder="Paste podcast feed URL…"
                style={{flex:1,background:c_inner,border:`1px solid ${c_bord}`,borderRadius:'.625rem',padding:'.5rem .75rem',color:c_text,fontSize:'14px'}}/>
              <button onClick={()=>{ document.activeElement?.blur(); loadFeed(); }} disabled={loading}
                style={{padding:'.5rem 1rem',borderRadius:'.625rem',background:bm?'#2a2114':'#b8813a',color:bm?'#b39b80':'#fff',border:'none',fontWeight:700,cursor:'pointer',whiteSpace:'nowrap',minWidth:60,opacity:loading?.6:1}}>
                {loading?'…':'Load'}
              </button>
            </div>

            <PodcastSettings />

            <PodcastEffects />

            {/* Now Playing strip */}
            {curEp && (
              <div className="card-inner" style={{marginBottom:'.875rem',background:bm?'rgba(230,178,119,.05)':'rgba(230,178,119,.07)',borderColor:bm?'rgba(230,178,119,.25)':'rgba(230,178,119,.25)'}}>
                <div style={{fontSize:'.62rem',fontWeight:700,letterSpacing:'.07em',textTransform:'uppercase',color:bm?'#a9762f':'#e6b277',marginBottom:'.2rem'}}>
                  {podPlaying ? '▶ Now Playing' : '⏸ Paused'}
                </div>
                <div style={{fontSize:'.73rem',color:c_head,lineHeight:1.4,marginBottom:'.5rem',display:'-webkit-box',WebkitLineClamp:2,WebkitBoxOrient:'vertical',overflow:'hidden'}}>
                  {curEp.title}
                </div>
                <input type="range" min={0} max={podProgress.dur||1} step={1} value={podProgress.cur}
                  onChange={e=>{ if(podAudio.current) podAudio.current.currentTime=+e.target.value; }}
                  className="purple" style={{width:'100%',marginBottom:'.2rem'}}/>
                <div style={{display:'flex',justifyContent:'space-between',fontSize:'.65rem',color:c_sub}}>
                  <span>{fmtTime(podProgress.cur)}</span>
                  <span>{podProgress.dur>0 ? fmtTime(podProgress.dur) : '--:--'}</span>
                </div>
              </div>
            )}

            <EpisodeBrowser />
          </div>
          </div>
        </div>
        )}
      </div>
    </div>
  );
}

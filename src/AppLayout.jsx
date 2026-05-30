import React from 'react';
import { useAppContext } from './context/AppContext.jsx';
import {
  BookMarked, Clock, GripVertical, Moon, MoonStar, Pause, Play, Plus, RotateCcw, RotateCw, Rss, Search, Settings2, Shuffle, SlidersHorizontal, Square, Sun, Trash2, Volume2, VolumeX, Wind, X, HelpCircle, Download, Check, Waves
} from 'lucide-react';

const icons = {
  BookMarked, Clock, GripVertical, Moon, MoonStar, Pause, Play, Plus, RotateCcw, RotateCw, Rss, Search, Settings2, Shuffle, SlidersHorizontal, Square, Sun, Trash2, Volume2, VolumeX, Wind, X, Download, Check, Waves
};

function LucideIcon({ name, size = 20, color = 'currentColor', strokeWidth = 2, className = '', style = {} }) {
  const Icon = icons[name] || HelpCircle;
  return <Icon size={size} color={color} strokeWidth={strokeWidth} className={className} style={style} />;
}


  const handleExportData = () => {
    const data = JSON.stringify(localStorage);
    const blob = new Blob([data], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `sleepulator-backup-${new Date().toISOString().split('T')[0]}.json`;
    a.click();
    URL.revokeObjectURL(url);
  };

  const handleImportData = (e) => {
    const file = e.target.files[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = (event) => {
      try {
        const data = JSON.parse(event.target.result);
        for (const [key, value] of Object.entries(data)) {
          localStorage.setItem(key, value);
        }
        alert('Data imported successfully! The app will now reload.');
        window.location.reload();
      } catch (err) {
        alert('Failed to parse backup file.');
      }
    };
    reader.readAsText(file);
  };

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

  const [mixName, setMixName] = React.useState('');
  const [showMixes, setShowMixes] = React.useState(false);
  
  return (
    <div className="app-container" style={{minHeight:'100dvh', color:c_text}}>
      <div className="mesh-bg" />

      {/* ── Breathing overlay ── */}
      {breathMode && bc && (
        <div className="overlay" style={{background:bm?'#000':'rgba(3,7,18,.97)',alignItems:'center',justifyContent:'center'}}>
          <button onClick={()=>setBreathMode(null)}
            style={{position:'absolute',top:'var(--top-clearance)',right:'1.25rem',background:'#1e293b',border:'none',borderRadius:'50%',width:44,height:44,display:'flex',alignItems:'center',justifyContent:'center',cursor:'pointer',color:'#94a3b8'}}>
            <LucideIcon name="X" size={20}/>
          </button>
          <div style={{display:'flex',gap:'.75rem',marginBottom:'2rem'}}>
            {['478','box'].map(m=>(
              <button key={m} onClick={()=>setBreathMode(m)}
                style={{padding:'.5rem 1.25rem',borderRadius:'9999px',border:'none',fontWeight:700,fontSize:'.8rem',cursor:'pointer',
                  background:breathMode===m?(bm?'#1f2937':'#4f46e5'):(bm?'#111':'#1e293b'),
                  color:breathMode===m?'#fff':(bm?'#6b7280':'#94a3b8')}}>
                {m==='478'?'4-7-8':'Box 4-4-4-4'}
              </button>
            ))}
          </div>
          <h2 style={{fontSize:'1.2rem',fontWeight:800,letterSpacing:'.08em',color:bm?'#9ca3af':bc.col,marginBottom:'.25rem'}}>{bc.label}</h2>
          <p style={{fontSize:'.85rem',color:c_sub,marginBottom:'5rem',textAlign:'center',padding:'0 2rem'}}>{bc.sub}</p>
          <div style={{position:'relative',width:220,height:220,display:'flex',alignItems:'center',justifyContent:'center'}}>
            <div style={{position:'absolute',inset:0,borderRadius:'50%',background:bc.col,opacity:.1}}/>
            <div className={bc.cls} style={{width:'100%',height:'100%',borderRadius:'50%',background:bc.col,opacity:.85,boxShadow:bm?'none':`0 0 60px ${bc.col}40`}}/>
          </div>
        </div>
      )}

      {/* ── Saved feeds overlay ── */}
      {showSubs && (
        <div className="overlay" style={{background:bm?'#000':'#030712',paddingTop:'var(--top-clearance)'}}>
          <div style={{display:'flex',alignItems:'center',justifyContent:'space-between',padding:'1.25rem'}}>
            <h2 style={{fontSize:'1.1rem',fontWeight:800,color:c_head,margin:0}}>Saved Feeds</h2>
            <button onClick={()=>setShowSubs(false)}
              style={{background:'#1e293b',border:'none',borderRadius:'50%',width:44,height:44,display:'flex',alignItems:'center',justifyContent:'center',cursor:'pointer',color:'#94a3b8'}}>
              <LucideIcon name="X" size={18}/>
            </button>
          </div>

          <div className="card" style={{margin:'0 1rem 1rem',padding:'1rem'}}>
            <p style={{fontSize:'.7rem',color:c_sub,margin:'0 0 .5rem'}}>Loaded feeds are saved automatically. Use this to rename the current feed if you want.</p>
            <div style={{display:'flex',gap:'.5rem'}}>
              <input type="text" value={subName} onChange={e=>setSubName(e.target.value)} placeholder={rssUrl.trim() ? "Current feed name…" : "Load a feed to rename it…"}
                style={{flex:1,background:c_inner,border:`1px solid ${c_bord}`,borderRadius:'.5rem',padding:'.5rem .75rem',color:c_text,fontSize:'14px'}}/>
              <button onClick={saveSub} disabled={!rssUrl.trim()}
                style={{padding:'.5rem 1rem',borderRadius:'.5rem',background:rssUrl.trim()?'#6d28d9':'#312e81',color:'#fff',border:'none',fontWeight:700,cursor:rssUrl.trim()?'pointer':'default',whiteSpace:'nowrap',opacity:rssUrl.trim()?1:.55}}>
                Update
              </button>
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
                  style={{padding:'.4rem .875rem',borderRadius:'.5rem',background:'rgba(139,92,246,.2)',color:'#c084fc',border:'none',fontSize:'.75rem',fontWeight:700,cursor:'pointer',whiteSpace:'nowrap'}}>
                  Load
                </button>
                <button onClick={()=>{ setSubName(s.name || ''); loadFeed(s.url, { autoplay: true, closeLibrary: true }); }}
                  style={{padding:'.4rem .875rem',borderRadius:'.5rem',background:'#6d28d9',color:'#fff',border:'none',fontSize:'.75rem',fontWeight:700,cursor:'pointer',whiteSpace:'nowrap'}}>
                  Play
                </button>
                <button onClick={()=>setSubs(prev=>prev.filter(x=>x.url!==s.url))}
                  style={{background:'none',border:'none',cursor:'pointer',color:'#4b5563',padding:'.25rem',display:'flex',alignItems:'center'}}
                  onMouseOver={e=>e.currentTarget.style.color='#f87171'}
                  onMouseOut={e=>e.currentTarget.style.color='#4b5563'}>
                  <LucideIcon name="Trash2" size={16}/>
                </button>
              </div>
            ))}
          </div>
        </div>
      )}

      {showPlaylistLibrary && (
        <div className="overlay" style={{background:bm?'#000':'#030712',paddingTop:'var(--top-clearance)'}}>
          <div style={{display:'flex',alignItems:'center',justifyContent:'space-between',padding:'1.25rem'}}>
            <h2 style={{fontSize:'1.1rem',fontWeight:800,color:c_head,margin:0}}>Saved Playlists</h2>
            <button onClick={()=>setShowPlaylistLibrary(false)}
              style={{background:'#1e293b',border:'none',borderRadius:'50%',width:44,height:44,display:'flex',alignItems:'center',justifyContent:'center',cursor:'pointer',color:'#94a3b8'}}>
              <LucideIcon name="X" size={18}/>
            </button>
          </div>

          <div className="card" style={{margin:'0 1rem 1rem',padding:'1rem'}}>
            <p style={{fontSize:'.7rem',color:c_sub,margin:'0 0 .5rem'}}>Save the current queue under a reusable name.</p>
            <div style={{display:'flex',gap:'.5rem'}}>
              <input type="text" value={playlistName} onChange={e=>setPlaylistName(e.target.value)} placeholder="Playlist name…"
                style={{flex:1,background:c_inner,border:`1px solid ${c_bord}`,borderRadius:'.5rem',padding:'.5rem .75rem',color:c_text,fontSize:'14px'}}/>
              <button onClick={saveCurrentPlaylist} disabled={!playlist.length}
                style={{padding:'.5rem 1rem',borderRadius:'.5rem',background:playlist.length?'#6d28d9':'#312e81',color:'#fff',border:'none',fontWeight:700,cursor:playlist.length?'pointer':'default',whiteSpace:'nowrap',opacity:playlist.length?1:.55}}>
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
                  style={{padding:'.4rem .875rem',borderRadius:'.5rem',background:'rgba(139,92,246,.2)',color:'#c084fc',border:'none',fontSize:'.75rem',fontWeight:700,cursor:'pointer',whiteSpace:'nowrap'}}>
                  Load
                </button>
                <button onClick={()=>loadSavedPlaylist(saved, { autoplay: true })}
                  style={{padding:'.4rem .875rem',borderRadius:'.5rem',background:'#6d28d9',color:'#fff',border:'none',fontSize:'.75rem',fontWeight:700,cursor:'pointer',whiteSpace:'nowrap'}}>
                  Play
                </button>
                <button onClick={()=>setSavedPlaylists(prev=>prev.filter(entry=>(entry.id || entry.name)!==(saved.id || saved.name)))}
                  style={{background:'none',border:'none',cursor:'pointer',color:'#4b5563',padding:'.25rem',display:'flex',alignItems:'center'}}
                  onMouseOver={e=>e.currentTarget.style.color='#f87171'}
                  onMouseOut={e=>e.currentTarget.style.color='#4b5563'}>
                  <LucideIcon name="Trash2" size={16}/>
                </button>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* ── Main ── */}
      <div style={{maxWidth:500,margin:'0 auto',padding:'0 1rem'}} className="pad-top pad-bottom">

        {/* Header */}
        <header style={{display:'flex',alignItems:'center',justifyContent:'space-between',marginBottom:'1.25rem'}}>
          <div style={{display:'flex',alignItems:'center',gap:'.625rem'}}>
            <LucideIcon name="Moon" size={26} color={bm?'#374151':'#818cf8'}/>
            <h1 style={{margin:0,fontSize:'1.4rem',fontWeight:900,letterSpacing:'.12em',
              background:bm?'none':'linear-gradient(135deg,#818cf8,#c084fc)',
              WebkitBackgroundClip:bm?'unset':'text',WebkitTextFillColor:bm?'#6b7280':'transparent',
              color:bm?'#6b7280':'transparent'}}>
              SLEEPULATOR
            </h1>
          </div>
          <div style={{display:'flex',gap:'.5rem',alignItems:'center'}}>
            <button onClick={()=>setBreathMode(v=>v?null:'478')} title="Breathing Guide"
              className={`btn-icon${breathMode?' active-indigo':''}`}>
              <LucideIcon name="Wind" size={18}/>
            </button>
            <button onClick={()=>setBm(v=>!v)}
              style={{display:'flex',alignItems:'center',gap:'.375rem',padding:'.5rem .875rem',borderRadius:'9999px',
                border:`1px solid ${bm?'#1f2937':'rgba(129,140,248,.3)'}`,
                background:bm?'#0a0a0a':'rgba(129,140,248,.08)',
                color:bm?'#6b7280':'#818cf8',cursor:'pointer',fontSize:'.75rem',fontWeight:700}}>
              <LucideIcon name={bm?'Sun':'MoonStar'} size={14}/>
              {bm?'Wake':'Bedtime'}
            </button>
          </div>
        </header>

        {/* Master Volume */}
        <div className="card" style={{display:'flex',alignItems:'center',gap:'.875rem',marginBottom:'1rem'}}>
          <LucideIcon name="Settings2" size={18} color={bm?'#4b5563':'#818cf8'}/>
          <span style={{fontSize:'.8rem',fontWeight:700,color:c_head,whiteSpace:'nowrap'}}>Master</span>
          <input type="range" min="0" max="1" step=".01" value={masterVol} className="indigo"
            onChange={e=>setMasterVol(+e.target.value)} style={{flex:1}}/>
          <span style={{fontSize:'.7rem',fontFamily:'monospace',color:c_sub,width:32,textAlign:'right'}}>{Math.round(masterVol*100)}%</span>
        </div>

        {/* Pro Audio Controls */}
        <div style={{display:'flex',gap:'.5rem',marginBottom:'1rem'}}>
          <button onClick={() => setCompOn(!compOn)} className="card"
            style={{flex:1,display:'flex',flexDirection:'column',alignItems:'center',gap:'.5rem',padding:'.875rem',cursor:'pointer',
            border:compOn?'1px solid rgba(192,132,252,0.4)':'1px solid var(--c-border)',
            background:compOn?'rgba(192,132,252,0.1)':'var(--c-surface)'}}>
            <LucideIcon name="Settings2" size={16} color={compOn?'#c084fc':'var(--c-dim)'} />
            <span style={{fontSize:'.65rem',fontWeight:700,color:compOn?'#c084fc':'var(--c-dim)'}}>NIGHT COMP</span>
          </button>
          
          <button onClick={() => setEqOn(!eqOn)} className="card"
            style={{flex:1,display:'flex',flexDirection:'column',alignItems:'center',gap:'.5rem',padding:'.875rem',cursor:'pointer',
            border:eqOn?'1px solid rgba(96,165,250,0.4)':'1px solid var(--c-border)',
            background:eqOn?'rgba(96,165,250,0.1)':'var(--c-surface)'}}>
            <LucideIcon name="SlidersHorizontal" size={16} color={eqOn?'#60a5fa':'var(--c-dim)'} />
            <span style={{fontSize:'.65rem',fontWeight:700,color:eqOn?'#60a5fa':'var(--c-dim)'}}>VOICE EQ</span>
          </button>

          <button onClick={() => setPanOn(!panOn)} className="card"
            style={{flex:1,display:'flex',flexDirection:'column',alignItems:'center',gap:'.5rem',padding:'.875rem',cursor:'pointer',
            border:panOn?'1px solid rgba(236,72,153,0.4)':'1px solid var(--c-border)',
            background:panOn?'rgba(236,72,153,0.1)':'var(--c-surface)'}}>
            <LucideIcon name="Waves" size={16} color={panOn?'#ec4899':'var(--c-dim)'} />
            <span style={{fontSize:'.65rem',fontWeight:700,color:panOn?'#ec4899':'var(--c-dim)'}}>AUTO PAN</span>
          </button>

        </div>


        
        {/* Mix Presets */}
        <div style={{marginBottom:'1rem'}}>
          <div style={{display:'flex',justifyContent:'space-between',alignItems:'center',marginBottom:'.5rem',padding:'0 .5rem'}}>
            <span className="section-label" style={{margin:0}}>Mix Presets</span>
            <button onClick={() => setShowMixes(!showMixes)} className="btn-icon" style={{width:28,height:28,minWidth:28,minHeight:28}}>
              <LucideIcon name={showMixes ? 'X' : 'BookMarked'} size={14} />
            </button>
          </div>
          
          {showMixes && (
            <div className="card" style={{marginBottom:'1rem', padding:'1rem'}}>
              <div style={{display:'flex',gap:'.5rem',marginBottom:mixPresets.length ? '1rem' : 0}}>
                <input type="text" value={mixName} onChange={e=>setMixName(e.target.value)} placeholder="Name this mix..." 
                  style={{flex:1, fontSize:'14px'}}/>
                <button onClick={()=>{ saveCurrentMix(mixName); setMixName(''); }} disabled={!mixName.trim()} 
                  className="btn-pill" style={{padding:'0 1rem'}}>Save</button>
              </div>
              
              {mixPresets.length > 0 && (
                <div style={{display:'flex',flexDirection:'column',gap:'.5rem',maxHeight:200}} className="scroll-y">
                  {mixPresets.map(mix => (
                    <div key={mix.id} className="card-inner" style={{display:'flex',alignItems:'center',gap:'.5rem',padding:'.5rem'}}>
                      <button onClick={()=>loadMix(mix)} style={{flex:1,textAlign:'left',background:'transparent',border:'none',color:c_head,fontWeight:600,cursor:'pointer',padding:'.25rem'}}>
                        {mix.name}
                      </button>
                      <button onClick={()=>deleteMix(mix.id)} className="btn-icon" style={{width:32,height:32,minWidth:32,minHeight:32}}>
                        <LucideIcon name="Trash2" size={14} color="#f87171" />
                      </button>
                    </div>
                  ))}
                </div>
              )}
            </div>
          )}
        </div>

        <div style={{display:'flex',flexDirection:'column',gap:'1rem'}}>

          {/* Sleep Timer */}
          <div style={cardStyle}>
            <div style={{display:'flex',alignItems:'center',justifyContent:'space-between',marginBottom:'1rem'}}>
              <div style={{display:'flex',alignItems:'center',gap:'.5rem',color:bm?'#6b7280':'#a5b4fc'}}>
                <LucideIcon name="Clock" size={18}/>
                <span style={{fontWeight:700,fontSize:'.9rem'}}>Sleep Timer</span>
              </div>
              {timerActive && <span style={{fontFamily:'monospace',fontSize:'1.3rem',fontWeight:700,color:bm?'#9ca3af':'#818cf8',letterSpacing:'.04em'}}>{fmt(timeLeft)}</span>}
            </div>
            <div style={{display:'flex',gap:'.375rem',marginBottom:'.625rem'}}>
              {[15,30,45,60].map(m=>(
                <button key={m} onClick={()=>setTimerMins(m)} disabled={timerActive}
                  className={`speed-chip${timerMins===m?' on':''}`}
                  style={{opacity:timerActive?.4:1}}>
                  {m}m
                </button>
              ))}
            </div>
            <div style={{display:'flex',alignItems:'center',gap:'.75rem',marginBottom:'1rem'}}>
              <span style={{fontSize:'.7rem',color:c_sub}}>5m</span>
              <input type="range" min="5" max="120" step="5" value={timerMins} className="indigo"
                disabled={timerActive} onChange={e=>setTimerMins(+e.target.value)} style={{flex:1,opacity:timerActive?.4:1}}/>
              <span style={{fontSize:'.75rem',color:c_sub,width:36,textAlign:'right'}}>{timerMins}m</span>
            </div>
            {timerActive&&timeLeft!==null&&timeLeft<=60&&timeLeft>0 ? (
              <button onClick={bumpTimer} className="btn-primary"
                style={{background:bm?'#1f2937':'#4f46e5',color:bm?'#d1d5db':'#fff',animation:'pulse 1.5s ease-in-out infinite',
                  boxShadow:bm?'none':'0 0 20px rgba(79,70,229,.4)'}}>
                Still Awake? (+15 min)
              </button>
            ):(
              <button onClick={toggleTimer} className="btn-primary"
                style={{background:timerActive?(bm?'rgba(255,255,255,.04)':'rgba(248,113,113,.1)'):(bm?'#1f2937':'#4f46e5'),
                  color:timerActive?(bm?'#6b7280':'#f87171'):(bm?'#d1d5db':'#fff'),
                  border:timerActive?`1px solid ${bm?'#1f2937':'rgba(248,113,113,.3)'}`:'none',
                  boxShadow:timerActive?'none':(bm?'none':'0 4px 20px rgba(79,70,229,.3)')}}>
                {timerActive?'Cancel Timer':`Start ${timerMins} Min Timer`}
              </button>
            )}
            <p style={{fontSize:'.7rem',color:c_sub,textAlign:'center',margin:'.75rem 0 0'}}>Audio fades out over the last 60 seconds</p>
          </div>

          {/* Ambient + Binaural */}
          <div style={{display:'grid',gridTemplateColumns:'1fr 1fr',gap:'1rem'}}>

            {/* Ambient */}
            <div className="card" style={{position:'relative',overflow:'hidden'}}>
              {ambientOn && !bm && <div className="glow-orange" style={{position:'absolute',top:0,left:0,width:3,height:'100%',background:'#fb923c',borderRadius:2}}/>}
              <div style={{display:'flex',justifyContent:'space-between',alignItems:'flex-start',marginBottom:'.875rem'}}>
                <div style={{flex:1,minWidth:0}}>
                  <div style={{fontSize:'.8rem',fontWeight:700,color:c_head,marginBottom:'.5rem'}}>Ambient</div>
                  <select value={noiseType} onChange={e=>setNoiseType(e.target.value)}
                    style={{fontSize:'12px',background:c_inner,border:`1px solid ${c_bord}`,borderRadius:'.5rem',color:c_sub,padding:'.25rem .375rem',width:'100%'}}>
                    {Object.entries(NOISE_TYPES).map(([k,v])=><option key={k} value={k}>{v.label}</option>)}
                  </select>
                </div>
                <button onClick={toggleAmbient} className={`btn-icon${ambientOn?' active-orange':''}`} style={{marginLeft:'.5rem',flexShrink:0}}>
                  <LucideIcon name={ambientOn?'Square':'Play'} size={18}/>
                </button>
              </div>
              <div style={{display:'flex',alignItems:'center',gap:'.5rem'}}>
                <LucideIcon name="Volume2" size={14} color={c_sub}/>
                <input type="range" min="0" max="1" step=".01" value={ambientVol} className="orange"
                  onChange={e=>setAmbientVol(+e.target.value)} style={{flex:1}}/>
              </div>
              <label style={{display:'flex',alignItems:'center',gap:'.5rem',fontSize:'.7rem',color:c_sub,marginTop:'.75rem',cursor:'pointer'}}>
                <input type="checkbox" checked={ambientBypass} onChange={e=>setAmbientBypass(e.target.checked)}/>
                All night (bypass timer)
              </label>
            </div>

            {/* Binaural */}
            <div className="card" style={{position:'relative',overflow:'hidden'}}>
              {binOn && !bm && <div className="glow-blue" style={{position:'absolute',top:0,left:0,width:3,height:'100%',background:'#60a5fa',borderRadius:2}}/>}
              <div style={{display:'flex',justifyContent:'space-between',alignItems:'flex-start',marginBottom:'.875rem'}}>
                <div style={{flex:1,minWidth:0}}>
                  <div style={{fontSize:'.8rem',fontWeight:700,color:c_head,marginBottom:'.5rem'}}>Binaural</div>
                  <select value={binPreset} onChange={e=>setBinPreset(e.target.value)}
                    style={{fontSize:'12px',background:c_inner,border:`1px solid ${c_bord}`,borderRadius:'.5rem',color:c_sub,padding:'.25rem .375rem',width:'100%'}}>
                    {Object.entries(BINAURAL).map(([k,v])=><option key={k} value={k}>{v.name}</option>)}
                  </select>
                </div>
                <button onClick={toggleBin} className={`btn-icon${binOn?' active-blue':''}`} style={{marginLeft:'.5rem',flexShrink:0}}>
                  <LucideIcon name={binOn?'Square':'Play'} size={18}/>
                </button>
              </div>
              <div style={{display:'flex',alignItems:'center',gap:'.5rem'}}>
                <LucideIcon name="Volume2" size={14} color={c_sub}/>
                <input type="range" min="0" max="1" step=".01" value={binVol} className="blue"
                  onChange={e=>setBinVol(+e.target.value)} style={{flex:1}}/>
              </div>
              <label style={{display:'flex',alignItems:'center',gap:'.5rem',fontSize:'.7rem',color:c_sub,marginTop:'.75rem',cursor:'pointer'}}>
                <input type="checkbox" checked={binBypass} onChange={e=>setBinBypass(e.target.checked)}/>
                All night (bypass timer)
              </label>
            </div>
          </div>

          {/* Podcast */}
          <div className="card" style={{position:'relative',overflow:'hidden'}}>
            {podPlaying && !bm && <div className="glow-purple" style={{position:'absolute',top:0,left:0,width:3,height:'100%',background:'#c084fc',borderRadius:2}}/>}

            <div style={{display:'flex',alignItems:'center',justifyContent:'space-between',marginBottom:'1rem'}}>
              <div style={{display:'flex',alignItems:'center',gap:'.5rem',color:bm?'#7c3aed':'#c084fc'}}>
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
                style={{padding:'.5rem 1rem',borderRadius:'.625rem',background:bm?'#1f2937':'#7e22ce',color:bm?'#9ca3af':'#fff',border:'none',fontWeight:700,cursor:'pointer',whiteSpace:'nowrap',minWidth:60,opacity:loading?.6:1}}>
                {loading?'…':'Load'}
              </button>
            </div>

            <div className="card-inner" style={{marginBottom:'.875rem',display:'flex',flexDirection:'column',gap:'.625rem'}}>
              <div style={{display:'flex',alignItems:'flex-start',justifyContent:'space-between',gap:'.75rem'}}>
                <div>
                  <div className="section-label" style={{marginBottom:'.25rem'}}>Private Feed Proxy</div>
                  <div style={{fontSize:'.65rem',color:c_sub,lineHeight:1.5}}>
                    Member-only feeds use the built-in private proxy by default. Replace it only if you run your own worker.
                  </div>
                </div>
                <button
                  onClick={()=>setShowFeedDebug(v=>!v)}
                  style={{padding:'.4rem .65rem',borderRadius:'.625rem',border:`1px solid ${c_bord}`,background:'transparent',color:c_sub,fontSize:'.65rem',fontWeight:700,cursor:'pointer',whiteSpace:'nowrap'}}
                >
                  {showFeedDebug ? 'Hide Debug' : 'Feed Debug'}
                </button>
              </div>

              <div style={{display:'flex',gap:'.5rem'}}>
                <input
                  type="url"
                  value={feedProxyUrl}
                  onChange={e=>setFeedProxyUrl(e.target.value)}
                  placeholder="Built-in proxy URL…"
                  style={{flex:1,background:c_inner,border:`1px solid ${c_bord}`,borderRadius:'.625rem',padding:'.5rem .75rem',color:c_text,fontSize:'13px'}}
                />
                <button
                  onClick={()=>setFeedProxyUrl(getDefaultFeedProxyUrl())}
                  disabled={normalizeConfigUrl(feedProxyUrl) === getDefaultFeedProxyUrl()}
                  style={{padding:'.5rem .8rem',borderRadius:'.625rem',background:'transparent',color:normalizeConfigUrl(feedProxyUrl) === getDefaultFeedProxyUrl()?c_dim:c_sub,border:`1px solid ${c_bord}`,fontWeight:700,cursor:normalizeConfigUrl(feedProxyUrl) === getDefaultFeedProxyUrl()?'default':'pointer',whiteSpace:'nowrap',opacity:normalizeConfigUrl(feedProxyUrl) === getDefaultFeedProxyUrl()?.6:1}}
                >
                  Reset
                </button>
              </div>

              <div style={{borderTop:`1px solid ${c_bord}`,marginTop:'.125rem',paddingTop:'.625rem',display:'flex',flexDirection:'column',gap:'.625rem'}}>
                <div style={{display:'flex',alignItems:'flex-start',justifyContent:'space-between',gap:'.75rem'}}>
                  <div>
                    <div className="section-label" style={{marginBottom:'.25rem'}}>Sleep Safe Audio</div>
                    <div style={{fontSize:'.65rem',color:c_sub,lineHeight:1.5}}>
                      Optional server-side limiter and loudness normalization for podcast playback. Best for reducing abrupt spikes before sleep.
                    </div>
                  </div>
                  <label style={{display:'flex',alignItems:'center',gap:'.5rem',fontSize:'.68rem',color:c_sub,cursor:'pointer',whiteSpace:'nowrap'}}>
                    <input
                      type="checkbox"
                      checked={sleepSafeAudio}
                      onChange={e=>setSleepSafeAudio(e.target.checked)}
                    />
                    Enabled
                  </label>
                </div>

                <div style={{display:'flex',gap:'.5rem'}}>
                  <input
                    type="url"
                    value={audioProxyUrl}
                    onChange={e=>setAudioProxyUrl(e.target.value)}
                    placeholder="Sleep Safe proxy URL…"
                    style={{flex:1,background:c_inner,border:`1px solid ${c_bord}`,borderRadius:'.625rem',padding:'.5rem .75rem',color:c_text,fontSize:'13px'}}
                  />
                  <button
                    onClick={()=>setAudioProxyUrl('')}
                    disabled={!audioProxyUrl}
                    style={{padding:'.5rem .8rem',borderRadius:'.625rem',background:'transparent',color:audioProxyUrl?c_sub:c_dim,border:`1px solid ${c_bord}`,fontWeight:700,cursor:audioProxyUrl?'pointer':'default',whiteSpace:'nowrap',opacity:audioProxyUrl?1:.6}}
                  >
                    Clear
                  </button>
                </div>

                <div style={{fontSize:'.62rem',color:c_dim,lineHeight:1.5}}>
                  Sleep Safe uses a server proxy, so scrubbing may be less precise than direct playback.
                </div>
                <div style={{fontSize:'.62rem',color:sleepSafeAudio && !sleepSafeConfigured ? '#fbbf24' : c_dim,lineHeight:1.5}}>
                  {sleepSafeConfigured
                    ? 'Status: proxy configured.'
                    : 'Status: no Sleep Safe proxy URL yet. Playback will fall back to direct audio.'}
                </div>
              </div>

              
              {/* Backup & Restore */}
              <div className="card" style={{marginBottom:'1rem'}}>
                <div style={{display:'flex',justifyContent:'space-between',alignItems:'flex-start',marginBottom:'.5rem'}}>
                  <div>
                    <div style={{fontSize:'.8rem',fontWeight:700,color:c_head,marginBottom:'.25rem'}}>Backup & Restore</div>
                    <div style={{fontSize:'.65rem',color:c_sub,lineHeight:1.4}}>
                      Export your custom mixes, playlists, and settings to a file, or restore them.
                    </div>
                  </div>
                </div>
                <div style={{display:'flex',gap:'.5rem',marginTop:'.75rem'}}>
                  <button onClick={handleExportData} className="btn-pill" style={{flex:1,padding:'.5rem'}}>
                    Export Data
                  </button>
                  <label className="btn-pill" style={{flex:1,padding:'.5rem',textAlign:'center',cursor:'pointer'}}>
                    Import Data
                    <input type="file" accept=".json" onChange={handleImportData} style={{display:'none'}} />
                  </label>
                </div>
              </div>

              {showFeedDebug && (
                <div style={{background:c_inner,border:`1px solid ${c_bord}`,borderRadius:'.75rem',padding:'.75rem',display:'flex',flexDirection:'column',gap:'.5rem'}}>
                  <div style={{fontSize:'.68rem',fontWeight:700,color:c_head}}>Feed Debug</div>
                  <div style={{fontSize:'.65rem',color:c_sub,lineHeight:1.5}}>
                    Requested: {feedDebug?.requestedUrl ? redactUrlForDisplay(feedDebug.requestedUrl) : 'No feed loaded yet.'}
                  </div>
                  <div style={{fontSize:'.65rem',color:c_sub,lineHeight:1.5}}>
                    Proxy: {redactUrlForDisplay(normalizeConfigUrl(feedProxyUrl || getDefaultFeedProxyUrl()))}
                  </div>
                  {feedDebug?.final && (
                    <div style={{fontSize:'.65rem',color:feedDebug.final.status==='success'?'#86efac':'#fca5a5',lineHeight:1.5}}>
                      Result: {feedDebug.final.status==='success'
                        ? `Loaded ${feedDebug.final.episodeCount} episode${feedDebug.final.episodeCount===1?'':'s'} via ${feedDebug.final.via || 'feed loader'}.`
                        : feedDebug.final.message}
                    </div>
                  )}
                  {feedDebug?.attempts?.length ? (
                    <div style={{display:'flex',flexDirection:'column',gap:'.5rem'}}>
                      {feedDebug.attempts.map((attempt, idx)=>(
                        <div key={`${attempt.hop}-${attempt.via}-${idx}`} style={{border:`1px solid ${c_bord}`,borderRadius:'.625rem',padding:'.625rem',display:'flex',flexDirection:'column',gap:'.2rem'}}>
                          <div style={{display:'flex',justifyContent:'space-between',gap:'.5rem',fontSize:'.65rem'}}>
                            <span style={{fontWeight:700,color:c_head}}>{attempt.via}</span>
                            <span style={{color:c_sub}}>
                              Hop {attempt.hop}
                              {attempt.status ? ` · HTTP ${attempt.status}` : ''}
                            </span>
                          </div>
                          <div style={{fontSize:'.62rem',color:c_sub,lineHeight:1.4,wordBreak:'break-all'}}>
                            {redactUrlForDisplay(attempt.requestUrl || attempt.targetUrl || '')}
                          </div>
                          {attempt.contentType && (
                            <div style={{fontSize:'.62rem',color:c_sub}}>Content-Type: {attempt.contentType}</div>
                          )}
                          {(attempt.markupType || attempt.embeddedFeed) && (
                            <div style={{fontSize:'.62rem',color:c_sub}}>
                              Detected: {attempt.markupType || 'unknown'}{attempt.embeddedFeed ? ` -> ${attempt.embeddedMarkupType || 'embedded feed'}` : ''}
                            </div>
                          )}
                          {attempt.message && (
                            <div style={{fontSize:'.62rem',color:'#86efac'}}>{attempt.message}</div>
                          )}
                          {attempt.error && (
                            <div style={{fontSize:'.62rem',color:'#fca5a5'}}>{attempt.error}</div>
                          )}
                          {attempt.preview && (
                            <div style={{fontSize:'.62rem',color:c_dim,lineHeight:1.4}}>{attempt.preview}</div>
                          )}
                        </div>
                      ))}
                    </div>
                  ) : (
                    <div style={{fontSize:'.62rem',color:c_dim}}>No request attempts recorded yet.</div>
                  )}
                </div>
              )}
            </div>

            {/* Now Playing strip */}
            {curEp && (
              <div className="card-inner" style={{marginBottom:'.875rem',background:bm?'rgba(139,92,246,.05)':'rgba(192,132,252,.07)',borderColor:bm?'rgba(139,92,246,.25)':'rgba(192,132,252,.25)'}}>
                <div style={{fontSize:'.62rem',fontWeight:700,letterSpacing:'.07em',textTransform:'uppercase',color:bm?'#7c3aed':'#a78bfa',marginBottom:'.2rem'}}>
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

            {/* Tabs */}
            <div className="tab-bar" style={{marginBottom:'.875rem'}}>
              <button className={`tab-btn${activeTab==='feed'?' active':''}`} onClick={()=>setActiveTab('feed')}>
                Browse Feed {episodes.length>0&&`(${episodes.length})`}
              </button>
              <button className={`tab-btn${activeTab==='playlist'?' active-purple':''}`} onClick={()=>setActiveTab('playlist')}>
                Playlist {playlist.length>0&&`(${playlist.length})`}
              </button>
            </div>

            {/* Controls */}
            <div className="card-inner" style={{marginBottom:'.875rem',display:'flex',flexDirection:'column',gap:'.875rem'}}>
              <div style={{display:'flex',flexDirection:'column',gap:'.5rem'}}>
                <div style={{display:'flex',alignItems:'center',gap:'.75rem'}}>
                  <LucideIcon name="Volume2" size={16} color={bm?'#7c3aed':'#c084fc'}/>
                  <span style={{fontSize:'.7rem',fontWeight:700,color:c_sub,whiteSpace:'nowrap'}}>Pod Mix</span>
                  <input type="range" min="0" max="1" step=".01" value={podVol} className="purple"
                    disabled={NATIVE_MEDIA_VOLUME_LOCK}
                    onChange={e=>setPodVol(+e.target.value)}
                    style={{flex:1,opacity:NATIVE_MEDIA_VOLUME_LOCK ? .45 : 1}}/>
                </div>
                {NATIVE_MEDIA_VOLUME_LOCK && (
                  <div style={{fontSize:'.62rem',color:c_dim,lineHeight:1.5}}>
                    On iPhone, podcast volume follows the device media buttons so background playback stays reliable.
                  </div>
                )}
              </div>

              <div style={{borderTop:`1px solid ${c_bord}`}}/>

              <div style={{display:'flex',gap:'1.25rem',alignItems:'center'}}>
                <label style={{display:'flex',alignItems:'center',gap:'.375rem',fontSize:'.7rem',color:c_sub,cursor:'pointer'}}>
                  <input type="checkbox" checked={autoPlay} onChange={e=>setAutoPlay(e.target.checked)}/> Auto-play
                </label>
                <label style={{display:'flex',alignItems:'center',gap:'.375rem',fontSize:'.7rem',color:c_sub,cursor:'pointer'}}>
                  <input type="checkbox" checked={shuffle} onChange={e=>setShuffle(e.target.checked)}/><LucideIcon name="Shuffle" size={12}/> Shuffle
                </label>
              </div>

              <div style={{paddingTop:'.125rem'}}>
                <div style={{fontSize:'.75rem',fontWeight:600,color:c_head,marginBottom:'.25rem'}}>Background-safe playback</div>
                <div style={{fontSize:'.65rem',color:c_sub,lineHeight:1.5}}>
                  Feed episodes now use the device audio path directly so lock-screen and background playback stay reliable across more podcast hosts.
                </div>
              </div>

              <div>
                <div className="section-label">Lethargic Speed</div>
                <div style={{display:'flex',gap:'.375rem'}}>
                  {[1,.85,.75].map(s=>(
                    <button key={s} onClick={()=>setPodSpeed(s)} className={`speed-chip${podSpeed===s?' on':''}`}>
                      {s===1?'Normal':`${s}×`}
                    </button>
                  ))}
                </div>
              </div>
            </div>

            {feedErr && <p style={{color:'#f87171',fontSize:'.8rem',marginBottom:'.75rem'}}>{feedErr}</p>}
            {!feedErr && feedNote && <p style={{color:'#fbbf24',fontSize:'.78rem',marginBottom:'.75rem'}}>{feedNote}</p>}

            {activeTab==='feed' && episodes.length>0 && (
              <div style={{display:'flex',gap:'.5rem',marginBottom:'.75rem',flexWrap:'wrap'}}>
                <button onClick={()=>playEp(episodes[0], 'feed')}
                  style={{padding:'.45rem .8rem',borderRadius:'.625rem',background:'#6d28d9',color:'#fff',border:'none',fontSize:'.72rem',fontWeight:700,cursor:'pointer'}}>
                  Play Latest
                </button>
                <button onClick={()=>addEpisodesToPlaylist(episodes)}
                  style={{padding:'.45rem .8rem',borderRadius:'.625rem',background:'rgba(139,92,246,.18)',color:'#c084fc',border:`1px solid ${c_bord}`,fontSize:'.72rem',fontWeight:700,cursor:'pointer'}}>
                  Add All to Playlist
                </button>
              </div>
            )}

            {activeTab==='playlist' && (
              <div style={{display:'flex',gap:'.5rem',marginBottom:'.75rem',flexWrap:'wrap'}}>
                <button onClick={()=>playlist.length && playEp(playlist[0], 'playlist')} disabled={!playlist.length}
                  style={{padding:'.45rem .8rem',borderRadius:'.625rem',background:playlist.length?'#6d28d9':'#312e81',color:'#fff',border:'none',fontSize:'.72rem',fontWeight:700,cursor:playlist.length?'pointer':'default',opacity:playlist.length?1:.55}}>
                  Play Playlist
                </button>
                <button onClick={saveCurrentPlaylist} disabled={!playlist.length}
                  style={{padding:'.45rem .8rem',borderRadius:'.625rem',background:'rgba(139,92,246,.18)',color:playlist.length?'#c084fc':'#64748b',border:`1px solid ${c_bord}`,fontSize:'.72rem',fontWeight:700,cursor:playlist.length?'pointer':'default',opacity:playlist.length?1:.55}}>
                  Save Playlist
                </button>
                <button onClick={()=>setShowPlaylistLibrary(true)}
                  style={{padding:'.45rem .8rem',borderRadius:'.625rem',background:'transparent',color:c_sub,border:`1px solid ${c_bord}`,fontSize:'.72rem',fontWeight:700,cursor:'pointer'}}>
                  Saved Playlists
                </button>
              </div>
            )}

            {/* Episode search filter — only show when there's a list to filter */}
            {((activeTab==='feed'&&episodes.length>0)||(activeTab==='playlist'&&playlist.length>0)) && (
              <div style={{position:'relative',marginBottom:'.625rem'}}>
                <input type="text" value={epFilter} onChange={e=>setEpFilter(e.target.value)}
                  placeholder="Filter episodes…"
                  style={{width:'100%',background:c_inner,border:`1px solid ${c_bord}`,borderRadius:'.625rem',padding:'.45rem .75rem .45rem 2rem',color:c_text,fontSize:'14px'}}/>
                <span style={{position:'absolute',left:'.6rem',top:'50%',transform:'translateY(-50%)',pointerEvents:'none',color:c_dim}}>
                  <LucideIcon name="Search" size={14}/>
                </span>
                {epFilter && (
                  <button onClick={()=>setEpFilter('')}
                    style={{position:'absolute',right:'.5rem',top:'50%',transform:'translateY(-50%)',background:'none',border:'none',cursor:'pointer',color:c_dim,padding:'.2rem'}}>
                    <LucideIcon name="X" size={13}/>
                  </button>
                )}
              </div>
            )}

            {/* Episode list */}
            {activeTab==='feed'&&!episodes.length&&!loading&&!feedErr ? (
              <EmptyState text="Paste a podcast feed URL and tap Load" color={c_sub}/>
            ) : activeTab==='playlist'&&!playlist.length ? (
              <EmptyState text={"Playlist is empty.\nBrowse a feed, add episodes, or save a queue for later."} color={c_sub}/>
            ) : (
              <div className="scroll-y" style={{maxHeight:'min(420px,45dvh)',display:'flex',flexDirection:'column',gap:'.375rem'}}>
                {(activeTab==='feed'?episodes:playlist)
                  .filter(ep=>!epFilter||ep.title.toLowerCase().includes(epFilter.toLowerCase()))
                  .map((ep,idx,arr)=>{
                  const playing=curEp?.id===ep.id&&podPlaying;
                  const isExpanded=expandedEp===ep.id;
                  return (
                    <div key={ep.id}
                      draggable={activeTab==='playlist'}
                      onDragStart={()=>{ dragSrcRef.current=ep.id; }}
                      onDragEnd={()=>{ dragSrcRef.current=null; }}
                      onDragOver={e=>e.preventDefault()}
                      onDrop={()=>{
                        if(!dragSrcRef.current||dragSrcRef.current===ep.id) return;
                        setPlaylist(prev=>{
                          const from=prev.findIndex(e=>e.id===dragSrcRef.current);
                          const to=prev.findIndex(e=>e.id===ep.id);
                          if(from<0||to<0||from===to) return prev;
                          const next=[...prev];
                          const [moved]=next.splice(from,1);
                          const insertAt=from<to?to-1:to;
                          next.splice(insertAt,0,moved);
                          return next;
                        });
                        dragSrcRef.current=null;
                      }}>
                      <div className="ep-row"
                        style={{background:playing?(bm?'rgba(139,92,246,.12)':'rgba(192,132,252,.08)'):(bm?'rgba(255,255,255,.02)':'rgba(255,255,255,.02)'),
                          border:playing?`1px solid ${bm?'rgba(139,92,246,.2)':'rgba(192,132,252,.2)'}`:undefined,
                          cursor:activeTab==='playlist'?'grab':'default'}}>
                        {/* Drag handle on playlist */}
                        {activeTab==='playlist' && (
                          <span style={{color:c_dim,marginRight:'.25rem',flexShrink:0}}>
                            <LucideIcon name="GripVertical" size={14}/>
                          </span>
                        )}
                        <div style={{flex:1,minWidth:0}}>
                          <span
                            onClick={()=>setExpandedEp(isExpanded?null:ep.id)}
                            style={{display:isExpanded?'block':'-webkit-box',fontSize:'.72rem',color:playing?c_head:c_sub,
                              WebkitLineClamp:isExpanded?undefined:2,WebkitBoxOrient:'vertical',overflow:'hidden',
                              cursor:ep.description?'pointer':'default'}}>
                            {ep.title}
                          </span>
                          {ep.duration && (
                            <span style={{fontSize:'.62rem',color:c_dim,display:'block',marginTop:'.15rem'}}>{ep.duration}</span>
                          )}
                          {isExpanded && ep.description && (
                            <p style={{margin:'.375rem 0 0',fontSize:'.68rem',color:c_sub,lineHeight:1.5}}>
                              {ep.description}
                            </p>
                          )}
                        </div>
                        <div style={{display:'flex',gap:'.375rem',flexShrink:0}}>

                          {/* Download Button */}
                          <button onClick={() => {
                            if (cachedEpisodes[ep.url]) deleteEpisode(ep.url);
                            else downloadEpisode(ep.url);
                          }} className="btn-icon"
                            style={{width:36,height:36,minWidth:36,minHeight:36,
                              background:'transparent', color: cachedEpisodes[ep.url] ? '#38bdf8' : c_dim}}>
                            {downloadProgress[ep.url] ? (
                              <span style={{fontSize:'10px',fontWeight:'bold'}}>...</span>
                            ) : (
                              <LucideIcon name={cachedEpisodes[ep.url] ? 'Check' : 'Download'} size={15}/>
                            )}
                          </button>

                          {activeTab==='feed' ? (
                            <button onClick={()=>addToPlaylist(ep)} className="btn-icon"
                              style={{width:36,height:36,minWidth:36,minHeight:36,
                                color:playlist.find(p=>p.id===ep.id)?'#4ade80':c_sub,
                                background:playlist.find(p=>p.id===ep.id)?'rgba(74,222,128,.12)':'transparent'}}>
                              <LucideIcon name="Plus" size={15}/>
                            </button>
                          ) : (
                            <button onClick={()=>removeFromPlaylist(ep.id)} className="btn-icon"
                              style={{width:36,height:36,minWidth:36,minHeight:36,background:'transparent',color:c_sub}}>
                              <LucideIcon name="X" size={15}/>
                            </button>
                          )}
                          <button onClick={()=>playEp(ep,activeTab)}
                            className={`btn-icon${playing?' active-purple':''}`}
                            style={{width:36,height:36,minWidth:36,minHeight:36,
                              ...(playing?{background:'rgba(192,132,252,.2)',color:'#c084fc'}:{})}}>
                            <LucideIcon name={playing?'Pause':'Play'} size={15}/>
                          </button>
                        </div>
                      </div>
                      {curEp?.id===ep.id && (
                        <div style={{display:'flex',justifyContent:'flex-end',gap:'.375rem',padding:'.25rem .375rem .375rem'}}>
                          {[{s:-15,icon:'RotateCcw'},{s:15,icon:'RotateCw'}].map(({s,icon})=>(
                            <button key={s} onClick={()=>skipPod(s)}
                              style={{display:'flex',alignItems:'center',gap:'.25rem',padding:'.375rem .625rem',borderRadius:'.5rem',
                                background:bm?'rgba(255,255,255,.04)':'rgba(192,132,252,.08)',
                                color:bm?'#6b7280':'#c084fc',border:'none',cursor:'pointer',fontSize:'.7rem'}}>
                              <LucideIcon name={icon} size={13}/>{Math.abs(s)}s
                            </button>
                          ))}
                        </div>
                      )}
                    </div>
                  );
                })}
              </div>
            )}
          </div>

          {/* Install hint */}
          <div style={{textAlign:'center',fontSize:'.7rem',color:c_sub,padding:'.5rem 0 .25rem',lineHeight:1.7}}>
            <p style={{margin:0}}><strong style={{color:c_sub}}>iPhone:</strong> Safari → Share → "Add to Home Screen"</p>
            <p style={{margin:0}}><strong style={{color:c_sub}}>Android:</strong> Chrome → ⋮ → "Add to Home Screen"</p>
          </div>

        </div>
      </div>
    </div>
  );
}

function EmptyState({text,color}) {
  return (
    <div style={{textAlign:'center',padding:'2rem 1rem',color,display:'flex',flexDirection:'column',alignItems:'center',gap:'.75rem'}}>
      <svg width="36" height="36" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" opacity=".3">
        <path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/>
      </svg>
      <p style={{margin:0,fontSize:'.8rem',whiteSpace:'pre-line'}}>{text}</p>
    </div>
  );
}

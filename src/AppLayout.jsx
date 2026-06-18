import React from 'react';
import { useAppContext } from './context/AppContext.jsx';
import { fmtTime, NOISE_TYPES, BINAURAL, isStandaloneWebApp } from './utils/core.js';
import LucideIcon from './components/LucideIcon.jsx';
import SleepTimer from './components/SleepTimer.jsx';
import MixerPanel from './components/MixerPanel.jsx';
import Header from './components/Header.jsx';
import AmbientBinaural from './components/AmbientBinaural.jsx';
import NowPlayingBar from './components/NowPlayingBar.jsx';
import PodcastScreen from './components/PodcastScreen.jsx';

export default function AppLayout() {
  const {
    bm, breathMode, setBreathMode, episodes,
    playlist, savedPlaylists, setSavedPlaylists, showPlaylistLibrary,
    setShowPlaylistLibrary, playlistName, setPlaylistName, label,
    sub, m, entry, saveCurrentPlaylist,
    name, loadSavedPlaylist, p, bc,
    c_text, c_sub, c_dim, c_head,
    c_bord, c_inner,
    lastMix, resumeLastMix, ambientOn, binOn,
  } = useAppContext() || {};

  // Standalone (installed PWA) is computed once — the install hint is noise then.
  const standalone = isStandaloneWebApp();
  // One-tap "Resume" the last mix: only when nothing's already playing.
  const showResume = lastMix && (lastMix.ambient || lastMix.bin) && !ambientOn && !binOn;
  const resumeLabel = showResume ? [
    lastMix.ambient && NOISE_TYPES[lastMix.noiseType]?.label.split(' (')[0],
    lastMix.bin && BINAURAL[lastMix.binPreset]?.name,
  ].filter(Boolean).join(' + ') : '';

  const [showPodcasts, setShowPodcasts] = React.useState(false);

  return (
    <div className="app-container">
      <div className="mesh-bg" />

      {/* ── Breathing overlay ── */}
      {breathMode && bc && (
        <div className="overlay" className="overlay-content centered">
          <button onClick={()=>setBreathMode(null)}
            className="btn-icon header-btn">
            <LucideIcon name="X" size={20}/>
          </button>
          <div className="flex-row gap-md" style={{marginBottom: "2rem"}}>
            {['478','box'].map(m=>(
              <button key={m} onClick={()=>setBreathMode(m)}
                style={{padding:'.5rem 1.25rem',borderRadius:'9999px',border:'none',fontWeight:700,fontSize:'.8rem',cursor:'pointer',
                  background:breathMode===m?(bm?'#2a2114':'var(--c-accent-strong)'):(bm?'#111':'var(--c-btn)'),
                  color:breathMode===m?'#fff':(bm?'#8a7860':'#b39b80')}}>
                {m==='478'?'4-7-8':'Box 4-4-4-4'}
              </button>
            ))}
          </div>
          <h2 className="breath-title" style={{color:bm?'#b39b80':bc.col}}>{bc.label}</h2>
          <p className="breath-sub">{bc.sub}</p>
          <div className="breath-circle-container">
            <div className="breath-circle-bg" style={{background: bc.col}}/>
            <div className={`${bc.cls} breath-circle-pulse`} style={{background: bc.col, boxShadow: bm ? "none" : `0 0 60px ${bc.col}40`}}/>
          </div>
        </div>
      )}

      {showPlaylistLibrary && (
        <div className="overlay" style={{background:bm?'#000':'var(--c-bg)',paddingTop:'var(--top-clearance)'}}>
          <div style={{display:'flex',alignItems:'center',justifyContent:'space-between',padding:'1.25rem'}}>
            <h2 className="text-title" style={{color: c_head}}>Saved Playlists</h2>
            <button onClick={()=>setShowPlaylistLibrary(false)}
              className="btn-icon header-btn">
              <LucideIcon name="X" size={18}/>
            </button>
          </div>

          <div className="card" className="panel anim-fade-in">
            <p className="text-dim" style={{marginBottom: "0.5rem"}}>Save the current queue under a reusable name.</p>
            <div style={{display:'flex',gap:'.5rem'}}>
              <input type="text" value={playlistName} onChange={e=>setPlaylistName(e.target.value)} placeholder="Playlist name…"
                style={{flex:1,background:c_inner,border:`1px solid ${c_bord}`,borderRadius:'.5rem',padding:'.5rem .75rem',color:c_text,fontSize:'14px'}}/>
              <button onClick={saveCurrentPlaylist} disabled={!playlist.length}
                style={{padding:'.5rem 1rem',borderRadius:'.5rem',background:playlist.length?'var(--c-accent-strong)':'#4a3a1e',color:playlist.length?'var(--c-bg)':'#fff',border:'none',fontWeight:700,cursor:playlist.length?'pointer':'default',whiteSpace:'nowrap',opacity:playlist.length?1:.55}}>
                Save
              </button>
            </div>
          </div>

          <div className="scroll-y" style={{flex:1,padding:'0 1rem',display:'flex',flexDirection:'column',gap:'.5rem'}}>
            {savedPlaylists.length===0 && <p style={{textAlign:'center',padding:'2rem',color:c_sub,fontSize:'.85rem'}}>No saved playlists yet.</p>}
            {savedPlaylists.map(saved => (
              <div key={saved.id || saved.name} className="card" className="panel-row">
                <div style={{flex:1,minWidth:0}}>
                  <p className="text-sub" style={{fontWeight: 600, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", color: c_head}}>{saved.name}</p>
                  <p className="text-dim">
                    {(saved.count || saved.episodes?.length || 0)} episode{(saved.count || saved.episodes?.length || 0)===1?'':'s'}
                    {saved.updatedAt ? ` · Updated ${new Date(saved.updatedAt).toLocaleDateString()}` : ''}
                  </p>
                </div>
                <button onClick={()=>loadSavedPlaylist(saved)}
                  className="btn-pill-sub">
                  Load
                </button>
                <button onClick={()=>loadSavedPlaylist(saved, { autoplay: true })}
                  className="btn-pill-main">
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
      <div className="pad-top pad-bottom anim-fade-in" style={{maxWidth: 500, margin: "0 auto", paddingLeft: "1rem", paddingRight: "1rem"}}>

        {/* Header */}
        <Header />

        {/* One-tap nightly resume — the 95% case, at the very top so you can
            open → tap → let the screen go dark. */}
        {showResume && (
          <button onClick={resumeLastMix} aria-label={`Resume ${resumeLabel}`}
            className="btn-resume-mix">
            <span style={{width:46,height:46,flexShrink:0,borderRadius:'50%',display:'flex',alignItems:'center',justifyContent:'center',
              background:bm?'#1a1305':'rgba(230,178,119,0.2)',color:'#e6b277'}}>
              <LucideIcon name="Play" size={22}/>
            </span>
            <span style={{flex:1,minWidth:0}}>
              <span style={{display:'block',fontSize:'.62rem',fontWeight:700,letterSpacing:'.08em',textTransform:'uppercase',color:'#e6b277',marginBottom:'.15rem'}}>Resume last night</span>
              <span style={{display:'block',fontSize:'.95rem',fontWeight:700,color:c_head,overflow:'hidden',textOverflow:'ellipsis',whiteSpace:'nowrap'}}>
                {resumeLabel}{lastMix.useTimer ? ` · ${lastMix.timerMins} min timer` : ''}
              </span>
            </span>
          </button>
        )}

        <NowPlayingBar onOpen={()=>setShowPodcasts(true)} compact />

        <div style={{display:'flex',flexDirection:'column',gap:'1rem'}}>

          {/* Sounds — the primary choice, first */}
          <AmbientBinaural />

          {/* Sleep Timer */}
          <SleepTimer />

          {/* Master volume + saved mixes */}
          <MixerPanel />

          {/* Podcasts entry — opens the podcast screen */}
          <button onClick={()=>setShowPodcasts(true)} className="panel-row" style={{width: "100%"}}>
            <span style={{display:'flex',alignItems:'center',gap:'.6rem',fontWeight:700,fontSize:'1rem',color:c_head}}>
              <LucideIcon name="Rss" size={20} color={bm?'#a9762f':'#e6b277'}/> Podcasts
            </span>
            <span style={{display:'flex',alignItems:'center',gap:'.5rem',color:c_sub,fontSize:'.85rem'}}>
              Browse &amp; play
              <span style={{fontSize:'1.3rem',lineHeight:1,color:c_dim}}>›</span>
            </span>
          </button>

          {/* Install hint — only before the app is installed (it's noise once
              you're running standalone). Build stamp moved to Podcast settings. */}
          {!standalone && (
            <div style={{textAlign:'center',fontSize:'.7rem',color:c_sub,padding:'.5rem 0 .25rem',lineHeight:1.7}}>
              <p style={{margin:0}}><strong style={{color:c_sub}}>iPhone:</strong> Safari → Share → "Add to Home Screen"</p>
              <p style={{margin:0}}><strong style={{color:c_sub}}>Android:</strong> Chrome → ⋮ → "Add to Home Screen"</p>
            </div>
          )}
        </div>

        <PodcastScreen show={showPodcasts} onClose={()=>setShowPodcasts(false)} />
      </div>
    </div>
  );
}

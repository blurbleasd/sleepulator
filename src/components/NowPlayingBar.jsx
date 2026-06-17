import React from 'react';
import { Play, Pause } from 'lucide-react';
import { useAppContext } from '../context/AppContext.jsx';
import { fmtTime } from '../utils/core.js';

// Home-screen / podcast player. `compact` (home) shows a thin NON-interactive
// progress bar — a stray thumb in the dark shouldn't jump playback to a random
// timestamp. Full scrubbing lives in the Podcast screen (compact=false). Tapping
// the title opens the Podcasts screen (onOpen). Renders nothing with no episode.
export default function NowPlayingBar({ onOpen, compact = false }) {
  const { curEp, podPlaying, podProgress, podAudio, c_head, c_sub } = useAppContext() || {};
  if (!curEp) return null;

  const cur = podProgress?.cur || 0;
  const dur = podProgress?.dur || 0;
  const toggle = () => {
    const a = podAudio?.current;
    if (!a) return;
    if (podPlaying) a.pause();
    else a.play().catch(() => {});
  };

  return (
    <div className="card" style={{display:'flex',flexDirection:'column',gap:'.6rem',padding:'.9rem 1rem',marginBottom:'1rem'}}>
      <div style={{display:'flex',alignItems:'center',gap:'.75rem'}}>
        <button onClick={toggle} className="btn-icon" aria-label={podPlaying ? 'Pause' : 'Play'} style={{flexShrink:0}}>
          {podPlaying ? <Pause size={20}/> : <Play size={20}/>}
        </button>
        <button onClick={onOpen} style={{flex:1,minWidth:0,textAlign:'left',background:'transparent',border:'none',cursor:'pointer',padding:0}}>
          <div style={{fontSize:'.6rem',fontWeight:700,letterSpacing:'.07em',textTransform:'uppercase',color:'#e6b277',marginBottom:'.1rem'}}>
            {podPlaying ? 'Now playing' : 'Paused'}
          </div>
          <div style={{fontSize:'.85rem',color:c_head,lineHeight:1.3,overflow:'hidden',textOverflow:'ellipsis',whiteSpace:'nowrap'}}>
            {curEp.title}
          </div>
        </button>
      </div>
      <div style={{display:'flex',alignItems:'center',gap:'.5rem'}}>
        <span style={{fontSize:'.6rem',color:c_sub,fontFamily:'monospace',width:36,textAlign:'right'}}>{fmtTime(cur)}</span>
        {compact ? (
          <div style={{flex:1,height:4,borderRadius:2,background:'rgba(255,255,255,0.1)',overflow:'hidden'}}>
            <div style={{height:'100%',width:`${dur>0?Math.min(100,(cur/dur)*100):0}%`,background:'var(--c-accent)',borderRadius:2,transition:'width .3s linear'}}/>
          </div>
        ) : (
          <input type="range" min={0} max={dur||1} step={1} value={cur} className="purple"
            onChange={e=>{ if (podAudio?.current) podAudio.current.currentTime = +e.target.value; }}
            style={{flex:1}}/>
        )}
        <span style={{fontSize:'.6rem',color:c_sub,fontFamily:'monospace',width:36}}>{dur>0 ? fmtTime(dur) : '--:--'}</span>
      </div>
    </div>
  );
}

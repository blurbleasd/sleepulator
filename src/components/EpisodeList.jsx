import React, { useState, useEffect } from 'react';
import { useAppContext } from '../context/AppContext.jsx';
import LucideIcon from './LucideIcon.jsx';

const PAGE = 40; // render episodes a chunk at a time — long feeds were janky

// A clean, reusable list of episode rows. `mode` is 'feed' (a podcast's
// episodes: tap + to queue) or 'queue' (the Up-Next list: reorder + remove).
// No filter or playback controls here — those live in Settings, so the list
// stays uncluttered.
export default function EpisodeList({ list, mode = 'feed', emptyText = 'Nothing here yet.' }) {
  const {
    bm, c_head, c_sub, c_dim,
    curEp, podPlaying, playEp, skipPod,
    playlist, setPlaylist, addToPlaylist, removeFromPlaylist,
    cachedEpisodes, deleteEpisode, downloadEpisode, downloadProgress,
  } = useAppContext() || {};
  const [expandedEp, setExpandedEp] = useState(null);
  const [visible, setVisible] = useState(PAGE);
  // Reset the window whenever the list changes (e.g. opening a different feed).
  useEffect(() => { setVisible(PAGE); }, [list]);

  const moveEp = (id, dir) => setPlaylist(prev => {
    const i = prev.findIndex(e => e.id === id);
    const j = i + dir;
    if (i < 0 || j < 0 || j >= prev.length) return prev;
    const next = [...prev];
    [next[i], next[j]] = [next[j], next[i]];
    return next;
  });

  if (!list || !list.length) {
    return (
      <div style={{textAlign:'center',padding:'2.5rem 1rem',color:c_sub,display:'flex',flexDirection:'column',alignItems:'center',gap:'.75rem'}}>
        <svg width="36" height="36" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" opacity=".3">
          <path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/>
        </svg>
        <p style={{margin:0,fontSize:'.82rem',whiteSpace:'pre-line'}}>{emptyText}</p>
      </div>
    );
  }

  return (
    <div className="scroll-y" style={{display:'flex',flexDirection:'column',gap:'.375rem'}}>
      {list.slice(0, visible).map(ep => {
        const playing = curEp?.id === ep.id && podPlaying;
        const isExpanded = expandedEp === ep.id;
        const inQueue = playlist.find(p => p.id === ep.id);
        const pi = mode === 'queue' ? list.findIndex(e => e.id === ep.id) : -1;
        return (
          <div key={ep.id}>
            <div className="ep-row"
              style={{background:playing?'rgba(230,178,119,.08)':'rgba(255,255,255,.02)',
                border:playing?'1px solid rgba(230,178,119,.2)':undefined}}>
              {mode === 'queue' && (
                <div style={{display:'flex',flexDirection:'column',marginRight:'.25rem',flexShrink:0}}>
                  <button aria-label="Move up" disabled={pi<=0} onClick={()=>moveEp(ep.id,-1)}
                    style={{background:'transparent',border:'none',cursor:pi<=0?'default':'pointer',color:c_dim,padding:0,opacity:pi<=0?.3:1,lineHeight:0}}>
                    <LucideIcon name="ChevronUp" size={16}/>
                  </button>
                  <button aria-label="Move down" disabled={pi>=list.length-1} onClick={()=>moveEp(ep.id,1)}
                    style={{background:'transparent',border:'none',cursor:pi>=list.length-1?'default':'pointer',color:c_dim,padding:0,opacity:pi>=list.length-1?.3:1,lineHeight:0}}>
                    <LucideIcon name="ChevronDown" size={16}/>
                  </button>
                </div>
              )}
              <div style={{flex:1,minWidth:0}}>
                <span onClick={()=>setExpandedEp(isExpanded?null:ep.id)}
                  style={{display:isExpanded?'block':'-webkit-box',fontSize:'.78rem',color:playing?c_head:c_sub,
                    WebkitLineClamp:isExpanded?undefined:2,WebkitBoxOrient:'vertical',overflow:'hidden',
                    cursor:ep.description?'pointer':'default'}}>
                  {ep.title}
                </span>
                {ep.duration && (
                  <span style={{fontSize:'.62rem',color:c_dim,display:'block',marginTop:'.15rem'}}>{ep.duration}</span>
                )}
                {isExpanded && ep.description && (
                  <p style={{margin:'.375rem 0 0',fontSize:'.7rem',color:c_sub,lineHeight:1.5}}>{ep.description}</p>
                )}
              </div>
              <div style={{display:'flex',gap:'.375rem',flexShrink:0}}>
                <button onClick={()=>{ cachedEpisodes[ep.url] ? deleteEpisode(ep.url) : downloadEpisode(ep.url); }}
                  className="btn-icon" aria-label={cachedEpisodes[ep.url] ? 'Downloaded' : 'Download'}
                  style={{width:38,height:38,minWidth:38,minHeight:38,background:'transparent',color:cachedEpisodes[ep.url]?'#e6b277':c_dim}}>
                  {downloadProgress[ep.url]
                    ? <span style={{fontSize:'10px',fontWeight:'bold'}}>…</span>
                    : <LucideIcon name={cachedEpisodes[ep.url] ? 'Check' : 'Download'} size={16}/>}
                </button>
                {mode === 'feed' ? (
                  <button onClick={()=>addToPlaylist(ep)} className="btn-icon" aria-label="Add to queue"
                    style={{width:38,height:38,minWidth:38,minHeight:38,color:inQueue?'#4ade80':c_sub,background:inQueue?'rgba(74,222,128,.12)':'transparent'}}>
                    <LucideIcon name={inQueue ? 'Check' : 'Plus'} size={16}/>
                  </button>
                ) : (
                  <button onClick={()=>removeFromPlaylist(ep.id)} className="btn-icon" aria-label="Remove from queue"
                    style={{width:38,height:38,minWidth:38,minHeight:38,background:'transparent',color:c_sub}}>
                    <LucideIcon name="X" size={16}/>
                  </button>
                )}
                <button onClick={()=>playEp(ep, mode === 'queue' ? 'playlist' : 'feed')}
                  className={`btn-icon${playing?' active-purple':''}`} aria-label={playing ? 'Pause' : 'Play'}
                  style={{width:38,height:38,minWidth:38,minHeight:38,...(playing?{background:'rgba(230,178,119,.2)',color:'#e6b277'}:{})}}>
                  <LucideIcon name={playing ? 'Pause' : 'Play'} size={16}/>
                </button>
              </div>
            </div>
            {playing && (
              <div style={{display:'flex',justifyContent:'flex-end',gap:'.375rem',padding:'.25rem .375rem .375rem'}}>
                {[{s:-15,icon:'RotateCcw'},{s:15,icon:'RotateCw'}].map(({s,icon})=>(
                  <button key={s} onClick={()=>skipPod(s)}
                    style={{display:'flex',alignItems:'center',gap:'.25rem',padding:'.375rem .625rem',borderRadius:'.5rem',
                      background:bm?'rgba(255,255,255,.04)':'rgba(230,178,119,.08)',color:bm?'#8a7860':'#e6b277',border:'none',cursor:'pointer',fontSize:'.7rem'}}>
                    <LucideIcon name={icon} size={13}/>{Math.abs(s)}s
                  </button>
                ))}
              </div>
            )}
          </div>
        );
      })}
      {visible < list.length && (
        <button onClick={()=>setVisible(v => v + PAGE)} className="btn-pill"
          style={{margin:'.5rem auto 0',padding:'.6rem 1.2rem'}}>
          Load more ({list.length - visible} left)
        </button>
      )}
    </div>
  );
}


import React, { useState } from 'react';
import { useAppContext } from '../context/AppContext.jsx';
import { NATIVE_MEDIA_VOLUME_LOCK } from '../utils/core.js';
import LucideIcon from './LucideIcon.jsx';

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

// Tabs (Browse Feed / Playlist), pod-mix + playback controls, episode filter,
// and the episode list with drag-and-drop reordering on the playlist.
// Extracted from AppLayout; reads everything from context.
export default function EpisodeBrowser() {
  const {
    episodes, playlist,
    bm, c_head, c_sub, c_dim, c_bord, c_inner, c_text,
    podVol, setPodVol, autoPlay, setAutoPlay, shuffle, setShuffle, podSpeed, setPodSpeed,
    preloadNext, setPreloadNext,
    feedErr, feedNote, loading,
    playEp, addEpisodesToPlaylist, saveCurrentPlaylist, setShowPlaylistLibrary,
    curEp, podPlaying,
    dragSrcRef, setPlaylist,
    cachedEpisodes, deleteEpisode, downloadEpisode, downloadProgress,
    addToPlaylist, removeFromPlaylist, skipPod,
  } = useAppContext() || {};

  // Browser-local view state — used only here, so it lives here rather than in
  // the global context (first step of de-monolithing AppContext).
  const [activeTab, setActiveTab] = useState('feed');
  const [expandedEp, setExpandedEp] = useState(null);
  const [epFilter, setEpFilter] = useState('');

  // Swap a playlist item with its neighbour. Drives the up/down reorder buttons,
  // which work on touch (unlike native HTML5 drag-and-drop, which iOS ignores).
  const moveEp = (id, dir) => setPlaylist(prev => {
    const i = prev.findIndex(e => e.id === id);
    const j = i + dir;
    if (i < 0 || j < 0 || j >= prev.length) return prev;
    const next = [...prev];
    [next[i], next[j]] = [next[j], next[i]];
    return next;
  });

  return (
    <>
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
                  <LucideIcon name="Volume2" size={16} color={bm?'#a9762f':'#e6b277'}/>
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
                <label style={{display:'flex',alignItems:'center',gap:'.375rem',fontSize:'.7rem',color:c_sub,cursor:'pointer'}} title="Download the next episode ahead of time so it starts instantly (uses data)">
                  <input type="checkbox" checked={preloadNext} onChange={e=>setPreloadNext(e.target.checked)}/> Preload next
                </label>
              </div>

              <div style={{paddingTop:'.125rem'}}>
                <div style={{fontSize:'.75rem',fontWeight:600,color:c_head,marginBottom:'.25rem'}}>Background-safe playback</div>
                <div style={{fontSize:'.65rem',color:c_sub,lineHeight:1.5}}>
                  Feed episodes now use the device audio path directly so lock-screen and background playback stay reliable across more podcast hosts.
                </div>
              </div>

              <div>
                <div className="section-label">Playback speed</div>
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
                  style={{padding:'.45rem .8rem',borderRadius:'.625rem',background:'#b8813a',color:'#fff',border:'none',fontSize:'.72rem',fontWeight:700,cursor:'pointer'}}>
                  Play Latest
                </button>
                <button onClick={()=>addEpisodesToPlaylist(episodes)}
                  style={{padding:'.45rem .8rem',borderRadius:'.625rem',background:'rgba(230,178,119,.18)',color:'#e6b277',border:`1px solid ${c_bord}`,fontSize:'.72rem',fontWeight:700,cursor:'pointer'}}>
                  Add All to Playlist
                </button>
              </div>
            )}

            {activeTab==='playlist' && (
              <div style={{display:'flex',gap:'.5rem',marginBottom:'.75rem',flexWrap:'wrap'}}>
                <button onClick={()=>playlist.length && playEp(playlist[0], 'playlist')} disabled={!playlist.length}
                  style={{padding:'.45rem .8rem',borderRadius:'.625rem',background:playlist.length?'#b8813a':'#4a3a1e',color:'#fff',border:'none',fontSize:'.72rem',fontWeight:700,cursor:playlist.length?'pointer':'default',opacity:playlist.length?1:.55}}>
                  Play Playlist
                </button>
                <button onClick={saveCurrentPlaylist} disabled={!playlist.length}
                  style={{padding:'.45rem .8rem',borderRadius:'.625rem',background:'rgba(230,178,119,.18)',color:playlist.length?'#e6b277':'#8a7860',border:`1px solid ${c_bord}`,fontSize:'.72rem',fontWeight:700,cursor:playlist.length?'pointer':'default',opacity:playlist.length?1:.55}}>
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
                        style={{background:playing?(bm?'rgba(230,178,119,.12)':'rgba(230,178,119,.08)'):(bm?'rgba(255,255,255,.02)':'rgba(255,255,255,.02)'),
                          border:playing?`1px solid ${bm?'rgba(230,178,119,.2)':'rgba(230,178,119,.2)'}`:undefined,
                          cursor:activeTab==='playlist'?'grab':'default'}}>
                        {/* Reorder controls on playlist (touch-friendly; native
                            drag is kept above for desktop). Hidden while filtering,
                            since order is ambiguous against a filtered subset. */}
                        {activeTab==='playlist' && !epFilter && (() => {
                          const pi = playlist.findIndex(e=>e.id===ep.id);
                          return (
                            <div style={{display:'flex',flexDirection:'column',marginRight:'.25rem',flexShrink:0}}>
                              <button aria-label="Move up" disabled={pi<=0} onClick={()=>moveEp(ep.id,-1)}
                                style={{background:'transparent',border:'none',cursor:pi<=0?'default':'pointer',color:c_dim,padding:0,opacity:pi<=0?.3:1,lineHeight:0}}>
                                <LucideIcon name="ChevronUp" size={16}/>
                              </button>
                              <button aria-label="Move down" disabled={pi>=playlist.length-1} onClick={()=>moveEp(ep.id,1)}
                                style={{background:'transparent',border:'none',cursor:pi>=playlist.length-1?'default':'pointer',color:c_dim,padding:0,opacity:pi>=playlist.length-1?.3:1,lineHeight:0}}>
                                <LucideIcon name="ChevronDown" size={16}/>
                              </button>
                            </div>
                          );
                        })()}
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
                              background:'transparent', color: cachedEpisodes[ep.url] ? '#e6b277' : c_dim}}>
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
                              ...(playing?{background:'rgba(230,178,119,.2)',color:'#e6b277'}:{})}}>
                            <LucideIcon name={playing?'Pause':'Play'} size={15}/>
                          </button>
                        </div>
                      </div>
                      {curEp?.id===ep.id && (
                        <div style={{display:'flex',justifyContent:'flex-end',gap:'.375rem',padding:'.25rem .375rem .375rem'}}>
                          {[{s:-15,icon:'RotateCcw'},{s:15,icon:'RotateCw'}].map(({s,icon})=>(
                            <button key={s} onClick={()=>skipPod(s)}
                              style={{display:'flex',alignItems:'center',gap:'.25rem',padding:'.375rem .625rem',borderRadius:'.5rem',
                                background:bm?'rgba(255,255,255,.04)':'rgba(230,178,119,.08)',
                                color:bm?'#8a7860':'#e6b277',border:'none',cursor:'pointer',fontSize:'.7rem'}}>
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
    </>
  );
}

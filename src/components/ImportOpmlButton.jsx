import React, { useState, useRef } from 'react';
import { useAppContext } from '../context/AppContext.jsx';
import { parseOpmlFeeds, deriveFeedName } from '../utils/core.js';

// Import subscriptions from an OPML file exported by another podcast app
// (Overcast: overcast.fm/account -> Export -> OPML; Apple Podcasts; Pocket
// Casts; etc.). The file usually contains far more feeds than the user wants
// here, so parsed feeds are shown as a checklist to pick from before importing.
export default function ImportOpmlButton() {
  const { upsertFeedSub, c_head, c_sub, c_bord, c_inner } = useAppContext() || {};
  const [feeds, setFeeds] = useState(null);   // parsed [{url,name}] awaiting selection, or null
  const [picked, setPicked] = useState(() => new Set());
  const [msg, setMsg] = useState(null);
  const inputRef = useRef(null);

  const onFile = (e) => {
    const file = e.target.files?.[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = (ev) => {
      const parsed = parseOpmlFeeds(String(ev.target?.result || ''));
      if (!parsed.length) { setMsg('No feeds found in that file.'); setFeeds(null); return; }
      setMsg(null);
      setFeeds(parsed);
      setPicked(new Set(parsed.map((f) => f.url))); // default: all selected
    };
    reader.onerror = () => setMsg('Could not read that file.');
    reader.readAsText(file);
    e.target.value = '';
  };

  const toggle = (url) => setPicked((prev) => {
    const next = new Set(prev);
    if (next.has(url)) next.delete(url); else next.add(url);
    return next;
  });
  const setAll = (on) => setPicked(on ? new Set(feeds.map((f) => f.url)) : new Set());

  const doImport = () => {
    const chosen = feeds.filter((f) => picked.has(f.url));
    chosen.forEach((f) => upsertFeedSub?.({ url: f.url, name: f.name }));
    setMsg(`Imported ${chosen.length} feed${chosen.length === 1 ? '' : 's'}.`);
    setFeeds(null);
    setPicked(new Set());
  };

  if (!feeds) {
    return (
      <div style={{display:'flex',flexDirection:'column',gap:'.4rem'}}>
        <button type="button" className="btn-pill" style={{textAlign:'center',cursor:'pointer',padding:'.6rem'}}
          onClick={()=>inputRef.current?.click()}>
          Import from OPML (Overcast, etc.)
        </button>
        {/* No accept filter: iOS has no registered type for .opml, so any
            restriction greys the file out. We validate by parsing instead.
            Off-screen (not display:none) so the picker reliably opens on iOS. */}
        <input ref={inputRef} type="file" onChange={onFile}
          style={{position:'absolute',width:1,height:1,opacity:0,overflow:'hidden',pointerEvents:'none'}} />
        {msg && <div style={{fontSize:'.7rem',color:c_sub,textAlign:'center',lineHeight:1.5}}>{msg}</div>}
      </div>
    );
  }

  return (
    <div style={{display:'flex',flexDirection:'column',gap:'.6rem'}}>
      <div style={{display:'flex',alignItems:'center',justifyContent:'space-between'}}>
        <span style={{fontSize:'.75rem',fontWeight:700,color:c_head}}>Choose feeds to import ({picked.size}/{feeds.length})</span>
        <div style={{display:'flex',gap:'.75rem'}}>
          <button onClick={()=>setAll(true)} style={{background:'transparent',border:'none',color:'#e6b277',fontSize:'.7rem',fontWeight:700,cursor:'pointer'}}>All</button>
          <button onClick={()=>setAll(false)} style={{background:'transparent',border:'none',color:c_sub,fontSize:'.7rem',fontWeight:700,cursor:'pointer'}}>None</button>
        </div>
      </div>

      <div className="scroll-y" style={{maxHeight:260,display:'flex',flexDirection:'column',gap:'.25rem',border:`1px solid ${c_bord}`,borderRadius:'.625rem',padding:'.4rem',background:c_inner}}>
        {feeds.map((f) => (
          <label key={f.url} style={{display:'flex',alignItems:'center',gap:'.6rem',padding:'.45rem .35rem',cursor:'pointer',minWidth:0}}>
            <input type="checkbox" checked={picked.has(f.url)} onChange={()=>toggle(f.url)} style={{flexShrink:0}}/>
            <span style={{minWidth:0,overflow:'hidden'}}>
              <span style={{display:'block',fontSize:'.8rem',color:c_head,overflow:'hidden',textOverflow:'ellipsis',whiteSpace:'nowrap'}}>{f.name || deriveFeedName(f.url)}</span>
              <span style={{display:'block',fontSize:'.62rem',color:c_sub,overflow:'hidden',textOverflow:'ellipsis',whiteSpace:'nowrap'}}>{f.url}</span>
            </span>
          </label>
        ))}
      </div>

      <div style={{display:'flex',gap:'.5rem'}}>
        <button onClick={doImport} disabled={!picked.size} className="btn-pill"
          style={{flex:1,padding:'.6rem',opacity:picked.size?1:.5,cursor:picked.size?'pointer':'default'}}>
          Import {picked.size} selected
        </button>
        <button onClick={()=>{ setFeeds(null); setPicked(new Set()); }} className="btn-pill" style={{padding:'.6rem 1rem'}}>
          Cancel
        </button>
      </div>
    </div>
  );
}

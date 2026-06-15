import React, { useState } from 'react';
import { useAppContext } from '../context/AppContext.jsx';
import { parseOpmlFeeds } from '../utils/core.js';

// Import subscriptions from an OPML file exported by another podcast app
// (Overcast: overcast.fm/account -> Export -> OPML; Apple Podcasts; Pocket
// Casts; etc.). Each feed is added to Saved Feeds via upsertFeedSub.
export default function ImportOpmlButton() {
  const { upsertFeedSub, c_sub } = useAppContext() || {};
  const [msg, setMsg] = useState(null);

  const onFile = (e) => {
    const file = e.target.files?.[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = (ev) => {
      const feeds = parseOpmlFeeds(String(ev.target?.result || ''));
      feeds.forEach((f) => upsertFeedSub?.({ url: f.url, name: f.name }));
      setMsg(feeds.length
        ? `Imported ${feeds.length} feed${feeds.length === 1 ? '' : 's'}.`
        : 'No feeds found in that file.');
    };
    reader.onerror = () => setMsg('Could not read that file.');
    reader.readAsText(file);
    e.target.value = '';
  };

  return (
    <div style={{display:'flex',flexDirection:'column',gap:'.4rem'}}>
      <label className="btn-pill" style={{textAlign:'center',cursor:'pointer',padding:'.6rem'}}>
        Import from OPML (Overcast, etc.)
        <input type="file" accept=".opml,.xml,text/xml,application/xml,text/x-opml" onChange={onFile} style={{display:'none'}} />
      </label>
      {msg && <div style={{fontSize:'.7rem',color:c_sub,textAlign:'center',lineHeight:1.5}}>{msg}</div>}
    </div>
  );
}

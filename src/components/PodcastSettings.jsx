import React from 'react';
import { useAppContext } from '../context/AppContext.jsx';
import { normalizeConfigUrl, getDefaultFeedProxyUrl } from '../utils/core.js';
import FeedDebugPanel from './FeedDebugPanel.jsx';

// Injected by Vite at build time (vite.config.js). typeof guard keeps it safe
// under tests/dev where the define isn't applied.
const BUILD_ID = typeof __BUILD_ID__ !== 'undefined' ? __BUILD_ID__ : 'dev';

// Dump all of localStorage to a downloadable JSON backup.
function handleExportData() {
  const data = JSON.stringify(localStorage);
  const blob = new Blob([data], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `sleepulator-backup-${new Date().toISOString().split('T')[0]}.json`;
  a.click();
  URL.revokeObjectURL(url);
}

// Restore settings from a previously exported backup file.
function handleImportData(e) {
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
}

// Podcast connection settings: private feed proxy, Sleep Safe audio proxy,
// backup/restore, and the Feed Debug toggle + panel. Extracted from AppLayout.
export default function PodcastSettings() {
  const {
    c_inner, c_bord, c_text, c_sub, c_dim, c_head,
    showFeedDebug, setShowFeedDebug,
    feedProxyUrl, setFeedProxyUrl,
    sleepSafeAudio, setSleepSafeAudio,
    audioProxyUrl, setAudioProxyUrl,
    sleepSafeConfigured,
  } = useAppContext() || {};

  return (
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

      <FeedDebugPanel />

      {/* Build stamp — compare to the latest commit on GitHub to confirm the
          service worker served the current version. Lives here, off the nightly
          home view. */}
      <div style={{textAlign:'center',fontSize:'.6rem',color:c_dim,paddingTop:'.5rem',letterSpacing:'.04em'}}>
        build {BUILD_ID}
      </div>
    </div>
  );
}

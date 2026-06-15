import React, { useState } from 'react';
import { useAppContext } from '../context/AppContext.jsx';
import { redactUrlForDisplay, normalizeConfigUrl, getDefaultFeedProxyUrl } from '../utils/core.js';

// Developer panel shown under the "Feed Debug" toggle. Two parts:
//  - Audio Engine (dev): force an iOS-style AudioContext teardown + rebuild
//    and read engine diagnostics (see TESTING.md §3B).
//  - Feed Debug: the most recent feed-load attempt trace.
// First component extracted out of AppLayout; it reads everything it needs
// from context, so AppLayout just renders <FeedDebugPanel /> in place.
export default function FeedDebugPanel() {
  const {
    showFeedDebug,
    feedDebug,
    feedProxyUrl,
    forceAudioTeardown,
    getAudioDiagnostics,
    c_inner, c_bord, c_head, c_sub, c_dim,
  } = useAppContext() || {};

  const [audioDiag, setAudioDiag] = useState(null);

  if (!showFeedDebug) return null;

  return (
    <div style={{background:c_inner,border:`1px solid ${c_bord}`,borderRadius:'.75rem',padding:'.75rem',display:'flex',flexDirection:'column',gap:'.5rem'}}>
      <div style={{fontSize:'.68rem',fontWeight:700,color:c_head}}>Audio Engine (dev)</div>
      <div style={{fontSize:'.62rem',color:c_sub,lineHeight:1.5}}>
        Simulates an iOS interruption that closes the AudioContext, then rebuilds it
        (TESTING.md §3B). After tapping, audio should recover on the next Play / lock-screen control.
      </div>
      <div style={{display:'flex',gap:'.5rem',flexWrap:'wrap'}}>
        <button
          type="button"
          onClick={async ()=>{ await forceAudioTeardown?.(); setAudioDiag(getAudioDiagnostics?.()); }}
          style={{fontSize:'.65rem',fontWeight:700,color:'#fca5a5',background:'transparent',border:`1px solid ${c_bord}`,borderRadius:'.5rem',padding:'.4rem .6rem',cursor:'pointer'}}
        >
          Force teardown + rebuild
        </button>
        <button
          type="button"
          onClick={()=>setAudioDiag(getAudioDiagnostics?.())}
          style={{fontSize:'.65rem',fontWeight:700,color:c_head,background:'transparent',border:`1px solid ${c_bord}`,borderRadius:'.5rem',padding:'.4rem .6rem',cursor:'pointer'}}
        >
          Refresh status
        </button>
      </div>
      {audioDiag && (
        <div style={{fontSize:'.62rem',color:audioDiag.dead?'#fca5a5':'#86efac',lineHeight:1.5,wordBreak:'break-all'}}>
          state: {audioDiag.state} · dead: {String(audioDiag.dead)} · rebuilding: {String(audioDiag.rebuilding)} · sources: [{audioDiag.sources.join(', ')||'none'}]
        </div>
      )}
      <div style={{fontSize:'.68rem',fontWeight:700,color:c_head,marginTop:'.25rem'}}>Feed Debug</div>
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
  );
}

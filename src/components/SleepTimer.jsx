import React from 'react';
import { Clock } from 'lucide-react';
import { useAppContext } from '../context/AppContext.jsx';

// Sleep timer card: duration chips + slider, start/cancel, and the
// "Still Awake? (+15 min)" extend button that appears in the final minute.
// Extracted from AppLayout; reads timer state/handlers from context.
export default function SleepTimer() {
  const {
    bm,
    timerActive,
    timeLeft,
    timerMins,
    setTimerMins,
    toggleTimer,
    bumpTimer,
    fmt,
    c_sub,
  } = useAppContext() || {};

  return (
    <div className="card">
      <div style={{display:'flex',alignItems:'center',justifyContent:'space-between',marginBottom:'1rem'}}>
        <div style={{display:'flex',alignItems:'center',gap:'.5rem',color:bm?'#8a7860':'#f0c79a'}}>
          <Clock size={18}/>
          <span style={{fontWeight:700,fontSize:'.9rem'}}>Sleep Timer</span>
        </div>
        {timerActive && <span style={{fontFamily:'monospace',fontSize:'1.3rem',fontWeight:700,color:bm?'#b39b80':'#e6b277',letterSpacing:'.04em'}}>{fmt(timeLeft)}</span>}
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
          style={{background:bm?'#2a2114':'#b8813a',color:bm?'#e6dcce':'#15110b',animation:'pulse 1.5s ease-in-out infinite',
            boxShadow:bm?'none':'0 0 20px rgba(79,70,229,.4)'}}>
          Still Awake? (+15 min)
        </button>
      ):(
        <button onClick={toggleTimer} className="btn-primary"
          style={{background:timerActive?(bm?'rgba(255,255,255,.04)':'rgba(248,113,113,.1)'):(bm?'#2a2114':'#b8813a'),
            color:timerActive?(bm?'#8a7860':'#f87171'):(bm?'#e6dcce':'#15110b'),
            border:timerActive?`1px solid ${bm?'#2a2114':'rgba(248,113,113,.3)'}`:'none',
            boxShadow:timerActive?'none':(bm?'none':'0 4px 20px rgba(79,70,229,.3)')}}>
          {timerActive?'Cancel Timer':`Start ${timerMins} Min Timer`}
        </button>
      )}
      <p style={{fontSize:'.7rem',color:c_sub,textAlign:'center',margin:'.75rem 0 0'}}>Audio fades out gently over the final 10 minutes</p>
    </div>
  );
}

import React, { useState } from 'react';
import { Settings2, SlidersHorizontal, Waves, X, BookMarked, Trash2 } from 'lucide-react';
import { useAppContext } from '../context/AppContext.jsx';

// Master volume, the three pro-audio toggles (Night Comp / Voice EQ / Auto Pan),
// and the saveable Mix Presets. Extracted from AppLayout; the preset-naming and
// preset-list-open UI state is local to this component.
export default function MixerPanel() {
  const {
    bm,
    c_head, c_sub,
    masterVol, setMasterVol,
    compOn, setCompOn,
    eqOn, setEqOn,
    panOn, setPanOn,
    mixPresets,
    saveCurrentMix,
    loadMix,
    deleteMix,
  } = useAppContext() || {};

  const [mixName, setMixName] = useState('');
  const [showMixes, setShowMixes] = useState(false);

  return (
    <>
      {/* Master Volume */}
      <div className="card" style={{display:'flex',alignItems:'center',gap:'.875rem',marginBottom:'1rem'}}>
        <Settings2 size={18} color={bm?'#6b5d48':'#e6b277'}/>
        <span style={{fontSize:'.8rem',fontWeight:700,color:c_head,whiteSpace:'nowrap'}}>Master</span>
        <input type="range" min="0" max="1" step=".01" value={masterVol} className="indigo"
          onChange={e=>setMasterVol(+e.target.value)} style={{flex:1}}/>
        <span style={{fontSize:'.7rem',fontFamily:'monospace',color:c_sub,width:32,textAlign:'right'}}>{Math.round(masterVol*100)}%</span>
      </div>

      {/* Pro Audio Controls */}
      <div style={{display:'flex',gap:'.5rem',marginBottom:'1rem'}}>
        <button onClick={() => setCompOn(!compOn)} className="card"
          style={{flex:1,display:'flex',flexDirection:'column',alignItems:'center',gap:'.5rem',padding:'.875rem',cursor:'pointer',
          border:compOn?'1px solid rgba(230,178,119,0.4)':'1px solid var(--c-border)',
          background:compOn?'rgba(230,178,119,0.1)':'var(--c-surface)'}}>
          <Settings2 size={16} color={compOn?'#e6b277':'var(--c-dim)'} />
          <span style={{fontSize:'.65rem',fontWeight:700,color:compOn?'#e6b277':'var(--c-dim)'}}>NIGHT COMP</span>
        </button>

        <button onClick={() => setEqOn(!eqOn)} className="card"
          style={{flex:1,display:'flex',flexDirection:'column',alignItems:'center',gap:'.5rem',padding:'.875rem',cursor:'pointer',
          border:eqOn?'1px solid rgba(230,178,119,0.4)':'1px solid var(--c-border)',
          background:eqOn?'rgba(230,178,119,0.1)':'var(--c-surface)'}}>
          <SlidersHorizontal size={16} color={eqOn?'#e6b277':'var(--c-dim)'} />
          <span style={{fontSize:'.65rem',fontWeight:700,color:eqOn?'#e6b277':'var(--c-dim)'}}>VOICE EQ</span>
        </button>

        <button onClick={() => setPanOn(!panOn)} className="card"
          style={{flex:1,display:'flex',flexDirection:'column',alignItems:'center',gap:'.5rem',padding:'.875rem',cursor:'pointer',
          border:panOn?'1px solid rgba(217,138,94,0.4)':'1px solid var(--c-border)',
          background:panOn?'rgba(217,138,94,0.1)':'var(--c-surface)'}}>
          <Waves size={16} color={panOn?'#d98a5e':'var(--c-dim)'} />
          <span style={{fontSize:'.65rem',fontWeight:700,color:panOn?'#d98a5e':'var(--c-dim)'}}>AUTO PAN</span>
        </button>
      </div>

      {/* Mix Presets */}
      <div style={{marginBottom:'1rem'}}>
        <div style={{display:'flex',justifyContent:'space-between',alignItems:'center',marginBottom:'.5rem',padding:'0 .5rem'}}>
          <span className="section-label" style={{margin:0}}>Mix Presets</span>
          <button onClick={() => setShowMixes(!showMixes)} className="btn-icon" style={{width:28,height:28,minWidth:28,minHeight:28}}>
            {showMixes ? <X size={14} /> : <BookMarked size={14} />}
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
                      <Trash2 size={14} color="#f87171" />
                    </button>
                  </div>
                ))}
              </div>
            )}
          </div>
        )}
      </div>
    </>
  );
}

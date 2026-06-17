import React from 'react';
import { Volume2, Square, Play } from 'lucide-react';
import { useAppContext } from '../context/AppContext.jsx';
import { NOISE_TYPES, BINAURAL } from '../utils/core.js';
import Slider from './Slider.jsx';

// The side-by-side Ambient (noise) and Binaural (beats) cards: source select,
// play/stop, volume, and the "All night (bypass timer)" toggle for each.
// Extracted from AppLayout.
export default function AmbientBinaural() {
  const {
    bm,
    c_head, c_sub, c_inner, c_bord,
    ambientOn, ambientVol, setAmbientVol, ambientBypass, setAmbientBypass,
    noiseType, setNoiseType, toggleAmbient,
    binOn, binVol, setBinVol, binBypass, setBinBypass,
    binPreset, setBinPreset, toggleBin,
  } = useAppContext() || {};

  return (
    <div style={{display:'grid',gridTemplateColumns:'1fr 1fr',gap:'1rem'}}>

      {/* Ambient */}
      <div className="card" style={{position:'relative',overflow:'hidden'}}>
        {ambientOn && !bm && <div className="glow-orange" style={{position:'absolute',top:0,left:0,width:3,height:'100%',background:'#fb923c',borderRadius:2}}/>}
        <div style={{display:'flex',justifyContent:'space-between',alignItems:'flex-start',marginBottom:'.875rem'}}>
          <div style={{flex:1,minWidth:0}}>
            <div style={{fontSize:'.8rem',fontWeight:700,color:c_head,marginBottom:'.5rem'}}>Ambient</div>
            <div className="chip-row" role="radiogroup" aria-label="Ambient sound">
              {Object.entries(NOISE_TYPES).map(([k,v])=>(
                <button key={k} role="radio" aria-checked={noiseType===k}
                  onClick={()=>setNoiseType(k)} className={`chip${noiseType===k?' on':''}`}>
                  {v.label.split(' (')[0]}
                </button>
              ))}
            </div>
          </div>
          <button onClick={toggleAmbient} className={`btn-icon${ambientOn?' active-orange':''}`} style={{marginLeft:'.5rem',flexShrink:0}}>
            {ambientOn ? <Square size={18}/> : <Play size={18}/>}
          </button>
        </div>
        <div style={{display:'flex',alignItems:'center',gap:'.5rem'}}>
          <Volume2 size={14} color={c_sub}/>
          <Slider value={ambientVol} onChange={setAmbientVol} className="orange" style={{flex:1}}/>
        </div>
        <label style={{display:'flex',alignItems:'center',gap:'.5rem',fontSize:'.7rem',color:c_sub,marginTop:'.75rem',cursor:'pointer'}}>
          <input type="checkbox" checked={ambientBypass} onChange={e=>setAmbientBypass(e.target.checked)}/>
          Play all night (ignore timer)
        </label>
      </div>

      {/* Binaural */}
      <div className="card" style={{position:'relative',overflow:'hidden'}}>
        {binOn && !bm && <div className="glow-blue" style={{position:'absolute',top:0,left:0,width:3,height:'100%',background:'#e6b277',borderRadius:2}}/>}
        <div style={{display:'flex',justifyContent:'space-between',alignItems:'flex-start',marginBottom:'.875rem'}}>
          <div style={{flex:1,minWidth:0}}>
            <div style={{fontSize:'.8rem',fontWeight:700,color:c_head,marginBottom:'.5rem'}}>Binaural</div>
            <div className="chip-row" role="radiogroup" aria-label="Binaural preset">
              {Object.entries(BINAURAL).map(([k,v])=>(
                <button key={k} role="radio" aria-checked={binPreset===k}
                  onClick={()=>setBinPreset(k)} className={`chip${binPreset===k?' on':''}`}>
                  {v.name}
                </button>
              ))}
            </div>
          </div>
          <button onClick={toggleBin} className={`btn-icon${binOn?' active-blue':''}`} style={{marginLeft:'.5rem',flexShrink:0}}>
            {binOn ? <Square size={18}/> : <Play size={18}/>}
          </button>
        </div>
        <div style={{display:'flex',alignItems:'center',gap:'.5rem'}}>
          <Volume2 size={14} color={c_sub}/>
          <Slider value={binVol} onChange={setBinVol} className="blue" style={{flex:1}}/>
        </div>
        <div style={{fontSize:'.6rem',color:c_sub,opacity:.7,marginTop:'.4rem'}}>Best with headphones</div>
        <label style={{display:'flex',alignItems:'center',gap:'.5rem',fontSize:'.7rem',color:c_sub,marginTop:'.75rem',cursor:'pointer'}}>
          <input type="checkbox" checked={binBypass} onChange={e=>setBinBypass(e.target.checked)}/>
          Play all night (ignore timer)
        </label>
      </div>
    </div>
  );
}

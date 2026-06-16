import React from 'react';
import { Settings2, SlidersHorizontal, Waves } from 'lucide-react';
import { useAppContext } from '../context/AppContext.jsx';
import { NATIVE_MEDIA_VOLUME_LOCK } from '../utils/core.js';

// Podcast-only audio processing (compressor / low-shelf EQ / auto-pan), applied
// to the podcast Web Audio source while it plays. On iPhone, podcast audio uses
// the native device path for reliable background playback, which bypasses these
// in-browser effects entirely — so they're shown disabled there, pointing to the
// server-side "Sleep Safe Audio" option instead. Lives on the Podcast screen,
// next to the audio it affects (previously a dead control on the home screen).
const EFFECTS = [
  { key: 'comp', label: 'Even out volume', Icon: Settings2 },
  { key: 'eq',   label: 'Clearer speech',  Icon: SlidersHorizontal },
  { key: 'pan',  label: 'Gentle drift',    Icon: Waves },
];

export default function PodcastEffects() {
  const {
    c_sub, c_dim,
    eqOn, setEqOn, compOn, setCompOn, panOn, setPanOn,
  } = useAppContext() || {};

  const wiring = { comp: [compOn, setCompOn], eq: [eqOn, setEqOn], pan: [panOn, setPanOn] };
  const disabled = NATIVE_MEDIA_VOLUME_LOCK;

  return (
    <div className="card-inner" style={{marginBottom:'.875rem',display:'flex',flexDirection:'column',gap:'.625rem'}}>
      <div className="section-label" style={{margin:0}}>Podcast sound</div>
      <div style={{display:'flex',gap:'.5rem'}}>
        {EFFECTS.map(({ key, label, Icon }) => {
          const [on, setOn] = wiring[key];
          const active = on && !disabled;
          return (
            <button key={key} onClick={() => !disabled && setOn(!on)} disabled={disabled}
              style={{flex:1,display:'flex',flexDirection:'column',alignItems:'center',gap:'.4rem',padding:'.7rem .35rem',borderRadius:'.75rem',
                cursor:disabled?'default':'pointer',opacity:disabled?.5:1,
                border:active?'1px solid rgba(230,178,119,0.4)':'1px solid var(--c-border)',
                background:active?'rgba(230,178,119,0.1)':'var(--c-surface)'}}>
              <Icon size={16} color={active?'#e6b277':'var(--c-dim)'} />
              <span style={{fontSize:'.62rem',fontWeight:700,textAlign:'center',lineHeight:1.2,color:active?'#e6b277':c_sub}}>{label}</span>
            </button>
          );
        })}
      </div>
      <div style={{fontSize:'.62rem',color:c_dim,lineHeight:1.5}}>
        {disabled
          ? 'Not available during iPhone background-safe playback. Use Sleep Safe Audio above for server-side volume smoothing.'
          : 'Applies to podcast audio playing in this browser.'}
      </div>
    </div>
  );
}

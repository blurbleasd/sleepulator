import React from 'react';
import { Moon, Wind, Sun, MoonStar } from 'lucide-react';
import { useAppContext } from '../context/AppContext.jsx';

// App header: brand mark, breathing-guide toggle, and the Bedtime/Wake
// (dark-mode) switch. Extracted from AppLayout.
export default function Header() {
  const { bm, setBm, breathMode, setBreathMode } = useAppContext() || {};

  return (
    <header style={{display:'flex',alignItems:'center',justifyContent:'space-between',marginBottom:'1.25rem'}}>
      <div style={{display:'flex',alignItems:'center',gap:'.625rem'}}>
        <Moon size={26} color={bm?'#374151':'#818cf8'}/>
        <h1 style={{margin:0,fontSize:'1.4rem',fontWeight:900,letterSpacing:'.12em',
          background:bm?'none':'linear-gradient(135deg,#818cf8,#c084fc)',
          WebkitBackgroundClip:bm?'unset':'text',WebkitTextFillColor:bm?'#6b7280':'transparent',
          color:bm?'#6b7280':'transparent'}}>
          SLEEPULATOR
        </h1>
      </div>
      <div style={{display:'flex',gap:'.5rem',alignItems:'center'}}>
        <button onClick={()=>setBreathMode(v=>v?null:'478')} title="Breathing Guide"
          className={`btn-icon${breathMode?' active-indigo':''}`}>
          <Wind size={18}/>
        </button>
        <button onClick={()=>setBm(v=>!v)}
          style={{display:'flex',alignItems:'center',gap:'.375rem',padding:'.5rem .875rem',borderRadius:'9999px',
            border:`1px solid ${bm?'#1f2937':'rgba(129,140,248,.3)'}`,
            background:bm?'#0a0a0a':'rgba(129,140,248,.08)',
            color:bm?'#6b7280':'#818cf8',cursor:'pointer',fontSize:'.75rem',fontWeight:700}}>
          {bm ? <Sun size={14}/> : <MoonStar size={14}/>}
          {bm?'Wake':'Bedtime'}
        </button>
      </div>
    </header>
  );
}

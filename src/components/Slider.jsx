import React from 'react';

// A range input whose thumb is driven by LOCAL state (always smooth) while the
// parent/context update is rAF-throttled to at most once per frame. Dragging a
// volume slider used to call a setter on the ~1.5k-line god-context on every
// input event, re-rendering every consumer mid-drag → jank. Here the thumb never
// waits on that, and the final value is committed on release. Drop-in for
// <input type="range">: pass `value` (number) and `onChange(number)`.
export default function Slider({ value, onChange, min = 0, max = 1, step = 0.01, className = '', style, ...rest }) {
  const [local, setLocal] = React.useState(value);
  const dragging = React.useRef(false);
  const raf = React.useRef(0);

  // Accept external changes only when not actively dragging (don't fight the thumb).
  React.useEffect(() => { if (!dragging.current) setLocal(value); }, [value]);
  React.useEffect(() => () => cancelAnimationFrame(raf.current), []);

  const commit = (v) => {
    cancelAnimationFrame(raf.current);
    raf.current = requestAnimationFrame(() => onChange(v));
  };
  const end = () => {
    if (!dragging.current) return;
    dragging.current = false;
    cancelAnimationFrame(raf.current);
    onChange(local); // ensure the exact final value lands
  };

  return (
    <input
      type="range" min={min} max={max} step={step} value={local}
      className={className} style={style}
      onChange={(e) => { const v = +e.target.value; dragging.current = true; setLocal(v); commit(v); }}
      onPointerUp={end} onPointerCancel={end} onTouchEnd={end} onMouseUp={end} onBlur={end}
      {...rest}
    />
  );
}

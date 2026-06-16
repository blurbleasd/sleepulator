import React from 'react';
import {
  BookMarked, Clock, GripVertical, Moon, MoonStar, Pause, Play, Plus, RotateCcw, RotateCw, Rss, Search, Settings2, Shuffle, SlidersHorizontal, Square, Sun, Trash2, Volume2, VolumeX, Wind, X, HelpCircle, Download, Check, Waves, ChevronUp, ChevronDown, CloudOff
} from 'lucide-react';

const icons = {
  BookMarked, Clock, GripVertical, Moon, MoonStar, Pause, Play, Plus, RotateCcw, RotateCw, Rss, Search, Settings2, Shuffle, SlidersHorizontal, Square, Sun, Trash2, Volume2, VolumeX, Wind, X, Download, Check, Waves, ChevronUp, ChevronDown, CloudOff
};

// Name-keyed wrapper around lucide-react icons so call sites can pass a string
// name (incl. computed names like skip RotateCcw/RotateCw). Falls back to a
// help glyph for unknown names. Shared across the app's components.
export default function LucideIcon({ name, size = 20, color = 'currentColor', strokeWidth = 2, className = '', style = {} }) {
  const Icon = icons[name] || HelpCircle;
  return <Icon size={size} color={color} strokeWidth={strokeWidth} className={className} style={style} />;
}

import { useState, useEffect, useCallback } from 'react';
import { get, set } from 'idb-keyval';

/**
 * usePersistence
 * Replaces localStorage with IndexedDB (idb-keyval) to bypass iOS quota constraints.
 * Falls back to localStorage synchronously on the very first load to prevent
 * layout thrashing and allow seamless migration.
 *
 * @param {string} key The storage key
 * @param {any} initialValue The fallback value if nothing is found
 * @returns {[any, Function, boolean]} [value, setValue, isLoaded]
 */
export function usePersistence(key, initialValue) {
  // 1. Synchronous read from localStorage (for migration / initial render)
  const [value, setValue] = useState(() => {
    try {
      const local = localStorage.getItem(key);
      if (local !== null) {
        return JSON.parse(local);
      }
    } catch {
      // Not JSON or missing
    }
    return initialValue;
  });

  const hasIDB = typeof window !== 'undefined' && !!window.indexedDB;
  const [loaded, setLoaded] = useState(!hasIDB);

  // 2. Asynchronous read from IndexedDB
  useEffect(() => {
    if (!hasIDB) return;
    let active = true;
    get(key).then(val => {
      if (!active) return;
      if (val !== undefined) {
        setValue(val);
      } else {
        // If IDB is empty, migrate from localStorage to IDB
        const local = localStorage.getItem(key);
        if (local !== null) {
          try {
            const parsed = JSON.parse(local);
            set(key, parsed).catch(console.error);
          } catch {
            set(key, local).catch(console.error);
          }
        }
      }
      setLoaded(true);
    }).catch((err) => {
      console.error(`IDB read failed for ${key}`, err);
      if (active) setLoaded(true); // Fallback to whatever is in state
    });
    return () => { active = false; };
  }, [key]);

  // 3. Write updates to both state and IndexedDB
  const setPersistentValue = useCallback((nextValue) => {
    setValue(prev => {
      const val = typeof nextValue === 'function' ? nextValue(prev) : nextValue;
      if (hasIDB) set(key, val).catch(console.error);
      
      // Keep localStorage somewhat in sync for tiny values, but wrap in try-catch
      // to swallow iOS quota errors. Large values like playlists will fail but that's ok
      // because IDB is now the source of truth.
      try {
        localStorage.setItem(key, JSON.stringify(val));
      } catch (e) {
        // Ignore quota errors
      }
      return val;
    });
  }, [key]);

  return [value, setPersistentValue, loaded];
}

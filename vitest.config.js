import { defineConfig } from 'vitest/config';

// Unit tests target the pure helpers in src/utils; the render test mounts the
// full app. A DOM environment is used because core.js reads
// window/navigator/localStorage at module load.
export default defineConfig({
  test: {
    environment: 'happy-dom',
    css: false,
    include: ['src/**/*.test.{js,jsx}'],
  },
});

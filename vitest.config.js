import { defineConfig } from 'vitest/config';

// Unit tests target the pure helpers in src/utils. A DOM environment is used
// because core.js reads window/navigator/localStorage at module load.
export default defineConfig({
  test: {
    environment: 'happy-dom',
    include: ['src/**/*.test.js'],
  },
});

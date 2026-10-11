import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// The Worker API runs on 8787 (wrangler dev). Same-origin /api keeps cookies first-party.
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      '/api': { target: 'http://127.0.0.1:8787', changeOrigin: false },
    },
  },
});

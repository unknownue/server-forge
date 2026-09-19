import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// Build straight into ../static so the FastAPI app serves it from the same
// origin (no CDN, works offline on an internal network).
export default defineConfig({
  plugins: [vue()],
  build: {
    outDir: '../static',
    emptyOutDir: true,
  },
  server: {
    proxy: {
      '/api': 'http://localhost:9090',
    },
  },
})

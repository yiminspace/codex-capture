import { defineConfig } from '@playwright/test';
export default defineConfig({
  testDir: './browser', timeout: 20000, fullyParallel: false,
  use: { baseURL: 'http://127.0.0.1:4177', channel: process.env.CAPTURE_BROWSER_CHANNEL || undefined, viewport: { width: 1440, height: 960 }, screenshot: 'only-on-failure' },
  webServer: { command: 'pnpm exec vite preview --host 127.0.0.1 --port 4177 --strictPort', port: 4177, reuseExistingServer: false },
});

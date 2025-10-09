import { defineConfig, devices } from '@playwright/test';

const defaultBaseURL = 'http://127.0.0.1:3000';
const baseURL = process.env.E2E_TARGET_URL ?? defaultBaseURL;
const useExternalTarget = Boolean(process.env.E2E_TARGET_URL);

const localWebServer = useExternalTarget
  ? undefined
  : {
      command: 'HOSTNAME=127.0.0.1 PORT=3000 pnpm run dev',
      url: baseURL,
      reuseExistingServer: !process.env.CI,
      timeout: 120_000,
    };

export default defineConfig({
  testDir: './tests/e2e',
  timeout: 30_000,
  expect: {
    timeout: 5_000,
  },
  retries: process.env.CI ? 2 : 0,
  reporter: process.env.CI ? [['list'], ['github']] : [['list']],
  use: {
    baseURL,
    trace: process.env.CI ? 'on-first-retry' : 'retain-on-failure',
    video: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
  workers: process.env.CI ? 2 : undefined,
  webServer: localWebServer,
});

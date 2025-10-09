import { expect, test } from '@playwright/test';

const HOME_PATH = '/';

test.describe('Homepage', () => {
  test('loads primary hero content', async ({ page }) => {
    await page.goto(HOME_PATH, { waitUntil: 'domcontentloaded' });

    await expect(page).toHaveTitle(/AI Development Platform/i);
    await expect(
      page.getByRole('heading', {
        level: 1,
        name: /Ship trusted AI experiences faster with a platform teams love\./i,
      }),
    ).toBeVisible();
    await expect(page.getByRole('link', { name: 'Request Access' })).toBeVisible();
    await expect(page.getByRole('link', { name: 'Explore Features' })).toBeVisible();
  });

  test('displays all core feature pillars', async ({ page }) => {
    await page.goto(HOME_PATH, { waitUntil: 'domcontentloaded' });

    const features = ['Security by Design', 'AI-Native Workflows', 'Modern Stack Velocity'];
    for (const feature of features) {
      await expect(page.getByRole('heading', { level: 3, name: feature })).toBeVisible();
    }
  });

  test('call-to-action section surfaces primary contact options', async ({ page }) => {
    await page.goto(`${HOME_PATH}#get-started`, { waitUntil: 'domcontentloaded' });

    await expect(
      page.getByRole('heading', { level: 2, name: 'Ready to launch secure AI products?' }),
    ).toBeVisible();
    await expect(page.getByRole('link', { name: 'Talk to Sales' })).toBeVisible();
    await expect(page.getByRole('link', { name: 'View Documentation' })).toBeVisible();
  });
});

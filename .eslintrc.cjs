module.exports = {
  root: true,
  extends: ['@ai-dev-platform/eslint-config-custom'],
  parserOptions: {
    project: ['./apps/web/tsconfig.json'],
    tsconfigRootDir: __dirname,
  },
  ignorePatterns: [
    'node_modules',
    '.turbo',
    'apps/web/.next',
    'apps/web/out',
    'apps/web/test-results',
    'pnpm-lock.yaml',
    '**/.eslintrc.js',
    'apps/web/.eslintrc.js',
    'apps/web/*.js',
  ],
  overrides: [
    {
      files: ['**/*.js', '**/*.cjs', '**/*.mjs'],
      parserOptions: {
        project: null,
      },
      rules: {
        '@typescript-eslint/consistent-type-imports': 'off',
      },
    },
    {
      files: ['apps/web/**/*.{ts,tsx}'],
      extends: ['@ai-dev-platform/eslint-config-custom/next'],
    },
  ],
};

/**
 * Shared base ESLint configuration.
 */
const securityPlugin = require('eslint-plugin-security');
const sonarjsPlugin = require('eslint-plugin-sonarjs');

if (securityPlugin?.configs?.recommended?.name) {
  delete securityPlugin.configs.recommended.name;
}

if (Array.isArray(securityPlugin?.configs?.recommended?.plugins)) {
  securityPlugin.configs.recommended.plugins = securityPlugin.configs.recommended.plugins.map(
    (plugin) => (typeof plugin === 'string' ? plugin : 'security'),
  );
} else if (securityPlugin?.configs?.recommended?.plugins) {
  securityPlugin.configs.recommended.plugins = ['security'];
}

if (sonarjsPlugin?.configs?.recommended?.name) {
  delete sonarjsPlugin.configs.recommended.name;
}

if (Array.isArray(sonarjsPlugin?.configs?.recommended?.plugins)) {
  sonarjsPlugin.configs.recommended.plugins = sonarjsPlugin.configs.recommended.plugins.map(
    (plugin) => (typeof plugin === 'string' ? plugin : 'sonarjs'),
  );
} else if (sonarjsPlugin?.configs?.recommended?.plugins) {
  sonarjsPlugin.configs.recommended.plugins = ['sonarjs'];
}

module.exports = {
  env: {
    es2022: true,
    browser: true,
    node: true,
  },
  parser: '@typescript-eslint/parser',
  parserOptions: {
    ecmaVersion: 2022,
    sourceType: 'module',
    projectService: true,
    tsconfigRootDir: process.cwd(),
  },
  plugins: ['@typescript-eslint', 'security', 'sonarjs'],
  extends: [
    'eslint:recommended',
    'plugin:@typescript-eslint/recommended-type-checked',
    'plugin:@typescript-eslint/stylistic-type-checked',
    'plugin:security/recommended',
    'plugin:sonarjs/recommended',
    'prettier',
  ],
  rules: {
    '@typescript-eslint/consistent-type-imports': ['error', { prefer: 'type-imports' }],
    '@typescript-eslint/no-explicit-any': 'error',
    '@typescript-eslint/no-floating-promises': 'error',
    '@typescript-eslint/no-unnecessary-type-assertion': 'error',
    '@typescript-eslint/prefer-nullish-coalescing': 'error',
    '@typescript-eslint/prefer-optional-chain': 'error',
    'security/detect-object-injection': 'error',
    'security/detect-unsafe-regex': 'error',
    'security/detect-non-literal-fs-filename': 'error',
    'security/detect-non-literal-regexp': 'error',
    'sonarjs/no-duplicate-string': ['warn', { threshold: 5 }],
    'sonarjs/no-identical-functions': 'warn',
    'sonarjs/no-all-duplicated-branches': 'warn',
  },
  settings: {
    'import/resolver': {
      node: {
        extensions: ['.js', '.jsx', '.ts', '.tsx'],
      },
    },
  },
  reportUnusedDisableDirectives: true,
  overrides: [
    {
      files: ['*.js', '*.cjs'],
      parserOptions: {
        projectService: false,
      },
      rules: {
        '@typescript-eslint/no-var-requires': 'off',
      },
    },
    {
      files: ['**/tests/**/*', '**/*.test.*', '**/*.spec.*'],
      env: {
        jest: true,
      },
    },
  ],
};

module.exports = {
  rootDir: __dirname,
  testEnvironment: 'jest-environment-jsdom',
  setupFilesAfterEnv: ['<rootDir>/jest.setup.ts'],
  testPathIgnorePatterns: ['<rootDir>/tests/e2e/', '/node_modules/', '/.next/'],
  collectCoverage: true,
  collectCoverageFrom: [
    '<rootDir>/src/**/*.{ts,tsx}',
    '!<rootDir>/src/**/*.d.ts',
    '!<rootDir>/src/app/layout.tsx',
  ],
  coverageThreshold: {
    global: {
      branches: 80,
      functions: 80,
      lines: 80,
      statements: 80,
    },
  },
  moduleNameMapper: {
    '^.+\\.module\\.(css|sass|scss)$': '<rootDir>/jest.cssModuleMock.js',
    '^.+\\.(css|sass|scss)$': '<rootDir>/jest.cssMock.js',
    '^.+\\.(png|jpg|jpeg|gif|webp|avif|ico|bmp|svg)$': '<rootDir>/jest.fileMock.js',
    '^@/(.*)$': '<rootDir>/src/$1',
    '^@fixtures/(.*)$': '<rootDir>/../../fixtures/$1',
  },
  transform: {
    '^.+\\.(js|jsx|ts|tsx|mjs)$': '<rootDir>/jest.transform.js',
  },
  transformIgnorePatterns: ['/node_modules/'],
  moduleFileExtensions: ['ts', 'tsx', 'js', 'jsx', 'json', 'mjs'],
  clearMocks: true,
  cacheDirectory: '<rootDir>/.cache/jest',
};

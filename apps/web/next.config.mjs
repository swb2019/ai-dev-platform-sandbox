import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const buildYear = new Date().getUTCFullYear().toString();

/** @type {import('next').NextConfig} */
const nextConfig = {
  output: 'standalone',
  env: {
    BUILD_COPYRIGHT_YEAR: buildYear,
  },
  experimental: {
    externalDir: true,
  },
  allowedDevOrigins: ['127.0.0.1', 'localhost'],
  webpack: (config) => {
    config.resolve.alias['@fixtures'] = path.resolve(__dirname, '../../fixtures');
    return config;
  },
};

export default nextConfig;

import type { Config } from 'tailwindcss';
import defaultTheme from 'tailwindcss/defaultTheme';

const config: Config = {
  content: ['./src/**/*.{ts,tsx,js,jsx,mdx}'],
  theme: {
    extend: {
      colors: {
        brand: {
          primary: '#2563eb',
          secondary: '#0ea5e9',
          accent: '#22d3ee',
        },
        surface: {
          default: '#0f172a',
          muted: '#111827',
          inverted: '#f8fafc',
        },
      },
      fontFamily: {
        sans: ['var(--font-sans)', ...defaultTheme.fontFamily.sans],
        mono: ['var(--font-mono)', ...defaultTheme.fontFamily.mono],
      },
      backgroundImage: {
        'grid-radial':
          'radial-gradient(circle at 25% 25%, rgba(34, 211, 238, 0.25), transparent 50%), radial-gradient(circle at 75% 0%, rgba(37, 99, 235, 0.2), transparent 40%)',
      },
    },
  },
};

export default config;

import type { Metadata } from 'next';
import type { ReactNode } from 'react';
import Link from 'next/link';
import { Inter, JetBrains_Mono } from 'next/font/google';
import { cn } from '@/lib/utils';
import './globals.css';

const COPYRIGHT_YEAR = process.env.BUILD_COPYRIGHT_YEAR ?? '2024';

const inter = Inter({
  variable: '--font-sans',
  subsets: ['latin'],
  display: 'swap',
});

const jetBrainsMono = JetBrains_Mono({
  variable: '--font-mono',
  subsets: ['latin'],
  display: 'swap',
});

export const metadata: Metadata = {
  title: 'AI Development Platform',
  description:
    'A secure, AI-native platform that accelerates product teams with a modern web stack.',
};

export default function RootLayout({ children }: Readonly<{ children: ReactNode }>) {
  return (
    <html lang="en" className="scroll-smooth">
      <body
        className={cn(
          'relative min-h-screen bg-transparent text-slate-100 antialiased',
          inter.variable,
          jetBrainsMono.variable,
        )}
      >
        <div className="relative flex min-h-screen flex-col">
          <header className="z-10 border-b border-white/10 bg-black/40 px-6 py-5 backdrop-blur">
            <div className="mx-auto flex w-full max-w-6xl items-center justify-between">
              <div className="flex items-center gap-2 text-lg font-semibold tracking-tight">
                <span className="inline-flex h-9 w-9 items-center justify-center rounded-full bg-gradient-to-br from-brand-primary to-brand-secondary text-base font-bold text-white">
                  AI
                </span>
                <span>AI Dev Platform</span>
              </div>
              <nav className="hidden items-center gap-6 text-sm font-medium md:flex">
                <a className="text-white/80 transition hover:text-white" href="#security">
                  Security
                </a>
                <a className="text-white/80 transition hover:text-white" href="#ai">
                  AI
                </a>
                <a className="text-white/80 transition hover:text-white" href="#modern-stack">
                  Modern Stack
                </a>
              </nav>
              <a
                className="rounded-full bg-brand-primary px-5 py-2 text-sm font-semibold text-white shadow shadow-brand-primary/40 transition hover:bg-brand-secondary"
                href="#get-started"
              >
                Get Started
              </a>
            </div>
          </header>
          <main className="relative flex-1">{children}</main>
          <footer className="border-t border-white/10 bg-black/50 px-6 py-6 text-sm text-white/60 backdrop-blur">
            <div className="mx-auto flex w-full max-w-6xl flex-col items-start justify-between gap-4 md:flex-row md:items-center">
              <p>© {COPYRIGHT_YEAR} AI Dev Platform. All rights reserved.</p>
              <nav className="flex gap-4">
                <Link className="hover:text-white" href="/privacy">
                  Privacy
                </Link>
                <Link className="hover:text-white" href="/terms">
                  Terms
                </Link>
                <Link className="hover:text-white" href="/contact">
                  Contact
                </Link>
              </nav>
            </div>
          </footer>
        </div>
      </body>
    </html>
  );
}

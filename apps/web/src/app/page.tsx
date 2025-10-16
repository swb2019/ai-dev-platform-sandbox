import Link from 'next/link';
import { cn } from '@/lib/utils';
import { features } from '@/data/feature-cards';

export default function Home() {
  return (
    <div className="relative overflow-hidden">
      <div className="pointer-events-none absolute inset-0 bg-grid-radial opacity-70" aria-hidden />
      <section className="relative px-6 pb-24 pt-24 sm:pt-28 lg:pt-32">
        <div className="mx-auto flex max-w-6xl flex-col items-center text-center">
          <span className="mb-6 inline-flex items-center rounded-full border border-white/20 bg-white/5 px-4 py-1 text-xs font-semibold uppercase tracking-[0.3em] text-white/70 backdrop-blur">
            Secure • AI • Modern
          </span>
          <h1 className="max-w-3xl text-4xl font-semibold leading-tight text-white sm:text-5xl lg:text-6xl">
            Ship trusted AI experiences faster with a platform teams love.
          </h1>
          <p className="mt-6 max-w-2xl text-lg text-white/70">
            AI Dev Platform unifies security controls, AI tooling, and a future-ready web stack so
            your organization can experiment boldly and deploy with confidence.
          </p>
          <div className="mt-10 flex flex-col gap-4 sm:flex-row">
            <Link
              href="#get-started"
              className="rounded-full bg-brand-primary px-8 py-3 text-sm font-semibold uppercase tracking-wide text-white shadow-lg shadow-brand-primary/40 transition hover:bg-brand-secondary"
            >
              Request Access
            </Link>
            <Link
              href="#features"
              className="rounded-full border border-white/20 bg-white/10 px-8 py-3 text-sm font-semibold uppercase tracking-wide text-white/80 transition hover:border-white/40 hover:text-white"
            >
              Explore Features
            </Link>
          </div>
        </div>
      </section>

      <section id="features" className="relative z-10 px-6 pb-24">
        <div className="mx-auto grid max-w-6xl gap-8 md:grid-cols-3">
          {features.map((feature) => (
            <article
              key={feature.id}
              id={feature.id}
              className={cn(
                'group relative flex h-full flex-col gap-4 overflow-hidden rounded-3xl border border-white/10 bg-white/5 p-8 text-left backdrop-blur transition hover:border-brand-accent/60 hover:shadow-2xl',
                "before:absolute before:inset-0 before:-z-10 before:opacity-0 before:transition before:duration-300 before:content-[''] before:[background:radial-gradient(circle_at_top,var(--brand-secondary)_0%,transparent_65%)]",
                'hover:before:opacity-100',
              )}
            >
              <span className="inline-flex w-fit rounded-full bg-brand-primary/10 px-3 py-1 text-xs font-semibold uppercase tracking-wide text-brand-accent">
                {feature.badge}
              </span>
              <h3 className="text-2xl font-semibold text-white">{feature.title}</h3>
              <p className="text-sm text-white/70">{feature.description}</p>
              <ul className="mt-4 space-y-2 text-sm text-white/80">
                {feature.points.map((point) => (
                  <li key={point} className="flex items-start gap-2">
                    <span
                      className="mt-1 inline-flex h-2 w-2 rounded-full bg-brand-accent"
                      aria-hidden
                    />
                    <span>{point}</span>
                  </li>
                ))}
              </ul>
              <Link
                href={'#' + feature.id}
                className="mt-auto inline-flex items-center gap-2 text-sm font-semibold text-brand-accent transition group-hover:text-white"
              >
                Learn more
                <span aria-hidden className="transition group-hover:translate-x-1">
                  →
                </span>
              </Link>
            </article>
          ))}
        </div>
      </section>

      <section id="get-started" className="relative z-10 px-6 pb-24" aria-labelledby="cta-title">
        <div className="mx-auto max-w-5xl overflow-hidden rounded-3xl border border-white/10 bg-gradient-to-br from-brand-primary/20 via-brand-secondary/20 to-brand-accent/10 p-10 text-center backdrop-blur">
          <h2 id="cta-title" className="text-3xl font-semibold text-white sm:text-4xl">
            Ready to launch secure AI products?
          </h2>
          <p className="mt-4 text-base text-white/75">
            Partner with us to roll out governed AI sandboxes, modern web experiences, and
            compliance-aligned delivery pipelines in weeks, not months.
          </p>
          <div className="mt-8 flex flex-col items-center justify-center gap-3 sm:flex-row">
            <Link
              href="mailto:hello@ai-dev-platform.example"
              className="rounded-full bg-white px-8 py-3 text-sm font-semibold uppercase tracking-wide text-slate-900 shadow-lg transition hover:bg-slate-200"
            >
              Talk to Sales
            </Link>
            <Link
              href="/docs"
              className="rounded-full border border-white/40 px-8 py-3 text-sm font-semibold uppercase tracking-wide text-white/80 transition hover:border-white hover:text-white"
            >
              View Documentation
            </Link>
          </div>
        </div>
      </section>
    </div>
  );
}

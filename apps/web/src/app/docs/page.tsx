import type { Metadata } from 'next';
import Link from 'next/link';

export const metadata: Metadata = {
  title: 'Documentation | AI Development Platform',
  description: 'Overview of guides and resources for the AI Development Platform.',
};

const sections = [
  {
    id: 'getting-started',
    title: 'Getting Started',
    description:
      'Spin up the development environment, install dependencies, and run the local stack.',
    bullets: [
      'Set up Node.js, pnpm, and Playwright prerequisites.',
      'Install dependencies with workspace-aware commands.',
      'Run lint, test, and build tasks through Turbo or pnpm fallbacks.',
    ],
  },
  {
    id: 'architecture',
    title: 'Architecture Overview',
    description: 'Understand how the web app, infrastructure, and delivery pipelines fit together.',
    bullets: [
      'Next.js App Router front-end backed by Tailwind and TypeScript.',
      'Kubernetes Gateway API and Kustomize overlays for traffic routing.',
      'Terraform-managed GKE Autopilot clusters with Binary Authorization.',
    ],
  },
  {
    id: 'security',
    title: 'Security & Compliance',
    description:
      'Review supply-chain scanning, signing, and compliance workflows embedded in the platform.',
    bullets: [
      'Docker supply-chain tooling integrates Trivy, Grype, Syft, and Cosign.',
      'GitHub Actions leverage Workload Identity Federation for keyless auth.',
      'Binary Authorization enforces attested images across environments.',
    ],
  },
  {
    id: 'operations',
    title: 'Operations Runbooks',
    description: 'Follow standardized workflows for onboarding and ongoing operations.',
    bullets: [
      'Use helper scripts to open PRs, monitor merges, and enforce editor parity.',
      'Apply Kustomize overlays with immutable image digests during deploys.',
      'Reference task context scripts to keep goals and TODOs synchronized.',
    ],
  },
];

export default function DocsPage() {
  return (
    <div className="mx-auto flex max-w-4xl flex-col gap-10 px-6 py-16">
      <header className="space-y-4 text-center">
        <span className="inline-flex items-center justify-center rounded-full bg-brand-primary/10 px-4 py-1 text-xs font-semibold uppercase tracking-[0.3em] text-brand-accent">
          Documentation
        </span>
        <h1 className="text-4xl font-semibold text-white">Explore the AI Dev Platform docs</h1>
        <p className="text-base text-white/70">
          Access curated guides, architecture diagrams, and operational playbooks that ship with the
          platform.
        </p>
      </header>
      <section className="grid gap-6 md:grid-cols-2">
        {sections.map((section) => (
          <article
            key={section.id}
            className="group flex flex-col gap-4 rounded-2xl border border-white/10 bg-white/5 p-6 backdrop-blur transition hover:border-brand-accent/60"
          >
            <h2 className="text-xl font-semibold text-white">{section.title}</h2>
            <p className="text-sm text-white/70">{section.description}</p>
            <ul className="space-y-2 text-sm text-white/80">
              {section.bullets.map((bullet) => (
                <li key={bullet} className="flex gap-2">
                  <span className="mt-1 inline-flex h-2 w-2 flex-none rounded-full bg-brand-accent" />
                  <span>{bullet}</span>
                </li>
              ))}
            </ul>
            <Link
              href={`#${section.id}`}
              className="group mt-auto inline-flex items-center gap-2 text-sm font-semibold text-brand-accent transition hover:text-white"
            >
              Jump to details
              <span
                aria-hidden
                className="transition-transform duration-200 group-hover:translate-x-1"
              >
                →
              </span>
            </Link>
          </article>
        ))}
      </section>
      <section className="space-y-12">
        {sections.map((section) => (
          <article
            key={section.id + '-detail'}
            id={section.id}
            className="scroll-mt-20 space-y-4 rounded-2xl border border-white/10 bg-white/5 p-6 backdrop-blur"
          >
            <h2 className="text-2xl font-semibold text-white">{section.title}</h2>
            <p className="text-sm text-white/70">{section.description}</p>
            <ul className="space-y-2 text-sm text-white/80">
              {section.bullets.map((bullet) => (
                <li key={bullet} className="flex gap-2">
                  <span className="mt-1 inline-flex h-2 w-2 flex-none rounded-full bg-brand-accent" />
                  <span>{bullet}</span>
                </li>
              ))}
            </ul>
          </article>
        ))}
      </section>
      <footer className="rounded-2xl border border-white/10 bg-brand-primary/10 p-8 text-center">
        <h2 className="text-2xl font-semibold text-white">Need something specific?</h2>
        <p className="mt-3 text-sm text-white/80">
          Reach out to our team and we&apos;ll help you navigate the platform roadmap.
        </p>
        <Link
          href="/contact"
          className="mt-5 inline-flex items-center justify-center rounded-full bg-brand-primary px-6 py-2 text-sm font-semibold uppercase tracking-wide text-white transition hover:bg-brand-secondary"
        >
          Contact us
        </Link>
      </footer>
    </div>
  );
}

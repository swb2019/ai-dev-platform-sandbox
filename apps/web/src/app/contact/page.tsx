import type { Metadata } from 'next';
import Link from 'next/link';

export const metadata: Metadata = {
  title: 'Contact | AI Development Platform',
  description: 'Get in touch with the AI Dev Platform team.',
};

const channels = [
  {
    title: 'Sales',
    description: 'Request demos, pricing details, or tailored onboarding programs.',
    href: 'mailto:hello@ai-dev-platform.example',
    label: 'Email sales',
  },
  {
    title: 'Security',
    description: 'Report vulnerabilities or request information security assurances.',
    href: 'mailto:security@ai-dev-platform.example',
    label: 'Email security',
  },
  {
    title: 'Support',
    description: 'Open tickets for platform operations, CI/CD pipelines, or infrastructure.',
    href: 'mailto:support@ai-dev-platform.example',
    label: 'Email support',
  },
];

export default function ContactPage() {
  return (
    <div className="mx-auto flex max-w-3xl flex-col gap-10 px-6 py-16">
      <header className="space-y-4 text-center">
        <h1 className="text-4xl font-semibold text-white">Contact the AI Dev Platform team</h1>
        <p className="text-base text-white/70">
          Choose the channel that best matches your request or reach out directly using the
          addresses below.
        </p>
      </header>
      <section className="space-y-6">
        {channels.map((channel) => (
          <article
            key={channel.title}
            className="flex flex-col gap-4 rounded-2xl border border-white/10 bg-white/5 p-6 backdrop-blur"
          >
            <div>
              <h2 className="text-xl font-semibold text-white">{channel.title}</h2>
              <p className="mt-2 text-sm text-white/70">{channel.description}</p>
            </div>
            <Link
              href={channel.href}
              className="inline-flex w-fit items-center gap-2 rounded-full bg-brand-primary px-5 py-2 text-sm font-semibold uppercase tracking-wide text-white transition hover:bg-brand-secondary"
            >
              {channel.label}
            </Link>
          </article>
        ))}
      </section>
      <footer className="space-y-3 rounded-2xl border border-white/10 bg-brand-primary/10 p-6 text-sm text-white/80">
        <p>
          For incident response or production-severity issues, escalate through the on-call channel
          documented in the internal runbook. Out-of-band security incidents should include relevant
          logs and timestamps to accelerate triage.
        </p>
      </footer>
    </div>
  );
}

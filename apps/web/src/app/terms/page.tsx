import type { Metadata } from 'next';

export const metadata: Metadata = {
  title: 'Terms of Service | AI Development Platform',
  description: 'Usage terms for the AI Development Platform.',
};

const clauses = [
  {
    heading: 'Acceptable Use',
    body: 'Operate within applicable laws and do not attempt to circumvent platform controls, exfiltrate data, or misuse AI models for harmful purposes.',
  },
  {
    heading: 'Service Commitments',
    body: 'We provide the platform on a best-effort basis with automated monitoring, rollout, and rollback protections. Availability targets are documented in customer agreements.',
  },
  {
    heading: 'Intellectual Property',
    body: 'All platform assets remain the property of AI Dev Platform unless superseded by individual licensing agreements. Customer workloads remain customer property.',
  },
  {
    heading: 'Liability',
    body: 'To the maximum extent permitted, AI Dev Platform is not liable for indirect, incidental, or consequential damages arising from use of the service.',
  },
];

export default function TermsPage() {
  return (
    <div className="mx-auto flex max-w-3xl flex-col gap-8 px-6 py-16">
      <header className="space-y-3">
        <h1 className="text-4xl font-semibold text-white">Terms of Service</h1>
        <p className="text-sm text-white/70">
          Effective {new Date().getFullYear()} — The following terms govern usage of the AI Dev
          Platform by internal and external teams.
        </p>
      </header>
      <section className="space-y-6 text-sm leading-relaxed text-white/80">
        {clauses.map((clause) => (
          <article key={clause.heading} className="space-y-2">
            <h2 className="text-xl font-semibold text-white">{clause.heading}</h2>
            <p>{clause.body}</p>
          </article>
        ))}
      </section>
    </div>
  );
}

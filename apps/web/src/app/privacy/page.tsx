import type { Metadata } from 'next';

export const metadata: Metadata = {
  title: 'Privacy Policy | AI Development Platform',
  description: 'How we handle data across the AI Development Platform.',
};

const policySections = [
  {
    heading: 'Overview',
    body: 'We collect only the telemetry and audit data required to operate and secure the platform. All logs are retained under enterprise access controls.',
  },
  {
    heading: 'Data Handling',
    body: 'Production data is encrypted in transit and at rest. Access to datasets, secrets, and model artifacts is gated through least-privilege IAM policies.',
  },
  {
    heading: 'User Control',
    body: 'Administrators can request export or deletion of user data by contacting support. Requests are fulfilled within 30 days unless stricter regulatory timelines apply.',
  },
  {
    heading: 'Contact',
    body: 'Questions about privacy can be sent to privacy@ai-dev-platform.example.',
  },
];

export default function PrivacyPage() {
  return (
    <div className="mx-auto flex max-w-3xl flex-col gap-8 px-6 py-16">
      <header className="space-y-3">
        <h1 className="text-4xl font-semibold text-white">Privacy Policy</h1>
        <p className="text-sm text-white/70">
          Updated {new Date().getFullYear()} — AI Dev Platform safeguards customer and operator data
          through rigorous security controls.
        </p>
      </header>
      <section className="space-y-6 text-sm leading-relaxed text-white/80">
        {policySections.map((section) => (
          <article key={section.heading} className="space-y-2">
            <h2 className="text-xl font-semibold text-white">{section.heading}</h2>
            <p>{section.body}</p>
          </article>
        ))}
      </section>
    </div>
  );
}

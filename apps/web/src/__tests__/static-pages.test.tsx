import { render, screen } from '@testing-library/react';
import DocsPage from '@/app/docs/page';
import PrivacyPage from '@/app/privacy/page';
import TermsPage from '@/app/terms/page';
import ContactPage from '@/app/contact/page';

describe('Static content pages', () => {
  it('renders the documentation overview with internal anchors', () => {
    render(<DocsPage />);

    expect(
      screen.getByRole('heading', { level: 1, name: /Explore the AI Dev Platform docs/i }),
    ).toBeInTheDocument();
    expect(screen.getAllByRole('link', { name: /Jump to details/i })).not.toHaveLength(0);
  });

  it('describes privacy commitments', () => {
    render(<PrivacyPage />);

    expect(screen.getByRole('heading', { level: 1, name: /Privacy Policy/i })).toBeInTheDocument();
    expect(screen.getByText(/privacy@ai-dev-platform\.example/i)).toBeInTheDocument();
  });

  it('lists the terms of service clauses', () => {
    render(<TermsPage />);

    expect(
      screen.getByRole('heading', { level: 1, name: /Terms of Service/i }),
    ).toBeInTheDocument();
    expect(screen.getByText(/Acceptable Use/i)).toBeInTheDocument();
  });

  it('exposes contact channels', () => {
    render(<ContactPage />);

    expect(
      screen.getByRole('heading', { level: 1, name: /Contact the AI Dev Platform team/i }),
    ).toBeInTheDocument();
    expect(screen.getByRole('link', { name: /Email sales/i })).toHaveAttribute(
      'href',
      'mailto:hello@ai-dev-platform.example',
    );
  });
});

import { render, screen, within } from '@testing-library/react';
import Home from '@/app/page';
import { features } from '@/data/feature-cards';

describe('Home page', () => {
  it('renders the hero headline and primary actions', () => {
    render(<Home />);

    expect(
      screen.getByRole('heading', {
        level: 1,
        name: /Ship trusted AI experiences faster with a platform teams love\./i,
      }),
    ).toBeInTheDocument();

    expect(screen.getByRole('link', { name: /Request Access/i })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: /Explore Features/i })).toBeInTheDocument();
  });

  it('highlights every feature from the shared fixture with learn more actions', () => {
    render(<Home />);

    const featureCards = screen.getAllByRole('article');

    expect(featureCards).toHaveLength(features.length);
    features.forEach((feature) => {
      const heading = screen.getByRole('heading', { level: 3, name: feature.title });

      expect(heading).toBeInTheDocument();

      const card = heading.closest('article');
      if (!card) {
        throw new Error(`Expected feature card article for ${feature.id}`);
      }

      feature.points.forEach((point) => {
        expect(screen.getByText(point)).toBeInTheDocument();
      });

      const learnMoreLink = within(card).getByRole('link', { name: /Learn more/i });

      expect(learnMoreLink).toHaveAttribute('href', `#${feature.id}`);
    });
  });

  it('renders the call-to-action section with contact options', () => {
    render(<Home />);

    const ctaSection = screen.getByRole('region', {
      name: /Ready to launch secure AI products\?/i,
    });

    expect(within(ctaSection).getByRole('heading', { level: 2 })).toBeInTheDocument();
    expect(within(ctaSection).getByRole('link', { name: /Talk to Sales/i })).toBeInTheDocument();
    expect(
      within(ctaSection).getByRole('link', { name: /View Documentation/i }),
    ).toBeInTheDocument();
  });
});

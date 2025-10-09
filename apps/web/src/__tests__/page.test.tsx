import { render, screen, within } from '@testing-library/react';
import Home from '@/app/page';

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

  it('highlights all feature cards with learn more actions', () => {
    render(<Home />);

    const featureCards = screen.getAllByRole('article');

    expect(featureCards).toHaveLength(3);
    featureCards.forEach((card) => {
      expect(within(card).getByRole('heading', { level: 3 })).toBeInTheDocument();
      expect(within(card).getByRole('link', { name: /Learn more/i })).toBeInTheDocument();
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

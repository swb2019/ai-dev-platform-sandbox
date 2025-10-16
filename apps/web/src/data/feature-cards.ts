import featureCardData from '@fixtures/web/feature-cards.json';

export interface FeatureCard {
  id: 'security' | 'ai' | 'modern-stack';
  title: string;
  badge: string;
  description: string;
  points: string[];
}

interface FeatureCardFixture {
  features: FeatureCard[];
}

const parsedFeatureCards = featureCardData as FeatureCardFixture;

export const features: FeatureCard[] = parsedFeatureCards.features;

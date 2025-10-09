module.exports = {
  extends: [require.resolve('./index.js'), 'plugin:@next/next/recommended', 'next/core-web-vitals'],
  rules: {
    '@next/next/no-html-link-for-pages': 'off',
    '@next/next/no-img-element': 'warn',
  },
};

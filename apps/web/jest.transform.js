const babel = require('@babel/core');

const STYLE_EXTENSIONS = ['.css', '.scss', '.sass'];

module.exports = {
  process(src, filename) {
    if (STYLE_EXTENSIONS.some((ext) => filename.endsWith(ext))) {
      return { code: 'module.exports = {};' };
    }

    const result = babel.transformSync(src, {
      filename,
      presets: [require.resolve('next/babel')],
      sourceMaps: 'inline',
      babelrc: false,
      configFile: false,
      caller: { name: 'jest-transform' },
    });

    if (!result) {
      return src;
    }

    return result;
  },
};

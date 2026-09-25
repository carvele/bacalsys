// https://docs.expo.dev/guides/using-eslint/
const { defineConfig } = require('eslint/config');
const expoConfig = require('eslint-config-expo/flat');

module.exports = defineConfig([
  expoConfig,
  {
    ignores: ['dist/*', 'android/*', 'ios/*'],
  },
  {
    files: ['src/**/*.tsx'],
    rules: {
      // Sprint 1 finding F-08: NativeWind drops className on Expo Router's <Link> on
      // iOS/Android (it only works on web). Use <TextLink> or <Link asChild>.
      'no-restricted-syntax': [
        'error',
        {
          selector: "JSXOpeningElement[name.name='Link'] > JSXAttribute[name.name='className']",
          message:
            'className on <Link> is ignored on iOS/Android. Use <TextLink> or <Link asChild> with a styled child (see findings/F-08).',
        },
      ],
    },
  },
]);

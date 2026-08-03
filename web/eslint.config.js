import js from '@eslint/js'
import prettier from 'eslint-config-prettier'
import reactHooks from 'eslint-plugin-react-hooks'
import reactRefresh from 'eslint-plugin-react-refresh'
import globals from 'globals'
import tseslint from 'typescript-eslint'

export default tseslint.config(
  { ignores: ['dist', 'node_modules', 'src/routeTree.gen.ts'] },
  {
    files: ['**/*.{ts,tsx}'],
    extends: [
      js.configs.recommended,
      ...tseslint.configs.recommendedTypeChecked,
      reactHooks.configs['recommended-latest'],
      reactRefresh.configs.vite,
      prettier,
    ],
    languageOptions: {
      ecmaVersion: 2023,
      globals: globals.browser,
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
    rules: {
      '@typescript-eslint/no-unused-vars': ['error', { argsIgnorePattern: '^_' }],
      // TanStack Router's `throw redirect(...)` / `throw notFound()` are idiomatic.
      '@typescript-eslint/only-throw-error': 'off',
      // Dexie table typings surface as `any` in some generic positions; keep the
      // unsafe-* family as warnings-off until the schema layer stabilizes them.
      '@typescript-eslint/no-unsafe-assignment': 'off',
      '@typescript-eslint/no-unsafe-member-access': 'off',
      '@typescript-eslint/no-misused-promises': [
        'error',
        { checksVoidReturn: { attributes: false } },
      ],
    },
  },
  {
    // `crypto.randomUUID` is [SecureContext]: undefined on a plain-http LAN
    // origin (`pnpm dev --host` from a phone), where it throws rather than
    // degrading. Shipping code must go through `@/lib/uuid`'s newId(), which
    // falls back to getRandomValues (not secure-context gated). Tests and
    // test-support helpers run in Node, where it always exists.
    files: ['src/**/*.{ts,tsx}'],
    ignores: ['**/*.test.{ts,tsx}', 'src/test/**', 'src/**/testSupport.ts', 'src/lib/uuid.ts'],
    rules: {
      'no-restricted-properties': [
        'error',
        {
          object: 'crypto',
          property: 'randomUUID',
          message: "Use newId() from '@/lib/uuid' — crypto.randomUUID is secure-context-only.",
        },
      ],
    },
  },
  {
    files: ['**/*.test.{ts,tsx}', 'src/test/**'],
    rules: {
      '@typescript-eslint/no-non-null-assertion': 'off',
      '@typescript-eslint/unbound-method': 'off',
      '@typescript-eslint/no-unsafe-argument': 'off',
    },
  },
)

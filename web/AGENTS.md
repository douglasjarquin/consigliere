# STATIC ASTRO DOCS SITE

The repository-level guidance in `../AGENTS.md` still applies, and this file records only web-specific seams that are easy to miss.

## DEPLOYMENT AND ROUTING

- Keep `astro.config.mjs` on static output with the `/consigliere` GitHub Pages base and the configured production site origin.
- Build every internal page and asset URL with `sitePath()` so local preview, Playwright, and GitHub Pages retain the same trailing-slash base contract.
- Use relative route URLs against Playwright's configured base URL, and assert `/consigliere/.../` when the prefix itself is part of the behavior under test.
- Treat `web/dist/` as the disposable static package consumed by preview and the Pages artifact upload.

## SOURCE OWNERSHIP

- `src/layouts/SiteLayout.astro` owns the document shell, metadata, theme bootstrap, `SiteHeader`, `SiteFooter`, command palette, nav drawer, shortcut sheet, and the single import of `global.css`.
- `src/lib/pages.mjs` owns the docs IA: sidebar groups, page metadata, and design-file href mapping.
- `src/lib/rewrite.mjs` rewrites design-canvas hrefs onto `sitePath()` URLs at build time.
- `src/content/` holds cleaned design HTML for each route; do not edit those files to change chrome, only page prose and page-local structure.
- Keep shared tokens, skip link, shell layout, overlays, and responsive rules in `src/styles/global.css`.
- `src/scripts/site-chrome.mjs` owns theme, palette, drawer, shortcuts, copy buttons, and TOC scroll-spy.

## ACCESSIBILITY AND FALLBACKS

- Keep every route useful as static HTML before client scripts run, with native links, headings, landmarks, and readable content.
- Preserve `aria-current`, visible `:focus-visible` treatment, Escape-to-close, and the skip link.
- Respect reduced motion by removing transitions and overlay animations.
- Prefer logical CSS properties and verify both desktop and mobile behavior when changing shared layout.

## AUBE AND MISE BOUNDARIES

- From the repository root, use the `mise run web:*` tasks so Node 24 and Aube 2.2.4 come from the pinned toolchain.
- From `web/`, use `aube run <script>` or use `aube -C web ...` from the root for focused package scripts.
- Treat `aubr` as package-script composition used inside `package.json`, not as the repository-level entry point.
- Install from `aube-lock.yaml` with `mise run web:install`.
- Keep `web/.npmrc` on `node-linker=hoisted` so Astro prerender can resolve native bindings and client entry files from an npm-compatible tree.
- Keep `astro check`, unit tests, browser tests, and the production build as separate evidence because none substitutes for another.

## STABLE LOCAL DOMAIN (PORTLESS)

- `mise run web:dev:local` runs the Astro dev server through [portless](https://github.com/vercel-labs/portless) at `https://consigliere.test` instead of a raw port. Run `web:install` first so portless can invoke the `dev` script through the aube-managed tree.
- The project TLD is `.test`, pinned via `PORTLESS_TLD=test` in the task itself. Deliberately not `.local`: portless's own docs warn it conflicts with mDNS/Bonjour.
- `ASTRO_DEV_BACKGROUND=1` is set in the task deliberately: Astro 7's `astro dev` auto-daemonizes when it detects an agentic environment, which makes the wrapping process exit immediately and breaks portless's route registration.

## TEST SURFACES AND OWNED SERVERS

- `tests/unit/*.test.mjs` are Node tests for config, SEO artifacts, and link rewriting without a browser page.
- `tests/e2e/*.spec.mjs` are Playwright tests against a production build served under `/consigliere/` in desktop Chromium.
- Use `aube -C web run test:unit` or `test:e2e` for a focused layer, while `mise run web:test` runs both layers in sequence.
- Playwright builds and starts its own Astro preview on `PLAYWRIGHT_PORT`, which defaults to `4321`.
- The Playwright preview command passes `--ignore-lock` so concurrent E2E runs on different `PLAYWRIGHT_PORT` values can start independent preview servers.

## GENERATED OUTPUTS

- Treat `node_modules/`, `.astro/`, `dist/`, `test-results/`, and `playwright-report/` as generated dependency, cache, build, or diagnostic output rather than source.

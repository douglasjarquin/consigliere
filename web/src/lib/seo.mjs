import astroConfig from "../../astro.config.mjs";
import { DOCS_PAGES } from "./pages.mjs";

export const SITE_ORIGIN = astroConfig.site;
export const SITE_BASE = `${astroConfig.base.replace(/\/+$/, "")}/`;
export const PRODUCT_NAME = "Consigliere";
export const PRODUCT_DESCRIPTION =
  "A personal agent distro: persistent capos, isolated soldiers, and durable supervision. It never merges without you.";
export const REPOSITORY_URL = "https://github.com/douglasjarquin/consigliere";
export const MADE_URL = "https://github.com/douglasjarquin/made";
export const PRODUCT_OPERATING_SYSTEM = "Linux, macOS";

export const INDEXABLE_PATHS = Object.freeze([
  SITE_BASE,
  ...DOCS_PAGES.map(({ slug }) => `${SITE_BASE}${slug}/`),
]);

export function withTrailingSlash(pathname) {
  const withoutIndex = pathname.replace(/\/index\.html$/, "/");
  return withoutIndex.endsWith("/") ? withoutIndex : `${withoutIndex}/`;
}

export function canonicalUrl(pathname) {
  return new URL(withTrailingSlash(pathname), SITE_ORIGIN).href;
}

export function absoluteUrl(pathname) {
  return new URL(pathname, SITE_ORIGIN).href;
}

export function sitemapLocation() {
  return absoluteUrl(`${SITE_BASE}sitemap.xml`);
}

export function robotsTxt() {
  return `User-agent: *\nAllow: ${SITE_BASE}\n\nSitemap: ${sitemapLocation()}\n`;
}

export function sitemapXml() {
  const entries = INDEXABLE_PATHS.map(
    (pathname) => `  <url>\n    <loc>${canonicalUrl(pathname)}</loc>\n  </url>`,
  ).join("\n");
  return `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${entries}\n</urlset>\n`;
}

export function llmsTxt() {
  const liveUrl = canonicalUrl(SITE_BASE);
  const pageLines = [
    `- [Home](${liveUrl})`,
    ...DOCS_PAGES.map(
      (page) => `- [${page.title}](${canonicalUrl(`${SITE_BASE}${page.slug}/`)})`,
    ),
  ].join("\n");
  return `# Consigliere

> ${PRODUCT_DESCRIPTION}

Consigliere is a personal agent distro for two harnesses (codex and claude) and one terminal runtime (herdr). Launch either harness in this repo and it becomes the boss's single point of contact for software work.

Live site: ${liveUrl}
Repository: ${REPOSITORY_URL}

Clone and start:

\`\`\`
git clone https://github.com/douglasjarquin/consigliere.git
bin/cs-install-herdr.sh ~/.local/bin
bin/cs-doctor.sh
\`\`\`

## Pages

${pageLines}
`;
}

export function productJsonLd() {
  const url = canonicalUrl(SITE_BASE);
  return {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "WebSite",
        name: PRODUCT_NAME,
        url,
        description: PRODUCT_DESCRIPTION,
      },
      {
        "@type": "SoftwareApplication",
        name: PRODUCT_NAME,
        url,
        description: PRODUCT_DESCRIPTION,
        applicationCategory: "DeveloperApplication",
        operatingSystem: PRODUCT_OPERATING_SYSTEM,
        downloadUrl: REPOSITORY_URL,
        codeRepository: REPOSITORY_URL,
      },
    ],
  };
}

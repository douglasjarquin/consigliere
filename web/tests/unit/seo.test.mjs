import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { DOCS_PAGES } from "../../src/lib/pages.mjs";
import {
  INDEXABLE_PATHS,
  PRODUCT_DESCRIPTION,
  PRODUCT_NAME,
  PRODUCT_OPERATING_SYSTEM,
  REPOSITORY_URL,
  SITE_BASE,
  SITE_ORIGIN,
  canonicalUrl,
  llmsTxt,
  productJsonLd,
  robotsTxt,
  sitemapLocation,
  sitemapXml,
  withTrailingSlash,
} from "../../src/lib/seo.mjs";

const publicDirectory = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../public");

test("canonical URLs are HTTPS trailing-slash addresses without index.html", () => {
  assert.equal(SITE_ORIGIN, "https://douglasjarquin.github.io");
  assert.equal(SITE_BASE, "/consigliere/");
  assert.equal(withTrailingSlash("/consigliere/index.html"), "/consigliere/");
  assert.equal(withTrailingSlash("/consigliere/architecture"), "/consigliere/architecture/");
  assert.equal(
    canonicalUrl("/consigliere/index.html"),
    "https://douglasjarquin.github.io/consigliere/",
  );
});

test("robots.txt allows the project path and points at the project sitemap", () => {
  const committed = readFileSync(path.join(publicDirectory, "robots.txt"), "utf8");
  assert.equal(committed, robotsTxt());
  assert.match(committed, /^User-agent: \*\nAllow: \/consigliere\/\n\nSitemap: /);
  assert.equal(sitemapLocation(), "https://douglasjarquin.github.io/consigliere/sitemap.xml");
  assert.doesNotMatch(committed, /Allow: \/\n/);
});

test("sitemap.xml lists every indexable trailing-slash URL", () => {
  const committed = readFileSync(path.join(publicDirectory, "sitemap.xml"), "utf8");
  assert.equal(committed, sitemapXml());
  assert.deepEqual(
    INDEXABLE_PATHS.map((pathname) => canonicalUrl(pathname)),
    [
      "https://douglasjarquin.github.io/consigliere/",
      ...DOCS_PAGES.map(
        (page) => `https://douglasjarquin.github.io/consigliere/${page.slug}/`,
      ),
    ],
  );
});

test("llms.txt names the product, live site, and repository", () => {
  const committed = readFileSync(path.join(publicDirectory, "llms.txt"), "utf8");
  assert.equal(committed, llmsTxt());
  assert.match(committed, /^# Consigliere\n/);
  assert.match(committed, /Live site: https:\/\/douglasjarquin\.github\.io\/consigliere\//);
  assert.match(committed, /Repository: https:\/\/github\.com\/douglasjarquin\/consigliere/);
});

test("JSON-LD describes the visible site and software without ratings or offers", () => {
  const jsonLd = productJsonLd();
  const serialized = JSON.stringify(jsonLd);
  assert.equal(jsonLd["@context"], "https://schema.org");
  assert.deepEqual(
    jsonLd["@graph"].map((node) => node["@type"]),
    ["WebSite", "SoftwareApplication"],
  );
  const [website, software] = jsonLd["@graph"];
  for (const node of jsonLd["@graph"]) {
    assert.equal(node.name, PRODUCT_NAME);
    assert.equal(node.description, PRODUCT_DESCRIPTION);
    assert.equal(node.url, "https://douglasjarquin.github.io/consigliere/");
    assert.equal("aggregateRating" in node, false);
    assert.equal("offers" in node, false);
  }
  assert.equal("operatingSystem" in website, false);
  assert.equal(software.operatingSystem, PRODUCT_OPERATING_SYSTEM);
  assert.equal(software.downloadUrl, REPOSITORY_URL);
  assert.equal(software.codeRepository, REPOSITORY_URL);
  assert.doesNotMatch(serialized, /aggregateRating|offers|"ratingValue"/);
});

import assert from "node:assert/strict";
import { readdirSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { DOCS_PAGES } from "../../src/lib/pages.mjs";
import { rewriteHtml } from "../../src/lib/rewrite.mjs";

test("design-canvas hrefs become trailing-slash site paths", () => {
  const html = rewriteHtml(
    '<a href="Home C.dc.html">home</a><a href="Quick Start.dc.html">start</a><a href="#color">jump</a><a href="https://github.com/douglasjarquin/consigliere">gh</a>',
  );
  assert.match(html, /href="\/consigliere\/"/);
  assert.match(html, /href="\/consigliere\/quick-start\/"/);
  assert.match(html, /href="#color"/);
  assert.match(html, /href="https:\/\/github.com\/douglasjarquin\/consigliere"/);
  assert.doesNotMatch(html, /\.dc\.html/);
});

test("every content file has a matching page slug", () => {
  const directory = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../src/content");
  const files = readdirSync(directory).filter((name) => name.endsWith(".html"));
  const slugs = new Set(["home", "404", ...DOCS_PAGES.map((page) => page.slug)]);
  for (const file of files) {
    assert.equal(slugs.has(file.replace(/\.html$/, "")), true, `${file} is missing from page metadata`);
  }
});

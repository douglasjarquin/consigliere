import assert from "node:assert/strict";
import test from "node:test";

test("Astro config uses the GitHub Pages static deployment contract", async () => {
  const config = await import("../../astro.config.mjs");

  assert.equal(config.default.base, "/consigliere");
  assert.equal(config.default.output, "static");
  assert.equal(config.default.site, "https://douglasjarquin.github.io");
});

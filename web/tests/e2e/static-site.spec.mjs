import { expect, test } from "@playwright/test";

const routes = [
  {
    path: "./",
    title: "Consigliere",
    canonical: "https://douglasjarquin.github.io/consigliere/",
  },
  {
    path: "./quick-start/",
    title: "Quick start | Consigliere",
    canonical: "https://douglasjarquin.github.io/consigliere/quick-start/",
  },
  {
    path: "./architecture/",
    title: "Architecture | Consigliere",
    canonical: "https://douglasjarquin.github.io/consigliere/architecture/",
  },
];

test("indexable routes publish unique titles and canonical URLs", async ({ page }) => {
  const titles = [];
  for (const route of routes) {
    await page.goto(route.path);
    await expect(page).toHaveTitle(route.title);
    await expect(page.locator('link[rel="canonical"]')).toHaveAttribute("href", route.canonical);
    await expect(page.locator('meta[property="og:url"]')).toHaveAttribute("content", route.canonical);
    titles.push(route.title);
  }
  expect(new Set(titles).size).toBe(routes.length);
});

test("index.html duplicates canonicalise to the trailing-slash home URL", async ({ page }) => {
  await page.goto("index.html");
  await expect(page.locator('link[rel="canonical"]')).toHaveAttribute(
    "href",
    "https://douglasjarquin.github.io/consigliere/",
  );
});

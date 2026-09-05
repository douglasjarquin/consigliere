import { expect, test } from "@playwright/test";

test("the home is the manifesto landing", async ({ page }) => {
  await page.goto("./");
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(
    "You describe the work. You give the word. Nothing else is yours to carry.",
  );
  await expect(page.getByRole("link", { name: "Begin →" })).toHaveAttribute(
    "href",
    "/consigliere/quick-start/",
  );
  await expect(page.getByRole("banner").getByRole("link", { name: "Consigliere" })).toHaveAttribute(
    "href",
    "/consigliere/",
  );
});

test("the home remains useful without client JavaScript", async ({ browser }) => {
  const context = await browser.newContext({
    baseURL: `http://127.0.0.1:${process.env.PLAYWRIGHT_PORT ?? "4321"}/consigliere/`,
    javaScriptEnabled: false,
  });
  const page = await context.newPage();
  try {
    await page.goto("./");
    await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
    await expect(page.getByRole("link", { name: "Begin →" })).toBeVisible();
  } finally {
    await context.close();
  }
});

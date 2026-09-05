import { expect, test } from "@playwright/test";

test("quick start keeps the docs sidebar and numbered steps", async ({ page }) => {
  await page.goto("./quick-start/");
  await expect(page.getByRole("heading", { level: 1 })).toHaveText("Quick start");
  const sidebar = page.getByRole("complementary", { name: "Section" });
  await expect(sidebar.getByRole("link", { name: "Quick start" })).toHaveAttribute(
    "aria-current",
    "page",
  );
  await expect(page.locator("pre").first()).toContainText(
    "git clone https://github.com/douglasjarquin/consigliere.git",
  );
});

test("docs chrome marks the current top-nav section", async ({ page }) => {
  await page.goto("./architecture/");
  await expect(page.getByRole("navigation", { name: "Primary" }).getByRole("link", { name: "Docs" })).toHaveAttribute(
    "aria-current",
    "page",
  );
});

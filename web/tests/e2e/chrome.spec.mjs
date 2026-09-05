import { expect, test } from "@playwright/test";

test("the skip link reaches main content", async ({ page }) => {
  await page.goto("./");
  const skip = page.getByRole("link", { name: "Skip to content" });
  await page.keyboard.press("Tab");
  await expect(skip).toBeFocused();
  await skip.press("Enter");
  await expect(page.locator("#main-content")).toBeInViewport();
});

test("theme toggle flips the document theme", async ({ page }) => {
  await page.goto("./");
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  await page.getByRole("button", { name: "Lights on" }).click();
  await expect(page.locator("html")).toHaveAttribute("data-theme", "light");
  await expect(page.getByRole("button", { name: "Lights off" })).toBeVisible();
});

test("command palette searches pages", async ({ page }) => {
  await page.goto("./");
  await page.keyboard.press("Meta+k");
  const dialog = page.getByRole("dialog", { name: "Search pages and commands" });
  await expect(dialog).toBeVisible();
  await dialog.getByPlaceholder("Search pages and commands…").fill("quick");
  await expect(dialog.getByRole("link", { name: /Quick start/ })).toBeVisible();
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL(/\/quick-start\/\/?$/);
});

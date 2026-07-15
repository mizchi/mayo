import { expect, test } from "@playwright/test";

test("MoonBit host dispatches prebuilt MoonBit Workers in a browser", async ({ page }) => {
  const pageErrors: Error[] = [];
  page.on("pageerror", (error) => pageErrors.push(error));

  const response = await page.goto("/");
  expect(response?.ok()).toBe(true);
  expect(await page.evaluate(() => globalThis.crossOriginIsolated)).toBe(true);

  const status = page.getByTestId("status");
  await expect(status).toHaveAttribute("data-state", "passed");
  await expect(status).toContainText("3 Workers, epochs 1 and 2");
  expect(pageErrors).toEqual([]);
});

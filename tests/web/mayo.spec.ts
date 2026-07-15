import { expect, test } from "@playwright/test";

test("MoonBit host calls range, JS, and Wasm guests in a browser", async ({ page }) => {
  const pageErrors: Error[] = [];
  page.on("pageerror", (error) => pageErrors.push(error));

  const response = await page.goto("/");
  expect(response?.ok()).toBe(true);
  expect(await page.evaluate(() => globalThis.crossOriginIsolated)).toBe(true);

  const status = page.getByTestId("status");
  await expect(status).toHaveAttribute("data-state", "passed");
  await expect(status).toContainText("range pool, typed JS guest, and typed Wasm guest");
  expect(pageErrors).toEqual([]);
});

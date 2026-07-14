import assert from "node:assert/strict";

async function runSelfTest(executable: string, backend: string): Promise<void> {
  const command = new Deno.Command(executable, {
    args: ["--backend", backend, "--self-test"],
    stdout: "piped",
    stderr: "piped",
  });
  const output = await command.output();
  const stderr = new TextDecoder().decode(output.stderr);
  assert.equal(output.success, true, stderr);
  assert.match(new TextDecoder().decode(output.stdout), /self-test ok/);
}

Deno.test("C pthread and mmap process pools satisfy the transform contract", async () => {
  await runSelfTest("./dist/c-bench", "pthread");
  await runSelfTest("./dist/c-bench", "mmap");
});

Deno.test("Rust std and Rayon pools satisfy the transform contract", async () => {
  await runSelfTest("./dist/rust-bench", "std");
  await runSelfTest("./dist/rust-bench", "rayon");
});

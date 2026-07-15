name = "mizchi/mayo"

version = "0.1.0"

import {
  "moonbitlang/async@0.19.2",
}

source = "."

readme = "README.md"

keywords = [
  "moonbit",
  "web",
  "browser",
  "deno",
  "node",
  "bun",
  "wasm",
  "atomics",
  "worker",
  "parallelism",
  "shared-memory",
]

description = "Zero-copy data-parallel Worker pool for MoonBit on Web, Deno, Node, and Bun"

license = "MIT"

repository = "https://github.com/mizchi/mayo"

preferred_target = "js"

options(
  exclude: [
    ".github",
    "bench",
    "examples",
    "native",
    "src",
    "tests",
    "tools",
    "worker",
    "deno.json",
    "host_client_wbtest.mbt",
    "justfile",
    "mayo.build.json",
    "package.json",
    "playwright.config.ts",
    "pnpm-lock.yaml",
  ],
)

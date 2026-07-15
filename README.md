# mayo

[日本語](./README.ja.md)

Mayo is an experimental data-parallel Worker pool for MoonBit's JavaScript backend. Both the host
client and Worker kernel are written in MoonBit, compiled ahead of time to JavaScript, and run in a
modern web browser or Deno.

Data and task descriptors are shared through `SharedArrayBuffer`. Persistent Workers sleep and wake
through JavaScript Atomics, so Worker startup is amortized across many batches. The long-term goal
is a Rayon-like MoonBit API; the current scheduler uses static, non-overlapping chunks rather than
work stealing.

> [!WARNING]
> Mayo is experimental. MoonBit heap objects, closures, and ordinary objects are not shared across
> Workers. The current contract shares one `Int32Array`-backed `SharedSlice` and one `Int` argument
> per dispatch.

## Runtime support

| Host runtime | Pool creation     | Dispatch API                             | Requirement                           |
| ------------ | ----------------- | ---------------------------------------- | ------------------------------------- |
| Web document | `Pool::create`    | `Pool::run_async`                        | Cross-origin isolation (COOP + COEP)  |
| Deno         | `Pool::create`    | `Pool::run` (recommended) or `run_async` | `--allow-read` for local Worker files |
| Node.js      | Not supported yet | —                                        | A Worker adapter is planned           |

[`Atomics.wait`](https://tc39.es/ecma262/multipage/structured-data.html#sec-atomics.wait) blocks and
is not permitted on a browser document main thread. Mayo therefore uses
[`Atomics.waitAsync`](https://tc39.es/ecma262/multipage/structured-data.html#sec-atomics.waitasync)
for browser dispatch and falls back to timer-based asynchronous polling when the runtime does not
expose it. Calling synchronous `Pool::run` from a web document raises `PoolError::InvalidArgument`
with a message directing the caller to `run_async`.

## Architecture

```text
MoonBit host client                         MoonBit Worker kernel
  Pool::create / run_async                    @mayo.start(kernel)
           │                                           │
           └──── compile with MoonBit JS backend ──────┘
                              │
                    Browser or Deno runtime
                              │
                 SharedArrayBuffer (zero-copy)
                   ├─ Worker 0 control slot
                   ├─ Worker 1 control slot
                   └─ Int32 data region
```

Each Worker sleeps until the epoch in its control slot changes. A dispatch partitions `[start, end)`
into non-overlapping ranges and completes when every Worker publishes the expected done epoch.

Only the runtime boundary that touches `Worker`, `SharedArrayBuffer`, Atomics, promises, and
`performance.now()` is JavaScript FFI. Option validation, range partitioning, lifecycle state, and
dispatch are implemented in MoonBit.

## Usage

### 1. Write a MoonBit Worker kernel

[`examples/mix_worker/main.mbt`](./examples/mix_worker/main.mbt) applies an LCG transform to every
element in the assigned range:

```moonbit
fn kernel(
  values : @mayo.SharedSlice,
  start : Int,
  end : Int,
  rounds : Int,
) -> Unit {
  for index = start; index < end; index = index + 1 {
    let mut value = values.load(index)
    for round = 0; round < rounds; round = round + 1 {
      value = mix(value)
    }
    values.store(index, value)
  }
}

fn main {
  @mayo.start(kernel)
}
```

`start` and `end` are logical indices into the shared slice. Worker ranges never overlap, so
`SharedSlice::load` and `store` intentionally use non-atomic element access.

### 2. Use Mayo in a web document

[`examples/web/main.mbt`](./examples/web/main.mbt) is a MoonBit browser client:

```moonbit
async fn main {
  let pool = @mayo.Pool::create(
    @mayo.pool_options(
      "./mayo_worker.js",
      capacity=1048576,
      worker_count=4,
    ),
  )
  defer {
    pool.close()
  }

  let values = pool.values()
  values.fill(1)
  let result = pool.run_async(end=values.length(), argument=64)
  println("dispatch: \{result.elapsed_ms} ms")
}
```

Serve the document and every Worker/subresource with
[cross-origin isolation](https://html.spec.whatwg.org/multipage/webappapis.html#cross-origin-isolated-capability)
enabled. A minimal same-origin configuration uses these response headers:

```http
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
Cross-Origin-Resource-Policy: same-origin
```

The repository includes a working server and a browser test:

```console
pnpm install
pnpm exec playwright install chromium firefox webkit
just serve-web   # open http://127.0.0.1:4173
just test-web    # Chromium, Firefox, and WebKit integration
```

The Playwright test runs on Chromium, Firefox, and WebKit. It verifies `crossOriginIsolated`, starts
three prebuilt MoonBit Workers, dispatches two batches through `run_async`, and checks epochs and
all shared-buffer values.

### 3. Use Mayo in Deno

[`examples/host/main.mbt`](./examples/host/main.mbt) uses the same MoonBit API. Deno permits
`Atomics.wait` on its main agent, so synchronous `run` gives the lowest dispatch overhead:

```moonbit
let result = pool.run(end=values.length(), argument=64)
```

Build and run the Deno example with:

```console
just example
```

The Worker URL is resolved relative to the generated host module's `import.meta.url`. Local Worker
files require Deno's `--allow-read` permission.

### Host package configuration

Browser and Deno clients both import MoonBit's async runtime because `Pool::create` and `run_async`
are async:

```moonbit
import {
  "mizchi/mayo" @mayo,
  "moonbitlang/async",
}

supported_targets = "js"

pkgtype(kind: "executable")
```

## Public API

### Host

- `pool_options(worker_url, capacity~, worker_count?=4, timeout_ms?=30000)`
- `Pool::create(options)`
- `Pool::values() -> SharedSlice`
- `Pool::run(start?=0, end~, argument?=0) -> RunResult` — blocking Deno API
- `Pool::run_async(start?=0, end~, argument?=0) -> RunResult` — browser-safe API
- `Pool::worker_count()` / `Pool::capacity()`
- `Pool::close()`
- `PoolError::{InvalidArgument, WorkerFailed, Timeout, Closed, Busy}`

Only one batch may run on a pool at a time. Ranges are validated against the shared data region.

### Worker

- `@mayo.start(kernel)` — installs the Mayo Worker protocol
- `@mayo.SharedSlice` — shared data view without the private control region
- `SharedSlice::length()` / `load(index)` / `store(index, value)` / `fill(value)`
- `@mayo.run_worker(...)` — low-level entry point for composite Workers

## Current limitations

- Shared data is limited to an `Int32Array`.
- Kernels must be compiled ahead of time as Worker modules.
- A batch carries one additional `Int` argument.
- Scheduling uses static chunks; dynamic chunks and work stealing are not implemented.
- In-flight cancellation, Worker crash recovery, and kernel panic propagation are not implemented.
- MoonBit has no equivalent of Rust's `Send` / `Sync` checking for this boundary.
- Web pages must be cross-origin isolated; third-party subresources must also satisfy the selected
  embedder policy.
- Node.js is not supported yet.

Static chunks work well for uniform array processing. Uneven or recursively generated tasks will
need dynamic scheduling and eventually work stealing.

## Development

```console
just test          # MoonBit, Deno, browser, Rust, and C contract tests
just check         # formatting, linting, type checks, native checks, and tests
just test-web      # Playwright Chromium / Firefox / WebKit integration
just serve-web     # COOP/COEP web example server
just example       # Deno host example
just compare 4     # pthread / mmap process / Rust / Rayon comparison
just bench         # Worker startup and contended-mutex experiments
```

Repository layout:

```text
host_client.mbt, host_runtime_js.mbt  MoonBit host API and JavaScript boundary
atomics_js.mbt, mayo.mbt              shared memory and Worker loop
protocol.mbt, start.mbt               control protocol and Worker entry point
examples/web/                         MoonBit browser client
examples/host/                        MoonBit Deno client
examples/mix_worker/                  MoonBit kernel
tests/web/                            COOP/COEP server and Playwright test
tests/client/                         MoonBit-to-MoonBit Deno integration test
worker/, bench/                       internal measurements
native/                               C pthread/mmap and Rust std/Rayon baselines
```

## Benchmark

`just compare 4` creates each pool and shared region once. Timed batches only publish a range and
round count; Worker/process startup and data copying are excluded. Mayo's benchmark host is also
MoonBit, compiled from `bench/mayo/main.mbt` and executed by Deno.

Median of five independent runs on 2026-07-15: Mac17,2, 32 GiB, 10 logical CPUs, darwin-aarch64,
Deno 2.6.4, MoonBit 0.1.20260713.

| backend         | dispatch p50 | dispatch p95 | memory bandwidth | compute throughput |
| --------------- | -----------: | -----------: | ---------------: | -----------------: |
| C pthread       |      10.0 µs |      20.0 µs |      102.8 GiB/s |        8.28 Gops/s |
| C mmap process  |      11.0 µs |      22.0 µs |      103.1 GiB/s |        8.32 Gops/s |
| Rust std pool   |      9.58 µs |      20.3 µs |       81.9 GiB/s |        9.73 Gops/s |
| Rust Rayon      |      17.5 µs |      80.4 µs |       82.1 GiB/s |        7.64 Gops/s |
| MoonBit message |      37.8 µs |      59.0 µs |       18.5 GiB/s |        8.54 Gops/s |
| Mayo            |      9.87 µs |      22.3 µs |       26.1 GiB/s |        8.69 Gops/s |

In this run, Mayo's dispatch p50 was 0.99× pthread and compute throughput was 1.05× pthread. The
single-operation memory case reached 25.4% of pthread bandwidth, where generated JavaScript and V8's
typed-array loop trail native vectorized loops. Treat local `just compare` results as authoritative;
core assignment, temperature, power state, and runtime versions materially affect these numbers.

## Roadmap

1. POD descriptors for multiple arguments and shared slices
2. Dynamic chunk counters with configurable grain size
3. A task ring and sleep/wake protocol in shared memory
4. Per-Worker Chase–Lev deques and work stealing
5. Error propagation, cancellation, and task recovery
6. Higher-level `par_for` and `par_chunks` APIs
7. A Node.js Worker adapter

Inspired by
[an experiment using shared memory and mutexes with Rust/Wasm](https://zenn.dev/grainrigi/articles/b7c2320ef13c71).

## License

MIT

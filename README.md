# mayo

[日本語](./README.ja.md)

Mayo is an experimental zero-copy data-parallel Worker pool for MoonBit, inspired by Rayon.

- MoonBit/JS hosts and prebuilt Workers
- MoonBit/Wasm kernels over shared `WebAssembly.Memory`
- Deno and cross-origin-isolated web pages
- Persistent Workers coordinated with JavaScript Atomics

Bulk data stays in shared `Int32` memory. A dispatch sends only a kernel ID, range, and one `Int`
argument.

> [!WARNING]
> Mayo does not share MoonBit heap objects, closures, strings, or ordinary arrays. Store structured
> data as explicit offsets and lengths inside shared memory.

## Example

Define a descriptor package shared by the Host and Worker builds:

```moonbit
fn scale_spec() -> @mayo.KernelSpec {
  @mayo.kernel_spec(id=1, layout_hash=0x5343414C)
}

pub fn manifest() -> @mayo.KernelManifest {
  @mayo.kernel_manifest("my-app/kernels/v1", [scale_spec()])
}

pub fn scale(factor~ : Int) -> @mayo.KernelCall {
  @mayo.kernel_call(manifest(), scale_spec(), argument=factor)
}

pub fn scale_entry(
  implementation : (@mayo.SharedSlice, Int, Int, Int) -> Unit,
) -> @mayo.KernelEntry {
  @mayo.kernel_entry(scale_spec(), implementation)
}
```

Compile the Worker ahead of time:

```moonbit
fn scale_range(
  values : @mayo.SharedSlice,
  start : Int,
  end : Int,
  factor : Int,
) {
  for index = start; index < end; index = index + 1 {
    values.store(index, values.load(index) * factor)
  }
}

fn main {
  @mayo.serve_kernels(
    @kernels.manifest(),
    [@kernels.scale_entry(scale_range)],
  )
}
```

Open the pool from MoonBit and dispatch the kernel:

```moonbit
async fn main {
  let threads = @mayo.ThreadPool::open(
    @kernels.manifest(),
    "./worker.js",
    capacity=1_000_000,
    workers=4,
  )
  defer threads.close()

  let values = threads.shared_i32()
  values.fill(2)
  let result = values.par_for(@kernels.scale(factor=3))
  println("dispatch: \{result.elapsed_ms} ms")
}
```

Host and Worker startup fails when their manifests, kernel IDs, or layout hashes differ.

## Image pipeline example

The real-world example runs grayscale conversion and Sobel edge detection over a shared 640x360 RGB
frame. The intermediate image remains in a second shared-memory plane.

```console
just example-image
```

See the shared [image contract](./examples/image_pipeline/pipeline.mbt),
[Worker kernels](./examples/image_worker/main.mbt), and
[MoonBit Host](./examples/image_host/main.mbt).

For structured concurrency, see the runnable [scope example](./examples/scope_host) or run
`just example-scope`.

## Runtime support

| Runtime | Status    | Requirement                           |
| ------- | --------- | ------------------------------------- |
| Deno    | Supported | `--allow-read` for local Worker files |
| Web     | Supported | COOP/COEP cross-origin isolation      |
| Node.js | Not yet   | Worker adapter is planned             |

JavaScript Workers use the `mayo.kernel/v1` manifest ABI. Wasm kernels use the lower-level shared
memory API; see [the Wasm example](./examples/wasm_host/main.mbt).

JSON RPC exists only as an optional compatibility package under [`json`](./json). It is not part of
the zero-copy API.

## Current limitations

- Shared application data is currently `Int32` only.
- Descriptor packages are written manually.
- Each dispatch has one range and one extra `Int` argument.
- Scheduling uses static chunks; there is no work stealing yet.
- Cancellation, Worker recovery, and kernel panic propagation are not implemented.
- Wasm kernels must be allocation-free and cannot share the MoonBit heap.
- Web pages must be cross-origin isolated.

## Development

```console
just check          # all checks and tests
just example        # MoonBit/JS Deno example
just example-scope  # structured concurrency
just example-image  # shared RGB image pipeline
just example-wasm   # MoonBit/JS Host + MoonBit/Wasm kernel
just serve-web      # web example with COOP/COEP
just compare 4      # pthread, mmap process, Rust, Rayon, and Mayo
```

The browser suite runs in Chromium, Firefox, and WebKit.

## Documentation

- [Kernel ABI v1](./docs/kernel-abi-v1.md)
- [Japanese Kernel ABI v1](./docs/kernel-abi-v1.ja.md)
- [Benchmark sources](./bench)

Inspired by
[an experiment using shared memory and mutexes with Rust/Wasm](https://zenn.dev/grainrigi/articles/b7c2320ef13c71).

## License

MIT

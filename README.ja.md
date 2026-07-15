# mayo

[English](./README.md)

MayoはRayonに着想を得た、MoonBit向けの実験的なzero-copyデータ並列Worker poolです。

- MoonBit/JS製Hostと事前ビルドWorker
- shared `WebAssembly.Memory`上で動くMoonBit/Wasm kernel
- Denoとcross-origin isolatedなWeb page
- JavaScript Atomicsで同期する常駐Worker

bulk dataはshared `Int32` memoryに残し、dispatchではkernel ID、range、1つの`Int` argumentだけを
通知します。

> [!WARNING]
> MoonBit heap object、closure、String、通常のArrayは共有しません。構造化dataはshared memory内の
> offsetとlengthで明示的に表現します。

## Example

HostとWorkerの両方がimportするdescriptor packageを定義します。

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

Workerを事前コンパイルします。

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

MoonBit製Hostからpoolを開き、kernelをdispatchします。

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

HostとWorkerのmanifest、kernel ID、layout hashが異なる場合は起動またはdispatch時に失敗します。

## Image pipeline example

実用例ではshared 640x360 RGB frameにgrayscale変換とSobel edge detectionを適用します。中間画像も
2つ目のshared-memory planeに残します。

```console
just example-image
```

共有する[image contract](./examples/image_pipeline/pipeline.mbt)、
[Worker kernel](./examples/image_worker/main.mbt)、[MoonBit Host](./examples/image_host/main.mbt)を参照してください。

structured concurrencyは実行可能な[scope example](./examples/scope_host)または
`just example-scope`を参照してください。

## Runtime support

| Runtime | Status | 必要条件                              |
| ------- | ------ | ------------------------------------- |
| Deno    | 対応   | local Worker fileへの`--allow-read`   |
| Web     | 対応   | COOP/COEPによるcross-origin isolation |
| Node.js | 未対応 | Worker adapterを予定                  |

JavaScript Workerは`mayo.kernel/v1` manifest ABIを使います。Wasm kernelは低レベルshared-memory
APIを使います。[Wasm example](./examples/wasm_host/main.mbt)を参照してください。

JSON RPCは[`json`](./json)以下のoptional compatibility packageだけで提供します。zero-copy APIには
含めません。

## 現在の制約

- shared application dataは現在`Int32`のみ
- descriptor packageは手書き
- 1 dispatchは1 rangeと追加の`Int` argumentを持つ
- schedulerはstatic chunk。work stealingは未実装
- cancel、Worker recovery、kernel panic propagationは未実装
- Wasm kernelはallocation-freeとし、MoonBit heapを共有できない
- Web pageはcross-origin isolatedである必要がある

## 開発

```console
just check          # 全checkとtest
just example        # MoonBit/JS Deno example
just example-scope  # structured concurrency
just example-image  # shared RGB image pipeline
just example-wasm   # MoonBit/JS Host + MoonBit/Wasm kernel
just serve-web      # COOP/COEP付きWeb example
just compare 4      # pthread、mmap process、Rust、Rayon、Mayo
```

browser suiteはChromium、Firefox、WebKitで実行します。

## Documentation

- [Kernel ABI v1 日本語版](./docs/kernel-abi-v1.ja.md)
- [Kernel ABI v1 English](./docs/kernel-abi-v1.md)
- [benchmark source](./bench)

着想元:
[Rust/Wasmでshared memoryとMutexを使う実験](https://zenn.dev/grainrigi/articles/b7c2320ef13c71)

## License

MIT

# mayo

[English](./README.md)

Mayo は MoonBit 向けの実験的な zero-copy データ並列 Worker pool です。Host は MoonBit から
JavaScript にコンパイルします。事前ビルドする kernel は MoonBit の JavaScript backend と Wasm
linear-memory backend に対応し、Deno または cross-origin isolated な Web page で実行できます。

常駐 Worker は JavaScript Atomics で sleep/wake します。bulk `Int32` data は shared memory に置いた
ままで、dispatch では POD descriptor `(start, end, argument)` だけを通知します。長期的な目標は
MoonBit 版 Rayon です。現在の scheduler は non-overlapping な static range を使います。

> [!WARNING]
> MoonBit heap object、closure、String、通常の Array は共有しません。contract は shared `Int32`
> region の application 固有 layout を定義します。可変長 data は offset と length で参照します。

## Data path

```text
MoonBit/JS host
  Pool::values() -> SharedSlice
          │
          │ 同じ SharedArrayBuffer / shared WebAssembly.Memory
          ▼
┌──────────────────────────────────────────────────────────┐
│ control slots │ POD descriptors │ application data      │
└──────────────────────────────────────────────────────────┘
          ▲                         ▲
          │ direct load/store       │ direct load/store
 MoonBit/JS Worker             MoonBit/Wasm Worker
```

この経路には JSON、UTF-8 変換、`postMessage` payload clone、SAB から Wasm への payload copy が
ありません。Host と guest は別々にコンパイルし、versioned ASCII `KernelContract` ID で結びます。

## JavaScript kernel

Host と guest で同じ contract ID を定義します。shared layout または kernel semantics を非互換に
変更したら ID も変更します。

```moonbit
// guest.mbt
let contract = @mayo.kernel_contract("my-app/mix-i32/v1")

fn kernel(values : @mayo.SharedSlice, start : Int, end : Int, rounds : Int) {
  for index = start; index < end; index = index + 1 {
    let mut value = values.load(index)
    for round = 0; round < rounds; round = round + 1 {
      value = mix(value)
    }
    values.store(index, value)
  }
}

fn main {
  @mayo.serve(contract, kernel)
}
```

MoonBit host は事前ビルドした kernel を起動し、shared region を所有します。

```moonbit
// host.mbt
async fn main {
  let contract = @mayo.kernel_contract("my-app/mix-i32/v1")
  let pool = @mayo.Pool::create(
    @mayo.kernel_pool_options(
      contract,
      "./guest.js",
      capacity=1048576,
      worker_count=4,
    ),
  )
  defer pool.close()

  let values = pool.values()
  values.fill(1)

  // Deno の main agent では Atomics.wait で block できる。
  let result = pool.run(end=values.length(), argument=64)

  // Browser document の main thread では async 版を使う。
  // let result = pool.run_async(end=values.length(), argument=64)
  println("dispatch: \{result.elapsed_ms} ms")
}
```

`start` / `end` は `SharedSlice` の logical index です。Worker range は重ならないため、data の
`SharedSlice::load` / `store` は意図的に non-atomic です。Atomics は scheduler の control slot
だけで使います。

構造化 data は小さな contract package で POD layout を定義します。たとえば descriptor に
`(input_offset, input_length, output_offset, output_length)` を置き、配列本体は shared region に
残します。Mayo はこの layout を serialization で隠しません。

## Wasm kernel

Wasm kernel も同じ Pool と data layout を使います。汎用 JavaScript glue が各 kernel を同じ imported
shared `WebAssembly.Memory` で instantiate し、全 Worker と host が同じ bytes を読み書きします。

```moonbit
fn kernel(data_offset : Int, start : Int, end : Int, rounds : Int) {
  // allocation-free な POD 計算
  // @abi.load_i32(data_offset, index) / @abi.store_i32(...) を使う
}

pub fn mayo_abi_version() -> Int { @abi.abi_version() }
pub fn mayo_contract_hash() -> Int { @contract.contract_hash() }
pub fn mayo_run(data_offset : Int, capacity : Int, start : Int, end : Int, argument : Int) -> Int {
  if !@abi.descriptor_is_valid(data_offset, capacity, start, end) { return -1 }
  kernel(data_offset, start, end, argument)
  0
}
```

guest package は bounded memory を import して ABI v2 を export します。

```moonbit
options(
  link: {
    "wasm": {
      "exports": ["mayo_abi_version", "mayo_contract_hash", "mayo_run"],
      "import-memory": { "module": "env", "name": "memory" },
      "memory-limits": { "min": 64, "max": 512 },
      "heap-start-address": 3145728,
    },
  },
)
```

現状の MoonBit はこの memory import を non-shared として出力します。`just build-wasm` は
[`wasm/patch_shared_memory.ts`](./wasm/patch_shared_memory.ts) を通し、memory limits flag だけを
shared に変更して import を検証します。Host 側は次のように作成します。

```moonbit
let pool = @mayo.Pool::create(
  @mayo.wasm_kernel_pool_options(
    @mayo.kernel_contract(@contract.contract_id()),
    "./mayo_wasm_kernel.js",
    "./kernel.wasm",
    capacity=1048576,
    worker_count=4,
  ),
)
```

この経路の Wasm kernel は allocation-free とし、`load_i32` / `store_i32` 経由で POD value だけを
操作してください。export する contract hash も事前生成した integer literal にします。Wasm 内で
String から計算すると allocation が起きる可能性があります。独立した Wasm instance 間で MoonBit
runtime heap を共有することはサポートしません。 実装例は
[`examples/wasm_guest`](./examples/wasm_guest) と [`examples/wasm_host`](./examples/wasm_host)
にあります。

## Browser と Deno

| Host runtime | Pool 作成      | Dispatch                        | 必要条件                             |
| ------------ | -------------- | ------------------------------- | ------------------------------------ |
| Web document | `Pool::create` | `Pool::run_async`               | cross-origin isolation (COOP + COEP) |
| Deno         | `Pool::create` | `Pool::run` / `Pool::run_async` | local Worker に `--allow-read`       |
| Node.js      | 未対応         | —                               | Worker adapter を予定                |

Browser では document、Worker、Wasm、その他 subresource に次の header が必要です。

```http
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
Cross-Origin-Resource-Policy: same-origin
```

Playwright suite は Chromium、Firefox、WebKit で JavaScript `SharedArrayBuffer` kernel と Wasm
shared-memory kernel の両方を検証します。

## 公開 API

- `kernel_contract(id) -> KernelContract`
- `kernel_pool_options(contract, worker_url, capacity~, worker_count?=4, timeout_ms?=30000)`
- `wasm_kernel_pool_options(contract, glue_url, wasm_url, capacity~, worker_count?=4, timeout_ms?=30000)`
- `Pool::create(options)`
- `Pool::values() -> SharedSlice`
- `Pool::run(start?=0, end~, argument?=0) -> RunResult` — Deno など blocking 可能な runtime
- `Pool::run_async(start?=0, end~, argument?=0) -> RunResult` — browser document。同じPoolへの
  並行呼び出しはFIFO順に待機
- `Pool::worker_count()` / `Pool::capacity()` / `Pool::close()`
- `serve(contract, kernel)` — JavaScript Worker
- `SharedSlice::length()` / `load()` / `store()` / `fill()`

`pool_options` と `start` は built-in `mayo.range/v1` contract を使う shortcut として残しています。

## Optional JSON compatibility package

`mizchi/mayo/json` は明示的な compatibility layer で、Mayo の主 API ではありません。`JsonGuest` は
`ToJson` / `FromJson` を実装する任意の MoonBit value を扱えますが、call ごとに JSON
stringify/parse、UTF-8 変換、allocation、mailbox copy が発生します。JavaScript guest 専用であり、
JSON Wasm ABI は提供しません。

この package は `JsonContract`、`json_contract`、`JsonGuest`、`json_guest_options`、`serve_json`、
`JsonError` を export します。例は [`examples/sync_contract`](./examples/sync_contract) にあります。

## 現在の制約

- shared data region は現在 `Int32Array` のみ
- 1 dispatch は 1 range と追加の `Int` argument を持つ
- scheduling は static chunk。dynamic grain と work stealing は未実装
- Wasm kernel は allocation や shared MoonBit heap object を使えない
- Wasm shared memory は MoonBit runtime image を含め 512 pages（32 MiB）まで
- cancel、Worker crash recovery、kernel panic propagation は未実装
- MoonBit にはこの境界に対する Rust の `Send` / `Sync` 相当の型検査がない
- Web page は cross-origin isolated である必要がある
- Node.js は未対応

## 開発

```console
just test          # MoonBit・Deno・browser・Rust・C test
just check         # format・lint・型検査・native check・test
just test-web      # Chromium / Firefox / WebKit 統合 test
just serve-web     # COOP/COEP 付き Web example server
just example       # MoonBit/JS Deno pool
just example-wasm  # MoonBit/JS host と shared-memory MoonBit/Wasm kernel
just example-json  # optional JSON compatibility example
just compare 4     # pthread / mmap process / Rust / Rayon 比較
```

## ベンチマーク

`just compare 4` は pool と shared region を一度だけ作成します。計測 batch では range
と演算回数だけを 通知し、Worker/process startup と data copy は除外します。`Mayo JS` は MoonBit/JS
kernel、`Mayo Wasm` は allocation-free な shared `WebAssembly.Memory` kernel です。

2026-07-15、Mac17,2 / 32 GiB / 10 logical CPUs / darwin-aarch64、Deno 2.6.4、MoonBit 0.1.20260713 で
5 回独立実行した中央値です。

| backend         | dispatch p50 | dispatch p95 | memory bandwidth | compute throughput |
| --------------- | -----------: | -----------: | ---------------: | -----------------: |
| C pthread       |      9.00 µs |      20.0 µs |       77.2 GiB/s |        5.83 Gops/s |
| C mmap process  |      11.0 µs |      23.0 µs |       76.8 GiB/s |        8.25 Gops/s |
| Rust std pool   |      8.75 µs |      18.9 µs |       81.3 GiB/s |        9.56 Gops/s |
| Rust Rayon      |      13.7 µs |      29.5 µs |       71.8 GiB/s |        6.79 Gops/s |
| MoonBit message |      43.9 µs |      76.6 µs |       14.2 GiB/s |        6.40 Gops/s |
| Mayo JS         |      10.0 µs |      22.5 µs |       20.6 GiB/s |        8.55 Gops/s |
| Mayo Wasm       |      10.6 µs |      25.4 µs |       26.6 GiB/s |        6.54 Gops/s |

今回の Mayo JS dispatch p50 は pthread の 1.12 倍、Mayo Wasm は 1.18 倍でした。memory bandwidth
はそれぞれ pthread の 26.7% と 34.5%、compute throughput は 1.47 倍と 1.12 倍です。core 割当、
温度、電源状態、runtime version で結果は変わるため、手元の `just compare` を基準にしてください。

## Roadmap

1. 複数 argument / shared slice 向け typed POD descriptor
2. grain size を指定できる dynamic chunk counter
3. shared task ring と Worker ごとの Chase–Lev deque
4. work stealing、cancel、task recovery
5. `par_for` / `par_chunks` 高レベル API
6. Node.js Worker adapter

着想元:
[Rust/Wasm で shared memory と Mutex を使う実験](https://zenn.dev/grainrigi/articles/b7c2320ef13c71)

## License

MIT

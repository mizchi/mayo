# Mayo Kernel ABI v1

[English](./kernel-abi-v1.md)

この文書は `mayo.kernel/v1` で識別されるJavaScript Host/Guest glue contractを定義します。
生成descriptor package、事前ビルドWorker artifact、`ThreadPool` facadeのsource of truthです。

## 共有descriptor package

HostとGuestは同じMoonBit descriptor packageをimportしなければなりません。このpackageは1つの
`KernelManifest` と、順序付きの `KernelSpec` を定義します。

```moonbit
fn mix_spec() -> @mayo.KernelSpec {
  @mayo.kernel_spec(id=1, layout_hash=0x4D495801)
}

fn add_spec() -> @mayo.KernelSpec {
  @mayo.kernel_spec(id=2, layout_hash=0x41444401)
}

pub fn manifest() -> @mayo.KernelManifest {
  @mayo.kernel_manifest("my-app/i32-kernels/v1", [mix_spec(), add_spec()])
}
```

次の宣言規則をruntimeで検査します。

- manifest IDは空白を含まないnon-empty printable ASCII
- manifestは1つ以上のkernel specを含む
- kernel IDは正数
- layout hashは0以外
- specはkernel IDの厳密な昇順
- `KernelCall` はmanifestに含まれるspecからのみ構築可能
- Guest entryはmanifestの順序、ID、layout hashと完全一致

manifest handshake文字列は決定的です。

```text
mayo.kernel/v1|<manifest-id-length>:<manifest-id>|<count>|<id>:<layout-hash>...
```

manifest ID長はASCII byte数です。count、kernel ID、layout hashはMoonBit `Int`の10進表記を使います。
kernel IDは正数、layout hashは0以外（負数可）です。

人間向けmanifest IDが同じでも、順序付きspecが変わればhandshakeも変わります。layoutを変えない
semantic-onlyなkernel変更ではmanifest IDを変更しなければなりません。

## 生成Host surface

descriptor generatorはkernelごとに名前付き関数を生成するべきです。application codeから
`kernel_call`を直接呼びません。

```moonbit
pub fn mix(rounds~ : Int) -> @mayo.KernelCall {
  @mayo.kernel_call(manifest(), mix_spec(), argument=rounds)
}
```

Hostは同じmanifestでWorkerを開きます。

```moonbit
let threads = @mayo.ThreadPool::open(
  @kernels.manifest(),
  "./worker.js",
  capacity=1_000_000,
  workers=4,
)

let values = threads.shared_i32()
values.par_for(@kernels.mix(rounds=64))
```

`ThreadPool::open` はWorkerが通知するmanifest handshakeが異なれば拒否します。`par_for` と `spawn`
も別manifestの `KernelCall` をdispatch前に拒否します。

## 生成Guest surface

descriptor generatorはkernelごとにentry binderを生成するべきです。

```moonbit
pub fn mix_entry(
  implementation : (@mayo.SharedSlice, Int, Int, Int) -> Unit,
) -> @mayo.KernelEntry {
  @mayo.kernel_entry(mix_spec(), implementation)
}
```

別途コンパイルするWorkerはmanifest順に全entryを登録します。

```moonbit
fn main {
  @mayo.serve_kernels(
    @kernels.manifest(),
    [@kernels.mix_entry(mix_range), @kernels.add_entry(add_range)],
  )
}
```

1つのWorker artifactに複数kernelを登録できます。kernel実装のsignatureは固定です。

```moonbit
(@mayo.SharedSlice, start : Int, end : Int, argument : Int) -> Unit
```

rangeは半開区間 `[start, end)` です。各Workerに割り当てるrangeは重複しません。shared dataの element
accessはnon-atomicで、scheduler controlにはJavaScript Atomicsを使います。

## Shared control slot

Workerごとにshared `Int32` memory上の16 word control slotを1つ所有します。

| Word | Name        | 意味                                  |
| ---- | ----------- | ------------------------------------- |
| 0    | epoch       | Hostがpublishするdispatch generation  |
| 1    | done_epoch  | Workerが完了した最後のgeneration      |
| 2    | start       | logical rangeのinclusive start        |
| 3    | end         | logical rangeのexclusive end          |
| 4    | argument    | kernel固有のsigned 32-bit argument    |
| 5    | stop        | 0以外でWorker終了を要求               |
| 6    | kernel_id   | manifest内のkernel ID                 |
| 7    | layout_hash | 期待するargument/data layout hash     |
| 8    | status      | Guest dispatch status                 |
| 9–15 | reserved    | 無視し、0のまま維持しなければならない |

Hostはdescriptorを書き、`epoch`をstoreして `Atomics.notify` を呼びます。Guestは新しいepochを待ち、
kernel IDとlayout hashを検査してkernelを実行し、`status`、`done_epoch`の順でstoreしてHostへ
notifyします。

status値は次の通りです。

| Value | 意味              |
| ----- | ----------------- |
| 0     | 成功              |
| -1    | 未知のkernel ID   |
| -2    | layout hash不一致 |

いずれかのWorkerがerrorを返した場合も、Hostはcontrol slotを再利用する前にdispatch対象の全Workerを
待たなければなりません。

## Versioningと対象外

schedulerまたはcontrol slotの破壊的変更では `mayo.kernel/v2` のようにABI prefixを変更します。 kernel
signature、POD layout、semanticsの変更では、内容に応じてlayout hashまたはmanifest IDを 変更します。

Kernel ABI v1はMoonBit closure、heap object、String、通常のArrayを転送しません。dynamic argument
block、typed result buffer、panic伝播、descriptor自動生成は未定義です。これらはraw `mayo.range/v1`
compatibility APIを変更せず、将来のABIで追加できます。

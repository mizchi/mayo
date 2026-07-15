# Mayo Kernel ABI v4

[English](./kernel-abi-v4.md)

この文書は`mayo.kernel/v4`で識別されるJavaScript Host/Guest contractを定義します。

## Manifest handshake

HostとGuestは同じ順序の`KernelManifest`をimportします。各`KernelSpec`は正のID、0以外のlayout
hash、kindを持ちます。kind `0`はin-place/range kernel、kind `1`はreducerです。

```text
mayo.kernel/v4|<manifest-id-length>:<manifest-id>|<count>|<id>:<layout-hash>:<kind>...
```

manifest IDはnon-empty printable ASCII、spec IDは厳密な昇順です。完全なhandshakeが違えば起動に
失敗し、別manifestから作ったcallもdispatch前に拒否します。

生成Host callが持つのはmanifest identity、kernel ID、layout hash、kind、1つのsigned `Int`
argumentだけです。生成Guest entryは次のどちらかをbindします。

```moonbit
(@mayo.SharedSlice, start : Int, end : Int, argument : Int) -> Unit // kind 0
(@mayo.SharedSlice, start : Int, end : Int, argument : Int) -> Int  // kind 1
```

rangeは半開区間です。application contractで別途定義しない限りshared data accessはnon-atomicです。
scheduler wordはJavaScript Atomicsで操作します。

## Shared control slot

各Workerは16個の`Int32` control wordを所有します。

| Word | 名前            | 意味                                          |
| ---: | --------------- | --------------------------------------------- |
|    0 | epoch           | Hostがpublishするdispatch generation          |
|    1 | done_epoch      | このWorkerが完了した最新generation            |
|    2 | start           | 割り当てrangeのinclusive start                |
|    3 | end             | 割り当てrangeのexclusive end                  |
|    4 | argument        | 1つのsigned 32-bit argument                   |
|    5 | stop            | non-zeroでshutdown要求                        |
|    6 | kernel_id       | 登録kernel ID                                 |
|    7 | layout_hash     | 期待するlayout/argument hash                  |
|    8 | status          | Guest completion status                       |
|    9 | cursor          | Worker-local dynamic shard cursor             |
|   10 | grain           | 正数ならdynamic chunk、0ならstatic            |
|   11 | cancel_sequence | slot 0に置くpool-wide cancellation generation |
|   12 | cancel_baseline | dispatch開始時のgeneration                    |
|   13 | result          | reducer partial result                        |
|   14 | elapsed_us      | Worker-local kernel時間（整数µs）             |
|   15 | worker_count    | slot 0に置くpool-wide Worker数                |

statusは`0` success、`-1` unknown kernel、`-2` layout mismatch、`-3` uncaught runtime failure、 `-4`
cooperative cancellationです。

Hostはdescriptor wordを書いてから`epoch`をpublishし、各Workerへnotifyします。Workerは`status`、
`result`、`elapsed_us`、最後に`done_epoch`を書いてHostへnotifyします。Hostはslotを再利用する前に
全Workerを待ちます。

## Scheduling

static dispatchはword 14から学習したWorker別throughput weightでrangeを分割します。dynamic dispatchは
Workerごとのshardとcursorを用意します。Workerは自分のshardを処理した後、他Workerのcursorからchunkを
claimします。公開`par_chunks`は最初にrange長とWorker数からgrainを決め、以降はkernel別item costを
更新して約100µsのchunkを目標にします。

reducerはstatic rangeを使います。non-empty Workerはword 13へpartialを書き、Hostは実際に割り当てた
rangeをWorker ID昇順にcombineします。順序は決定的ですが、parallel tree reductionではありません。

cancellationはdynamic chunk境界で協調的に検査します。static kernelは完了まで実行します。

## Failureとrecovery

uncaught kernel failureは失敗Workerを終了し、そのdispatchを失敗させます。defaultの`PoisonPool`は
pool全体を終了します。`RestartWorkers`は同じshared allocation上で全Workerを再生成します。失敗した
dispatch自体はerrorになり、次のdispatchから再利用できます。

## Shared application data

MoonBit heap object、closure、String、通常のArrayは転送しません。生成POD layoutはheader、offset、
length、`Int32` fieldを`SharedArena`へ保存します。`SharedRegion`はHost allocationが重複しないことを
保証します。JS Guest viewは`SharedSlice::worker_id`でpool-localなstable indexを取得し、
`WorkerScratch`をaddressできます。layout semanticsはapplication manifestの一部です。

## Runtime glueとWasm

JS Workerは`{ type: "online", protocol }`を通知し、shared bufferとslot
offsetを含む`atomic-init`を1回 受け取り、Atomics loopへ入ります。Nodeでは`worker_threads`
bridgeを使います。BunはWorker module URLの query parameterを除去するため、shared
Wasmでは同等のbootstrap messageも送ります。

MoonBit/Wasm kernelはimportしたshared `WebAssembly.Memory`と、別のlow-level Wasm ABI version `2`を
使います。exportは`mayo_abi_version`、`mayo_contract_hash`、`mayo_run`です。汎用JS glueが同じ16-word
scheduling protocolを担当します。Wasm kernelはshared memory limit内に収め、MoonBit heap共有を前提に
してはいけません。

control slot、handshake、kernel kindの非互換変更では新しい`mayo.kernel/vN` prefixが必要です。layout
またはsemanticsの変更ではlayout hashまたはmanifest IDを更新します。

# Mayo Kernel ABI v4

[日本語](./kernel-abi-v4.ja.md)

This document defines the JavaScript Host/Guest contract identified by `mayo.kernel/v4`.

## Manifest handshake

Host and Guest import the same ordered `KernelManifest`. Each `KernelSpec` contains a positive ID, a
non-zero layout hash, and a kind: `0` for an in-place/range kernel or `1` for a reducer.

```text
mayo.kernel/v4|<manifest-id-length>:<manifest-id>|<count>|<id>:<layout-hash>:<kind>...
```

The manifest ID is non-empty printable ASCII. Specs use strictly increasing IDs. Startup fails if
the complete handshake differs; dispatch also rejects calls built from another manifest.

A generated Host call contains only the manifest identity, kernel ID, layout hash, kind, and one
signed `Int` argument. Generated Guest entries bind one of these signatures:

```moonbit
(@mayo.SharedSlice, start : Int, end : Int, argument : Int) -> Unit // kind 0
(@mayo.SharedSlice, start : Int, end : Int, argument : Int) -> Int  // kind 1
```

Ranges are half-open. Shared data access is non-atomic unless the application contract says
otherwise. Scheduler words are accessed through JavaScript Atomics.

## Shared control slot

Every Worker owns 16 `Int32` control words.

| Word | Name            | Meaning                                          |
| ---: | --------------- | ------------------------------------------------ |
|    0 | epoch           | Host-published dispatch generation               |
|    1 | done_epoch      | Last generation completed by this Worker         |
|    2 | start           | Inclusive assigned range start                   |
|    3 | end             | Exclusive assigned range end                     |
|    4 | argument        | One signed 32-bit argument                       |
|    5 | stop            | Non-zero requests shutdown                       |
|    6 | kernel_id       | Registered kernel ID                             |
|    7 | layout_hash     | Expected layout/argument hash                    |
|    8 | status          | Guest completion status                          |
|    9 | cursor          | Worker-local dynamic shard cursor                |
|   10 | grain           | Positive dynamic chunk size; zero selects static |
|   11 | cancel_sequence | Pool-wide cancellation generation in slot 0      |
|   12 | cancel_baseline | Generation captured for this dispatch            |
|   13 | result          | Reducer partial result                           |
|   14 | elapsed_us      | Worker-local kernel time in integer microseconds |
|   15 | worker_count    | Pool-wide Worker count in slot 0                 |

Status values are `0` success, `-1` unknown kernel, `-2` layout mismatch, `-3` uncaught runtime
failure, and `-4` cooperative cancellation.

The Host writes all descriptor words, publishes `epoch`, and notifies each Worker. A Worker writes
`status`, `result`, `elapsed_us`, and finally `done_epoch`, then notifies the Host. The Host waits
for every Worker before reusing a slot.

## Scheduling

Static dispatch partitions the range using per-Worker throughput weights learned from word 14.
Dynamic dispatch gives each Worker a shard and a cursor. A Worker drains its own shard, then claims
chunks from the other Worker cursors. Public `par_chunks` chooses an initial grain from range length
and Worker count; later calls update a per-kernel item-cost estimate targeting roughly 100 µs
chunks.

Reducers use static ranges. Each non-empty Worker writes one partial to word 13; the Host combines
the actual assigned ranges in ascending Worker ID order. The combine order is deterministic, but it
is not a parallel tree reduction.

Cancellation is cooperative at dynamic chunk boundaries. Static kernels run to completion.

## Failure and recovery

An uncaught kernel failure terminates the failing Worker and fails its dispatch. The default
`PoisonPool` policy terminates the pool. `RestartWorkers` recreates the complete Worker set on the
same shared allocation; the failed dispatch is still reported, while a later dispatch may proceed.

## Shared application data

The ABI does not transfer MoonBit heap objects, closures, strings, or ordinary arrays. Generated POD
layouts store headers, offsets, lengths, and `Int32` fields in `SharedArena`. `SharedRegion`
guarantees non-overlapping Host allocation. A JS Guest view exposes its stable pool-local index
through `SharedSlice::worker_id`, allowing it to address `WorkerScratch`; layout semantics remain
part of the application manifest.

## Runtime glue and Wasm

The JS Worker advertises `{ type: "online", protocol }`, receives one `atomic-init` message carrying
the shared buffer and slot offsets, then enters the Atomics loop. Node uses a `worker_threads`
bridge. Bun receives an equivalent bootstrap message for shared Wasm because it removes URL query
parameters from Worker module URLs.

MoonBit/Wasm kernels use imported shared `WebAssembly.Memory` and a separate low-level Wasm ABI
version `2`: exports `mayo_abi_version`, `mayo_contract_hash`, and `mayo_run`. The generic JS glue
owns the same 16-word scheduling protocol. Wasm kernels must fit the configured shared memory limit
and must not rely on sharing the MoonBit heap.

Any incompatible control-slot, handshake, or kernel-kind change requires a new `mayo.kernel/vN`
prefix. Layout or semantic changes require a new layout hash or manifest ID.

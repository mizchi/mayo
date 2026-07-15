# Mayo Kernel ABI v1

[日本語](./kernel-abi-v1.ja.md)

This document defines the JavaScript Host/Guest glue contract identified by `mayo.kernel/v1`. It is
the source of truth for generated descriptor packages, prebuilt Worker artifacts, and the
`ThreadPool` facade.

## Shared descriptor package

Host and Guest builds MUST import the same MoonBit descriptor package. The package defines one
`KernelManifest` and its ordered `KernelSpec` values.

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

The following declaration rules are enforced:

- the manifest ID is non-empty printable ASCII without spaces;
- a manifest contains at least one kernel spec;
- kernel IDs are positive;
- layout hashes are non-zero;
- specs are sorted by strictly increasing kernel ID;
- a `KernelCall` can only be built from a spec contained in its manifest;
- Guest entries must exactly match the manifest order, IDs, and layout hashes.

The manifest handshake string is deterministic:

```text
mayo.kernel/v1|<manifest-id-length>:<manifest-id>|<count>|<id>:<layout-hash>...
```

The manifest ID length is its ASCII byte length. Counts, kernel IDs, and layout hashes use decimal
MoonBit `Int` notation; kernel IDs are positive and layout hashes may be negative but not zero.

Changing the ordered specs changes the handshake even if the human-readable manifest ID is
unchanged. A semantic-only kernel change that does not alter a layout MUST change the manifest ID.

## Generated Host surface

A descriptor generator SHOULD emit one named function per kernel. Application code should not call
`kernel_call` directly.

```moonbit
pub fn mix(rounds~ : Int) -> @mayo.KernelCall {
  @mayo.kernel_call(manifest(), mix_spec(), argument=rounds)
}
```

The Host opens a Worker with the same manifest:

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

`ThreadPool::open` rejects a Worker whose advertised manifest handshake differs. `par_for` and
`spawn` also reject a `KernelCall` from another manifest before a dispatch is published.

## Generated Guest surface

A descriptor generator SHOULD emit one entry binder per kernel:

```moonbit
pub fn mix_entry(
  implementation : (@mayo.SharedSlice, Int, Int, Int) -> Unit,
) -> @mayo.KernelEntry {
  @mayo.kernel_entry(mix_spec(), implementation)
}
```

The separately compiled Worker registers every entry in manifest order:

```moonbit
fn main {
  @mayo.serve_kernels(
    @kernels.manifest(),
    [@kernels.mix_entry(mix_range), @kernels.add_entry(add_range)],
  )
}
```

One Worker artifact may contain multiple kernels. A kernel implementation has the fixed signature:

```moonbit
(@mayo.SharedSlice, start : Int, end : Int, argument : Int) -> Unit
```

The range is half-open (`[start, end)`). Ranges assigned to Workers do not overlap. Shared data
element access is non-atomic; scheduler control access is performed with JavaScript Atomics.

## Shared control slot

Each Worker owns one 16-word control slot in shared `Int32` memory.

| Word | Name        | Meaning                                 |
| ---- | ----------- | --------------------------------------- |
| 0    | epoch       | Host-published dispatch generation      |
| 1    | done_epoch  | Last generation completed by the Worker |
| 2    | start       | Inclusive logical range start           |
| 3    | end         | Exclusive logical range end             |
| 4    | argument    | One signed 32-bit kernel argument       |
| 5    | stop        | Non-zero requests Worker shutdown       |
| 6    | kernel_id   | Manifest kernel ID                      |
| 7    | layout_hash | Expected argument/data layout hash      |
| 8    | status      | Guest dispatch status                   |
| 9–15 | reserved    | MUST be ignored and remain zero         |

The Host writes the descriptor, stores `epoch`, and calls `Atomics.notify`. The Guest waits for a
new epoch, validates the kernel ID and layout hash, runs the kernel, stores `status`, stores
`done_epoch`, and notifies the Host.

Status values are:

| Value | Meaning              |
| ----- | -------------------- |
| 0     | success              |
| -1    | unknown kernel ID    |
| -2    | layout hash mismatch |

Hosts MUST wait for every Worker in a dispatch before reusing control slots, including when one
Worker reports an error.

## Versioning and exclusions

Breaking scheduler or control-slot changes require a new ABI prefix such as `mayo.kernel/v2`. Kernel
signature, POD layout, or semantics changes require a new layout hash or manifest ID as appropriate.

Kernel ABI v1 does not transfer MoonBit closures, heap objects, strings, or ordinary arrays. It does
not define dynamic argument blocks, typed result buffers, panic propagation, or automatic descriptor
generation. These can be added in a later ABI without changing the raw `mayo.range/v1` compatibility
API.

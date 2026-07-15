///|
/// Shared control-slot layout used by the host and Worker runtime.
const CONTROL_SLOT_LENGTH : Int = 16

///|
const CONTROL_EPOCH : Int = 0

///|
const CONTROL_DONE_EPOCH : Int = 1

///|
const CONTROL_RANGE_START : Int = 2

///|
const CONTROL_RANGE_END : Int = 3

///|
const CONTROL_ARGUMENT : Int = 4

///|
const CONTROL_STOP : Int = 5

///|
const CONTROL_KERNEL_ID : Int = 6

///|
const CONTROL_LAYOUT_HASH : Int = 7

///|
const CONTROL_STATUS : Int = 8

///|
/// Worker-local shard cursor used for dynamic work sharing.
const CONTROL_DYNAMIC_CURSOR : Int = 9

///|
/// Zero selects static partitioning; a positive value selects dynamic chunks.
const CONTROL_GRAIN : Int = 10

///|
/// Pool-wide generation incremented to request cancellation.
const CONTROL_CANCEL_SEQUENCE : Int = 11

///|
/// Cancellation generation captured for one Worker dispatch.
const CONTROL_CANCEL_BASELINE : Int = 12

///|
/// Worker-local partial result for reduction kernels.
const CONTROL_RESULT : Int = 13

///|
/// Worker-local kernel elapsed time in integer microseconds.
const CONTROL_ELAPSED_US : Int = 14

///|
/// Pool-wide Worker count stored in the first slot.
const CONTROL_WORKER_COUNT : Int = 15

///|
/// Contract advertised by the low-level range Worker API.
const RANGE_PROTOCOL_ID : String = "mayo.range/v1"

///|
/// Prefix for manifest-bound multi-kernel Worker artifacts with dynamic chunks.
const KERNEL_PROTOCOL_PREFIX : String = "mayo.kernel/v4"

///|
const KERNEL_STATUS_OK : Int = 0

///|
const KERNEL_STATUS_UNKNOWN : Int = -1

///|
const KERNEL_STATUS_LAYOUT_MISMATCH : Int = -2

///|
const KERNEL_STATUS_RUNTIME_FAILED : Int = -3

///|
const KERNEL_STATUS_CANCELLED : Int = -4

///|
/// Shared Wasm scheduler/data begins above MoonBit's static runtime image.
const WASM_SHARED_BASE_WORDS : Int = 1048576

///|
const WASM_MAX_PAGES : Int = 512

///|
const WASM_PAGE_WORDS : Int = 16384

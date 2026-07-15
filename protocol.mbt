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
/// Contract advertised by the low-level range Worker API.
const RANGE_PROTOCOL_ID : String = "mayo.range/v1"

///|
/// Shared Wasm scheduler/data begins above MoonBit's static runtime image.
const WASM_SHARED_BASE_WORDS : Int = 1048576

///|
const WASM_MAX_PAGES : Int = 512

///|
const WASM_PAGE_WORDS : Int = 16384

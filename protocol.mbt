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
/// Number of Int32 words reserved before a typed mailbox payload.
const SYNC_MAILBOX_HEADER_WORDS : Int = 4

///|
const SYNC_REQUEST_LENGTH : Int = 0

///|
const SYNC_RESPONSE_LENGTH : Int = 1

///|
const SYNC_STATUS : Int = 2

///|
const SYNC_STATUS_PENDING : Int = 0

///|
const SYNC_STATUS_OK : Int = 1

///|
const SYNC_STATUS_ERROR : Int = -1

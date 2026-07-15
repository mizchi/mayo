///|
const MAILBOX_HEADER_WORDS : Int = 4

///|
const REQUEST_LENGTH : Int = 0

///|
const RESPONSE_LENGTH : Int = 1

///|
const STATUS : Int = 2

///|
const STATUS_PENDING : Int = 0

///|
const STATUS_OK : Int = 1

///|
const STATUS_ERROR : Int = -1

///|
extern "js" fn write_utf8(
  values : @mayo.SharedSlice,
  byte_offset : Int,
  text : String,
) -> Int =
  #| (values, byteOffset, text) => {
  #|   const bytes = new TextEncoder().encode(text);
  #|   const capacity = values.byteLength - byteOffset;
  #|   if (bytes.byteLength > capacity) return -(bytes.byteLength + 1);
  #|   new Uint8Array(
  #|     values.buffer,
  #|     values.byteOffset + byteOffset,
  #|     bytes.byteLength,
  #|   ).set(bytes);
  #|   return bytes.byteLength | 0;
  #| }

///|
extern "js" fn read_utf8(
  values : @mayo.SharedSlice,
  byte_offset : Int,
  byte_length : Int,
) -> String =
  #| (values, byteOffset, byteLength) => new TextDecoder().decode(
  #|   new Uint8Array(
  #|     values.buffer,
  #|     values.byteOffset + byteOffset,
  #|     byteLength,
  #|   ).slice(),
  #| )

///|
/// An opt-in JSON contract. This compatibility API serializes and copies every
/// request and response; Mayo's root package uses shared POD data instead.
pub struct JsonContract[Request, Response] {
  priv id_ : String
  priv _request_type : Request?
  priv _response_type : Response?
}

///|
/// Defines a versioned JSON contract shared by separately compiled JS bundles.
pub fn[Request, Response] json_contract(
  id : String,
) -> JsonContract[Request, Response] {
  { id_: id, _request_type: None, _response_type: None }
}

///|
pub fn[Request, Response] JsonContract::id(
  self : JsonContract[Request, Response],
) -> String {
  self.id_
}

///|
pub struct JsonGuestOptions {
  priv worker_url : String
  priv mailbox_bytes : Int
  priv timeout_ms : Int
}

///|
pub fn json_guest_options(
  worker_url : String,
  mailbox_bytes? : Int = 1048576,
  timeout_ms? : Int = 30000,
) -> JsonGuestOptions {
  { worker_url, mailbox_bytes, timeout_ms }
}

///|
pub suberror JsonError {
  InvalidArgument(String)
  CapacityExceeded(Int, Int)
  GuestFailed(String)
  Transport(String)
  Busy
}

///|
pub struct JsonGuest[Request, Response] {
  priv pool : @mayo.Pool
  priv mailbox_bytes_ : Int
  priv mut busy : Bool
  priv _request_type : Request?
  priv _response_type : Response?
}

///|
fn mailbox_capacity_words(mailbox_bytes : Int) -> Int {
  MAILBOX_HEADER_WORDS + (mailbox_bytes + 3) / 4
}

///|
fn payload_offset() -> Int {
  MAILBOX_HEADER_WORDS * 4
}

///|
fn write_mailbox(
  values : @mayo.SharedSlice,
  text : String,
  capacity : Int,
) -> Int raise JsonError {
  let written = write_utf8(values, payload_offset(), text)
  if written < 0 {
    raise JsonError::CapacityExceeded(-written - 1, capacity)
  }
  written
}

///|
fn read_mailbox(
  values : @mayo.SharedSlice,
  length : Int,
  capacity : Int,
) -> String raise JsonError {
  if length < 0 || length > capacity {
    raise JsonError::Transport(
      "guest returned an invalid mailbox length: \{length}",
    )
  }
  read_utf8(values, payload_offset(), length)
}

///|
fn pool_error_message(error : @mayo.PoolError) -> String {
  match error {
    @mayo.PoolError::InvalidArgument(message) => message
    @mayo.PoolError::WorkerFailed(message) => message
    @mayo.PoolError::Timeout(message) => message
    @mayo.PoolError::Closed => "worker pool is closed"
    @mayo.PoolError::Busy => "worker pool is busy"
  }
}

///|
fn[Response : @core_json.FromJson] decode_response(
  text : String,
) -> Response raise JsonError {
  let json = @core_json.parse(text) catch {
    error => raise JsonError::Transport("guest returned invalid JSON: \{error}")
  }
  @core_json.from_json(json) catch {
    error =>
      raise JsonError::Transport(
        "guest response did not match the contract: \{error}",
      )
  }
}

///|
fn[Request : ToJson, Response] JsonGuest::prepare_call(
  self : JsonGuest[Request, Response],
  request : Request,
) -> Unit raise JsonError {
  let values = self.pool.values()
  values.store(RESPONSE_LENGTH, 0)
  values.store(STATUS, STATUS_PENDING)
  let request_length = write_mailbox(
    values,
    request.to_json().stringify(),
    self.mailbox_bytes_,
  )
  values.store(REQUEST_LENGTH, request_length)
}

///|
fn[Request, Response : @core_json.FromJson] JsonGuest::finish_call(
  self : JsonGuest[Request, Response],
) -> Response raise JsonError {
  let values = self.pool.values()
  let response_text = read_mailbox(
    values,
    values.load(RESPONSE_LENGTH),
    self.mailbox_bytes_,
  )
  match values.load(STATUS) {
    STATUS_OK => decode_response(response_text)
    STATUS_ERROR =>
      raise JsonError::GuestFailed(
        if response_text.is_empty() {
          "guest failed without an error message"
        } else {
          response_text
        },
      )
    status =>
      raise JsonError::Transport("guest returned an invalid status: \{status}")
  }
}

///|
pub async fn[Request, Response] JsonGuest::create(
  contract : JsonContract[Request, Response],
  options : JsonGuestOptions,
) -> JsonGuest[Request, Response] raise JsonError {
  if contract.id_.is_empty() {
    raise JsonError::InvalidArgument("contract id must not be empty")
  }
  if options.mailbox_bytes < 1 {
    raise JsonError::InvalidArgument("mailbox_bytes must be positive")
  }
  if options.timeout_ms < 1 {
    raise JsonError::InvalidArgument("timeout_ms must be positive")
  }
  let pool = @mayo.Pool::create(
    @mayo.kernel_pool_options(
      @mayo.kernel_contract(contract.id_),
      options.worker_url,
      capacity=mailbox_capacity_words(options.mailbox_bytes),
      worker_count=1,
      timeout_ms=options.timeout_ms,
    ),
  ) catch {
    error => raise JsonError::Transport(pool_error_message(error))
  }
  {
    pool,
    mailbox_bytes_: options.mailbox_bytes,
    busy: false,
    _request_type: None,
    _response_type: None,
  }
}

///|
pub fn[Request : ToJson, Response : @core_json.FromJson] JsonGuest::call(
  self : JsonGuest[Request, Response],
  request : Request,
) -> Response raise JsonError {
  if self.busy {
    raise JsonError::Busy
  }
  self.busy = true
  defer {
    self.busy = false
  }
  self.prepare_call(request)
  ignore(
    self.pool.run(end=0) catch {
      error => raise JsonError::Transport(pool_error_message(error))
    },
  )
  self.finish_call()
}

///|
pub async fn[Request : ToJson, Response : @core_json.FromJson] JsonGuest::call_async(
  self : JsonGuest[Request, Response],
  request : Request,
) -> Response raise JsonError {
  if self.busy {
    raise JsonError::Busy
  }
  self.busy = true
  defer {
    self.busy = false
  }
  self.prepare_call(request)
  ignore(
    self.pool.run_async(end=0) catch {
      error => raise JsonError::Transport(pool_error_message(error))
    },
  )
  self.finish_call()
}

///|
pub fn[Request, Response] JsonGuest::mailbox_bytes(
  self : JsonGuest[Request, Response],
) -> Int {
  self.mailbox_bytes_
}

///|
pub fn[Request, Response] JsonGuest::close(
  self : JsonGuest[Request, Response],
) -> Unit {
  self.pool.close()
}

///|
fn write_guest_result(
  values : @mayo.SharedSlice,
  status : Int,
  text : String,
) -> Unit {
  let written = write_utf8(values, payload_offset(), text)
  if written < 0 {
    values.store(RESPONSE_LENGTH, 0)
    values.store(STATUS, STATUS_ERROR)
  } else {
    values.store(RESPONSE_LENGTH, written)
    values.store(STATUS, status)
  }
}

///|
/// Installs the opt-in JSON compatibility handler in a JavaScript Worker.
pub fn[Request : @core_json.FromJson, Response : ToJson] serve_json(
  contract : JsonContract[Request, Response],
  handler : (Request) -> Response,
) -> Unit {
  @mayo.serve(@mayo.kernel_contract(contract.id_), fn(
    values,
    _start,
    _end,
    _argument,
  ) {
    let request_length = values.load(REQUEST_LENGTH)
    if request_length < 0 ||
      request_length > values.byte_length() - payload_offset() {
      write_guest_result(values, STATUS_ERROR, "invalid request length")
      return
    }
    let request : Request = @core_json.from_json(
      @core_json.parse(read_utf8(values, payload_offset(), request_length)),
    ) catch {
      error => {
        write_guest_result(
          values,
          STATUS_ERROR,
          "request did not match the contract: \{error}",
        )
        return
      }
    }
    write_guest_result(
      values,
      STATUS_OK,
      handler(request).to_json().stringify(),
    )
  })
}

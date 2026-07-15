///|
/// A typed host/guest contract. The identifier is checked before the host
/// shares memory with the prebuilt Worker.
pub struct SyncContract[Request, Response] {
  priv id_ : String
  priv _request_type : Request?
  priv _response_type : Response?
}

///|
/// Defines a versioned typed contract shared by separately compiled host and
/// guest packages.
pub fn[Request, Response] sync_contract(
  id : String,
) -> SyncContract[Request, Response] {
  { id_: id, _request_type: None, _response_type: None }
}

///|
/// Returns the stable identifier checked during the Worker handshake.
pub fn[Request, Response] SyncContract::id(
  self : SyncContract[Request, Response],
) -> String {
  self.id_
}

///|
/// Configuration for a typed guest Worker.
pub struct SyncGuestOptions {
  priv worker_url : String
  priv mailbox_bytes : Int
  priv timeout_ms : Int
}

///|
/// Builds typed guest options. `mailbox_bytes` is the maximum encoded request
/// or response size, not including the internal header.
pub fn sync_guest_options(
  worker_url : String,
  mailbox_bytes? : Int = 1048576,
  timeout_ms? : Int = 30000,
) -> SyncGuestOptions {
  { worker_url, mailbox_bytes, timeout_ms }
}

///|
/// Errors raised by typed host/guest calls.
pub suberror SyncError {
  InvalidArgument(String)
  CapacityExceeded(Int, Int)
  GuestFailed(String)
  Transport(String)
  Busy
}

///|
/// A persistent, typed connection to one separately compiled guest Worker.
pub struct SyncGuest[Request, Response] {
  priv pool : Pool
  priv mailbox_bytes_ : Int
  priv mut busy : Bool
  priv _request_type : Request?
  priv _response_type : Response?
}

///|
fn mailbox_capacity_words(mailbox_bytes : Int) -> Int {
  SYNC_MAILBOX_HEADER_WORDS + (mailbox_bytes + 3) / 4
}

///|
fn mailbox_payload_offset() -> Int {
  SYNC_MAILBOX_HEADER_WORDS * 4
}

///|
fn write_mailbox(
  values : SharedSlice,
  text : String,
  capacity : Int,
) -> Int raise SyncError {
  let written = values.write_utf8(mailbox_payload_offset(), text)
  if written < 0 {
    let required = -written - 1
    raise SyncError::CapacityExceeded(required, capacity)
  }
  written
}

///|
fn read_mailbox(
  values : SharedSlice,
  length : Int,
  capacity : Int,
) -> String raise SyncError {
  if length < 0 || length > capacity {
    raise SyncError::Transport(
      "guest returned an invalid mailbox length: \{length}",
    )
  }
  values.read_utf8(mailbox_payload_offset(), length)
}

///|
fn[Response : @json.FromJson] decode_response(
  text : String,
) -> Response raise SyncError {
  let json = @json.parse(text) catch {
    error => raise SyncError::Transport("guest returned invalid JSON: \{error}")
  }
  @json.from_json(json) catch {
    error =>
      raise SyncError::Transport(
        "guest response did not match the contract: \{error}",
      )
  }
}

///|
fn[Request : ToJson, Response] SyncGuest::prepare_call(
  self : SyncGuest[Request, Response],
  request : Request,
) -> Unit raise SyncError {
  let values = self.pool.values()
  values.store(SYNC_RESPONSE_LENGTH, 0)
  values.store(SYNC_STATUS, SYNC_STATUS_PENDING)
  let encoded = request.to_json().stringify()
  let request_length = write_mailbox(values, encoded, self.mailbox_bytes_)
  values.store(SYNC_REQUEST_LENGTH, request_length)
}

///|
fn pool_error_message(error : PoolError) -> String {
  match error {
    PoolError::InvalidArgument(message) => message
    PoolError::WorkerFailed(message) => message
    PoolError::Timeout(message) => message
    PoolError::Closed => "worker pool is closed"
    PoolError::Busy => "worker pool is busy"
  }
}

///|
fn[Request, Response : @json.FromJson] SyncGuest::finish_call(
  self : SyncGuest[Request, Response],
) -> Response raise SyncError {
  let values = self.pool.values()
  let response_length = values.load(SYNC_RESPONSE_LENGTH)
  let response_text = read_mailbox(values, response_length, self.mailbox_bytes_)
  match values.load(SYNC_STATUS) {
    SYNC_STATUS_OK => decode_response(response_text)
    SYNC_STATUS_ERROR => {
      let message = if response_text.is_empty() {
        "guest failed without an error message"
      } else {
        response_text
      }
      raise SyncError::GuestFailed(message)
    }
    status =>
      raise SyncError::Transport("guest returned an invalid status: \{status}")
  }
}

///|
/// Starts a prebuilt guest and validates its contract identifier.
pub async fn[Request, Response] SyncGuest::create(
  contract : SyncContract[Request, Response],
  options : SyncGuestOptions,
) -> SyncGuest[Request, Response] raise SyncError {
  if contract.id_.is_empty() {
    raise SyncError::InvalidArgument("contract id must not be empty")
  }
  if options.mailbox_bytes < 1 {
    raise SyncError::InvalidArgument("mailbox_bytes must be positive")
  }
  if options.timeout_ms < 1 {
    raise SyncError::InvalidArgument("timeout_ms must be positive")
  }
  let pool = Pool::create({
    worker_url: options.worker_url,
    worker_count: 1,
    capacity: mailbox_capacity_words(options.mailbox_bytes),
    timeout_ms: options.timeout_ms,
    protocol_id: contract.id_,
  }) catch {
    error => raise SyncError::Transport(pool_error_message(error))
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
/// Sends and receives one typed value with a blocking wait. Use this from Deno
/// or another JavaScript agent that permits `Atomics.wait`.
pub fn[Request : ToJson, Response : @json.FromJson] SyncGuest::call(
  self : SyncGuest[Request, Response],
  request : Request,
) -> Response raise SyncError {
  if self.busy {
    raise SyncError::Busy
  }
  self.busy = true
  defer {
    self.busy = false
  }
  self.prepare_call(request)
  ignore(
    self.pool.run(end=0) catch {
      error => raise SyncError::Transport(pool_error_message(error))
    },
  )
  self.finish_call()
}

///|
/// Sends and receives one typed value without blocking a browser document main
/// thread.
pub async fn[Request : ToJson, Response : @json.FromJson] SyncGuest::call_async(
  self : SyncGuest[Request, Response],
  request : Request,
) -> Response raise SyncError {
  if self.busy {
    raise SyncError::Busy
  }
  self.busy = true
  defer {
    self.busy = false
  }
  self.prepare_call(request)
  ignore(
    self.pool.run_async(end=0) catch {
      error => raise SyncError::Transport(pool_error_message(error))
    },
  )
  self.finish_call()
}

///|
/// Returns the maximum encoded request or response size.
pub fn[Request, Response] SyncGuest::mailbox_bytes(
  self : SyncGuest[Request, Response],
) -> Int {
  self.mailbox_bytes_
}

///|
/// Stops the guest Worker. Calling `close` more than once is safe.
pub fn[Request, Response] SyncGuest::close(
  self : SyncGuest[Request, Response],
) -> Unit {
  self.pool.close()
}

///|
fn write_guest_result(
  values : SharedSlice,
  status : Int,
  text : String,
) -> Unit {
  let written = values.write_utf8(mailbox_payload_offset(), text)
  if written < 0 {
    values.store(SYNC_RESPONSE_LENGTH, 0)
    values.store(SYNC_STATUS, SYNC_STATUS_ERROR)
  } else {
    values.store(SYNC_RESPONSE_LENGTH, written)
    values.store(SYNC_STATUS, status)
  }
}

///|
/// Installs a typed handler as a Mayo guest Worker entry point. Request and
/// response types may be arbitrary values implementing MoonBit's JSON traits.
pub fn[Request : @json.FromJson, Response : ToJson] serve_sync(
  contract : SyncContract[Request, Response],
  handler : (Request) -> Response,
) -> Unit {
  install_atomic_worker(contract.id_, fn(shared, slot_base, data_offset) {
    run_worker(shared, slot_base, data_offset, fn(
      values,
      _start,
      _end,
      _argument,
    ) {
      let request_length = values.load(SYNC_REQUEST_LENGTH)
      if request_length < 0 ||
        request_length > values.byte_length() - mailbox_payload_offset() {
        write_guest_result(values, SYNC_STATUS_ERROR, "invalid request length")
        return
      }
      let request_text = values.read_utf8(
        mailbox_payload_offset(),
        request_length,
      )
      let request : Request = @json.from_json(@json.parse(request_text)) catch {
        error => {
          write_guest_result(
            values,
            SYNC_STATUS_ERROR,
            "request did not match the contract: \{error}",
          )
          return
        }
      }
      let response = handler(request)
      write_guest_result(values, SYNC_STATUS_OK, response.to_json().stringify())
    })
  })
}

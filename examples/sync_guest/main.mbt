///|
fn handle(request : @contract.SumRequest) -> @contract.SumResponse {
  let mut total = 0
  for value in request.values {
    total = total + value * request.scale
  }
  {
    message: "hello \{request.name}",
    total,
    item_count: request.values.length(),
  }
}

///|
fn main {
  @mayo.serve_sync(@contract.contract(), handle)
}

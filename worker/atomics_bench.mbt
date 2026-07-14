///|
#borrow(shared)
extern "js" fn atomic_load(shared : @mayo.SharedInts, index : Int) -> Int = "(shared, index) => Atomics.load(shared, index)"

///|
#borrow(shared)
extern "js" fn atomic_store(
  shared : @mayo.SharedInts,
  index : Int,
  value : Int,
) -> Unit = "(shared, index, value) => { Atomics.store(shared, index, value); }"

///|
#borrow(shared)
extern "js" fn atomic_compare_exchange(
  shared : @mayo.SharedInts,
  index : Int,
  expected : Int,
  replacement : Int,
) -> Int = "(shared, index, expected, replacement) => Atomics.compareExchange(shared, index, expected, replacement)"

///|
#borrow(shared)
extern "js" fn atomic_wait(
  shared : @mayo.SharedInts,
  index : Int,
  expected : Int,
) -> Unit = "(shared, index, expected) => { Atomics.wait(shared, index, expected); }"

///|
#borrow(shared)
extern "js" fn atomic_notify_one(
  shared : @mayo.SharedInts,
  index : Int,
) -> Unit = "(shared, index) => { Atomics.notify(shared, index, 1); }"

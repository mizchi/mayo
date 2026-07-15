///|
/// Builds a no-op call used to demonstrate scoped task submission.
pub fn noop() -> @mayo.KernelCall {
  mix(rounds=0)
}

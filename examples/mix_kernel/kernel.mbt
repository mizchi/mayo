///|
/// Builds the typed host-side descriptor for the prebuilt mix kernel.
///
/// This small wrapper is the shape that a future Mayo kernel generator will
/// emit from a registry definition.
pub fn mix(rounds~ : Int) -> @mayo.KernelCall {
  @mayo.kernel_call(argument=rounds)
}

///|
/// Builds a no-op call used to demonstrate scoped task submission.
pub fn noop() -> @mayo.KernelCall {
  @mayo.kernel_call()
}

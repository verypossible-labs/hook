# Hook

A term resolution library.

Dynamic, ancestor-walking, fallback following, group isolated, runtime term resolution that can be
compiled out for zero performance cost where desired.

To understand what Hook does check the [Examples](https://hexdocs.pm/hook/examples.html#content)
documentation. For reference and further understanding check
[Hook](https://hexdocs.pm/hook/Hook.html)'s documentation.

## Motivation

The development of Hook was motivated by a desire for variety of and flexibility in tools relevant
to testing across boundaries and among side effects, though its functionality facilitates more
than that use case.

Hook was inspired by [Mox](https://github.com/dashbitco/mox) and
[Pact](https://github.com/BlakeWilliams/pact). The requirement of behaviours by Mox and the lack
of concurrency support and Mox-like assertion functionality in Pact left us desiring something
else.

### Notable differences

From Mox:

- Behaviours are not required to enforce that defined callbacks match public functions on
  indicated modules.
- Runtime resolution framework included.

From Pact:

- First class callbacks and assertions.
- Runtime resolution can be compiled out.
- Resolution can walk process ancestors and follow fallbacks.
- Resolution calls are not serialized and go concurrently through ets.

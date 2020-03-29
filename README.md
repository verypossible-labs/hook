# Hook

A runtime resolution library.

Dynamic, ancestor-walking, fallback following, group isolated, runtime term resolution that can be
compiled out for zero performance cost where desired.

For further context check [Hook](https://hexdocs.pm/hook)'s public interface and the
[Examples](docs/examples.md) documentation.

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

- Behaviours are not required.
- Runtime resolution framework included.

From Pact:

- First class callbacks and assertions.
- Runtime resolution can be compiled out.
- Resolution can walk process ancestors and follow fallbacks.
- Resolution calls are not serialized and go concurrently through ets.

# Examples

## Module mocks via hooks, callbacks, and asserts

```elixir
defmodule Channel do
  use Hook # 1: import hook/1 macro

  def events_from_database(), do: # ...

  def flush() do
    :ok =
      events_from_database()
      |> Enum.map(&encode/1)
      |> Enum.join()
      # 2: hook a term
      |> hook(Mqtt).publish()
  end

  def submit(payload), do: # ...
end

defmodule ChannelTest do
  test "submitted events are published as single message" do
    payload_1 = "1"
    payload_2 = "2"
    joint_payload = "12"
    # 3: define a callback
    Hook.callback(Mqtt, :publish, fn ^joint_payload -> :ok end)
    :ok = Channel.submit(payload_1)
    :ok = Channel.submit(payload_2)
    :ok = Channel.flush()
    # 4: check for unresolved callbacks
    Hook.assert()
  end
end
```

### Exceptions

Omitting #3 above would cause:

```elixir
** (RuntimeError) Hook: failed to resolve a mapping for Mqtt
```

This is because the hook created at #2 does not `Mqtt` to another value, rather, it only allows
the resolution of a mapping for `Mqtt` to be delayed until runtime. The callback at #3 is actually
what ensures a mapping exists for `Mqtt` that will result in function calls on it being traced so
that assertions may be made.

Altering #3 so that the function name `:publish` was something else, say `:publish2`, would cause:

```elixir
** (RuntimeError) Hook: failed to resolve a Mqtt.publish/1 callback for #PID<0.225.0>
```

We no longer get the previous exception because a mapping does exist for Mqtt, we did define a
callback for it, but the callback we defined did not match what the code was calling.

**Note:** This exception helps find bugs in the code you are testing that would cause it to call a
function on a hooked module more times than you have defined callbacks for it to resolve.

A bug in your code that caused the callback to never be resolved would cause:

```elixir
** (RuntimeError) Hook: unresolved callbacks for #PID<0.672.0>: {1, Mqtt.publish/1}
```

Either you are defining more callbacks than intended or you're not calling the function in
question as many times as intended.

### Callbacks

Leverage multiple clauses.

```elixir
Hook.callback(System, :cmd, fn
  "joy", ["--flag"] -> {"", 0}
  "joy", args -> {"error: --flag required", 1}
end)
```

Define a callback multiple times like this.

```elixir
Hook.callback(System, :cmd, fn cmd, args -> {"joy", 0} end, count: 2)
```

Or separately.

```elixir
Hook.callback(System, :cmd, fn cmd, args -> {"joy", 0} end)
Hook.callback(System, :cmd, fn cmd, args -> {"joy", 0} end)
```

Either of those examples could be consumed twice. `:count` may also be passed `:infinity` which is
a special case.

#### Infinity and beyond

Callbacks with an infinity count can be consumed infinitely. Only one infinity count can be
defined per module and function at a time. The most recent definition persists. Infinity callbacks
are only consumed once all other non-infinity callbacks are exhausted.

### Assertions

```elixir
Hook.callback(System, :cmd, fn _, _ -> {"joy", 0} end)
Hook.assert()
```

Without the assert line, the above snippet would execute without fail. Adding the assert line
causes the following exception.

```elixir
** (RuntimeError) Hook: unresolved callbacks for #PID<0.672.0>: {1, Mqtt.publish/1}
```

## Module resolution

This is a simple example to demonstrate a common pattern of wiring things together. The
`App.MqttMock` could have a much more complex implementation.

```elixir
defmodule App.MqttMock do
  require Logger

  def publish(payload) do
    Logger.debug("published #{inspect payload}")
    :ok
  end
end

defmodule App.Channel do
  # 1: import hook/1 macro
  use Hook

  def events_from_database(), do: # ...

  def submit(payload), do: # ...

  def flush() do
    :ok =
      events_from_database()
      |> Enum.map(&encode/1)
      |> Enum.join()
      # 2: hook a term
      |> hook(Mqtt).publish()
  end
end

defmodule ChannelTest do
  test "flushing multiple events" do
    Hook.put(Mqtt, App.MqttMock)
    :ok = Channel.submit("1")
    :ok = Channel.submit("2")
    assert :ok = Channel.flush()
  end
end
```

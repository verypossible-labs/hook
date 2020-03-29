defmodule Hook do
  @moduledoc """
  An interface to define and leverage runtime resolution.

  # Groups

  Mappings are defined under `t:group/0`s. Hook defaults the group to be the calling process
  making process isolation of mappings frictionless. Any term can also be supplied as the group.
  Putting `:foo` under `:bar` in the `:red` group, than fetching it from the `:blue` group will
  fail.

  # Resolution

  Starting with the calling process:

  1. does the process define a mapping for the term

      1.1. the term has been resolved

  2. does the process define fallbacks

      2.1. for each fallback in order: goto step 1

  3. does the process have ancestors

      3.1. for each ancestor in order: goto step 1

  4. the term has not been resolved

  # Performance

  In general, the thing to focus on with respect to performance is whether the function call is
  getting serialized through a GenServer or not. You will find that only calls that result in a
  write get serialized and those that only read do not.

  Functions that get serialized through a GenServer:

  - `callback/3,4`
  - `fallback/1,2`
  - `put/2,3`
  - `resolve_callback/3`

  Functions that do not get serialized through a GenServer:

  - `assert/0,1`
  - `callbacks/0,1`
  - `fetch!/1,2`
  - `fetch/1,2`
  - `get_all/0,1`
  - `hook/1`

  This means that a "hot path" that is resolving a term via these functions should remain
  performant outside of extreme cases.
  ``
  """

  alias Hook.Server

  @type count() :: pos_integer() | :infinity

  @type group() :: pid() | atom()

  @type callback_opt() :: {:group, group()} | {:count, count()}

  @type callback_opts() :: [callback_opt()]

  @type fun_key() :: {function_name :: atom(), arity :: non_neg_integer()}

  @callback assert(group()) :: :ok

  @callback callback(module(), function_name :: atom(), fun(), callback_opts()) :: :ok

  @callback callbacks(group()) :: %{resolved: [], unresolved: [{count(), pid(), function()}]}

  @callback fallback(dest :: group(), src :: group()) :: :ok

  @callback fetch(key :: any(), group()) :: {:ok, any()} | :error

  @callback fetch!(any(), group()) :: any()

  @callback get_all(group()) :: {:ok, %{}} | :error

  @callback put(from :: module(), to :: module(), group()) :: :ok

  @callback resolve_callback(module(), fun_key(), args :: [any()]) :: any()

  defmacro __using__(_opts) do
    quote do
      import Hook, only: [hook: 1]
    end
  end

  @doc """
  A macro that compiles into `term` itself or a `Hook.fetch(term)` call.

  By default the fetch call will only be used when the Mix environment is not `:prod`. This logic
  can be overidden by the `:should_hook` configuration:

  ```
  config :hook,
    should_hook: {SomeModule, :some_function}
  ```

  `:should_hook` will be called with a single argument that is a term being processed by the
  `hook/1` macro and must return a boolean(). This evaluation will happen at compile time.
  """
  defmacro hook(term) do
    case Application.fetch_env(:hook, :should_hook) do
      {module, function_name} ->
        case apply(module, function_name, [term]) do
          true ->
            quote do
              Hook.fetch!(unquote(term))
            end

          _ ->
            quote do
              unquote(term)
            end
        end

      _ ->
        case Mix.env() do
          :prod ->
            quote do
              unquote(term)
            end

          _ ->
            quote do
              Hook.fetch!(unquote(term))
            end
        end
    end
  end

  @doc """
  Asserts that all non-infinity callbacks defined via `Hook.callback/4` have been consumed.

  Returns `:ok` or raises.
  """
  defdelegate assert(group \\ self()), to: Server

  @doc """
  Defines a callback that can be consumed `count` times.

  Ensures a module value is put under the key `module` for the calling process.
  """
  defdelegate callback(module, function_name, function, opts \\ []), to: Server

  @doc """
  Return `group`'s callbacks.
  """
  defdelegate callbacks(group \\ self()), to: Server

  @doc """
  Prepend `group` to the calling process' fallbacks.
  """
  defdelegate fallback(src_group \\ self(), dest_group), to: Server

  @doc """
  Gets all values for `group`.
  """
  defdelegate get_all(group \\ self()), to: Server

  @doc """
  Puts `value` under `key` for `group`.
  """
  defdelegate put(key, value, group \\ self()), to: Server

  @doc """
  Fetches the value for `key` for `group`.
  """
  defdelegate fetch(key, group \\ self()), to: Server

  @doc """
  See `Hook.fetch/2`.
  """
  defdelegate fetch!(key, group \\ self()), to: Server

  @doc """
  Resolves a callback for the calling process and executes it with `args`.
  """
  defdelegate resolve_callback(module, fun_key, args), to: Server
end

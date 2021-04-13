defmodule Hook do
  @moduledoc """
  An interface to define and leverage runtime resolution.

  In various module and function docs it is common to document options like so:

  > # Options
  >
  > - `:option1_name` - `type`. # since no default is specified, this option is required
  > - `:option2_name` - `type`. Descriptive text. # since no default is specified, this option is required
  > - `:option3_name` - `type`. `default`. # since a default is specified, this option is not required
  > - `:option4_name` - `type`. `default`. Descriptive text. # since a default is specified, this option is not required

  # Compile time Configuration

  These options can be set compile time to configure how `m:Hook.hook/1` behaves. `m:Hook.hook/1`
  will be referred to as "the macro".

  - `mappings` - `keyword()`. Mappings that the macro will resolve against.
  - `resolve_at` - `:compile_time | :run_time | :never`. When `:compile_time` or `:run_time`, the
    macro will resolve its term at the respective time. When `:never`, the macro will compile
    directly into its term with no attempt to resolve against mappings.
  - `top_level_module_allowlist` - `[module()]`. When the macro's calling module's
    top-level-module is in this list, the `:resolve_at` option will be respected. Otherwise, it
    will behave as if `resolve_at: :never` for that instance of the macro. This allows developers
    to control whether or not individual instances of the macro should ever attempt resolution or
    not with a top-level-module granularity. The common value for this option is the top level
    module of your application so that any instance of the macro throughout your application's
    code will respect the `:resolve_at` option, and any instance of the macro outside your
    application's code will behave as if `resolve_at: :never`. An example of "code outside your
    application" is if any of your application's dependencies happen to also use the macro.

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

  3. does the process have :"$ancestors"

      3.1. for each ancestor in order: goto step 1

  3. does the process have :"$callers"

      3.1. for each caller in order: goto step 1

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
  - `get/1,2,3`
  - `get_all/0,1`
  - `hook/1`

  This means that a "hot path" that is resolving a term via these functions should remain
  performant outside of extreme cases.
  """

  alias Hook.Server

  @resolve_at Application.compile_env!(:hook, :resolve_at)
  @top_level_module_allowlist Application.compile_env!(:hook, :top_level_module_allowlist)
  @mappings Application.compile_env!(:hook, :mappings)

  @type callback_opt() :: {:group, group()} | {:count, count()}
  @type callback_opts() :: [callback_opt()]
  @type config() :: %{hook?: boolean() | (any() -> boolean())}
  @type count() :: pos_integer() | :infinity
  @type fun_key() :: {function_name :: atom(), arity :: non_neg_integer()}
  @type group() :: pid() | atom()
  @type key() :: any()
  @type mappings() :: [{key(), value()} | {key(), value(), group()}]
  @type value() :: any()

  @callback assert(group()) :: :ok
  @callback callback(module(), function_name :: atom(), fun(), callback_opts()) :: :ok
  @callback callbacks(group()) :: %{resolved: [], unresolved: [{count(), pid(), function()}]}
  @callback fallback(dest :: group(), src :: group()) ::
              :ok | {:error, {:invalid_group, :destination | :source}}
  @callback fetch!(any(), group()) :: any()
  @callback fetch(key(), group()) :: {:ok, any()} | :error
  @callback get(key(), default :: any(), group()) :: {:ok, any()} | :error
  @callback get_all(group()) :: {:ok, %{}} | :error
  @callback put(key(), value(), group()) :: :ok
  @callback put_all(mappings()) :: :ok
  @callback put_all(mappings(), group()) :: :ok
  @callback resolve_callback(module(), fun_key(), args :: [any()]) :: any()

  defmacro __using__(_opts) do
    quote do
      import Hook, only: [hook: 1]
    end
  end

  @doc """
  A macro that compiles into `term` itself or a `Hook.fetch(term)` call.

  Check the "Compile time Configuration" section for information about configuring this
  functionality.
  """
  defmacro hook(term) do
    caller_top_level_module =
      __CALLER__.module
      |> Module.split()
      |> hd()
      |> List.wrap()
      |> Module.concat()

    valid_caller_module = caller_top_level_module in @top_level_module_allowlist

    cond do
      valid_caller_module ->
        case @resolve_at do
          :run_time ->
            quote do
              Hook.get(unquote(term), unquote(term))
            end

          :compile_time ->
            expanded = Macro.expand(term, __CALLER__)

            if not Macro.quoted_literal?(expanded) do
              raise("When the hook strategy is :compile_time, hooked terms must be literals.")
            end

            value =
              case List.keyfind(@mappings, expanded, 0) do
                mapping when tuple_size(mapping) >= 2 -> elem(mapping, 1)
                _ -> expanded
              end

            quote do
              unquote(value)
            end

          :never ->
            quote do
              unquote(term)
            end
        end

      true ->
        quote do
          unquote(term)
        end
    end
  end

  @doc """
  Asserts that all callbacks defined via `Hook.callback/4` have been satisfied.

  Returns `:ok` if the assertion holds, raises otherwise.

  Infinity-callbacks and 0-callbacks are inherently satisfied.
  """
  defdelegate assert(group \\ self()), to: Server

  @doc """
  Defines a callback that can be consumed and asserted on.

  **Note:** `module` will be defined under the calling process.

  This function will raise when the specified callback is not a public function on `module`.

  # Options

  `:count` - How many times the callback can be consumed.
    - `:infinity` - The callback can be consumed an infinite number of times. For a module,
      function, and arity, only a single infinity-callback will be defined at once, last write
      wins. Infinity-callbacks are always consumed after non-infinity-callbacks.
    - `0` - The callback should never be consumed. Raises an error if it is. The callback is
      removed upon raising.
  """
  defdelegate callback(module, function_name, function, opts \\ []), to: Server

  @doc """
  Return `group`'s callbacks.
  """
  defdelegate callbacks(group \\ self()), to: Server

  @doc """
  Prepend `group` to the calling process' fallbacks.

  **NOTE:** `:global` cannot be used as a `src_group`.
  """
  defdelegate fallback(src_group \\ self(), dest_group), to: Server

  @doc """
  Gets the value for `key` for `group` returning `default` if it is not defined.
  """
  defdelegate get(key, default \\ nil, group \\ self()), to: Server

  @doc """
  Gets all values for `group`.
  """
  defdelegate get_all(group \\ self()), to: Server

  @doc """
  Puts `value` under `key` for `group`.
  """
  defdelegate put(key, value, group \\ self()), to: Server

  @doc """
  Puts all key value pairs under `group`.
  """
  defdelegate put_all(kvps, group \\ self()), to: Server

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

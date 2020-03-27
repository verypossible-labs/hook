defmodule Hook.Server do
  @moduledoc false

  use GenServer
  alias Hook.Callbacks

  @behaviour Hook

  def __delete__ do
    GenServer.call(__MODULE__, :delete)
  end

  def __fetch__(group) when is_pid(group) or is_atom(group),
    do: __fetch__([group], &{:ok, &1})

  def __fetch__(match_fun) when is_function(match_fun), do: __fetch__([self()], match_fun)

  def __fetch__([group | groups], match_fun) do
    group = resolve_group(group)

    group
    |> do_fetch(groups, match_fun)
    |> case do
      {:ok, _} = ret ->
        ret

      {:error, []} ->
        group
        |> get_ancestors()
        |> case do
          {:ok, ancestors} -> __fetch__(ancestors, match_fun)
          :error -> :error
        end

      {:error, groups} ->
        __fetch__(groups, match_fun)
    end
  end

  def __fetch__(group, match_fun), do: __fetch__([group], match_fun)

  @impl Hook
  def assert(group) do
    {:ok, group_state} = __fetch__(group)
    Callbacks.assert(group_state)
  end

  @impl Hook
  def callback(module, function_name, function, opts) do
    opts =
      opts
      |> Keyword.put_new(:count, 1)
      |> Keyword.put_new(:group, self())

    GenServer.call(__MODULE__, {:callback, module, function_name, function, opts})
  end

  @impl Hook
  def callbacks(group) do
    {:ok, group_state} = __fetch__(group)
    Callbacks.get_all(group_state)
  end

  @impl Hook
  def fallback(src, dest), do: GenServer.call(__MODULE__, {:fallback, {src, dest}})

  @impl Hook
  def fetch(key, group) do
    __fetch__(group, fn
      %{mappings: %{^key => value}} -> {:ok, value}
      _ -> :error
    end)
  end

  @impl Hook
  def fetch!(key, group) do
    key
    |> fetch(group)
    |> case do
      {:ok, ret} -> ret
      _ -> raise_no_mapping_found(key)
    end
  end

  @impl Hook
  def get_all(group), do: __fetch__(group, fn %{mappings: ret} -> {:ok, ret} end)

  @impl GenServer
  def handle_call({:callback, module, function_name, function, opts}, _, state) do
    :ok = Callbacks.define(module, function_name, function, opts)
    {:reply, :ok, state}
  end

  def handle_call(:delete, _, state) do
    :ets.delete_all_objects(Hook)
    {:reply, :ok, state}
  end

  def handle_call({:put, key, value, group}, _, state) do
    {:ok, group_state} = __fetch__(group)
    group_state = put_in(group_state, [:mappings, key], value)
    :ets.insert(Hook, {group, group_state})
    {:reply, :ok, state}
  end

  def handle_call({:resolve_callback, module, fun_key, args}, {caller, _}, state) do
    __fetch__(caller, fn
      %{mappings: %{callbacks: %{^module => %{^fun_key => %{unresolved: [_ | _]}}}}} = group_state ->
        {:ok, group_state}

      _ ->
        :error
    end)
    |> case do
      {:ok, group_state} ->
        case Callbacks.resolve(group_state, module, fun_key, args, caller) do
          {ret, group_state} ->
            :ets.insert(Hook, {group_state.group, group_state})
            {:reply, {:ok, ret}, state}
        end

      _ ->
        {:reply, :error, state}
    end
  end

  def handle_call({:fallback, mapping}, _, state) do
    do_fallback(mapping)
    {:reply, :ok, state}
  end

  @impl GenServer
  def init([]) do
    Hook = :ets.new(Hook, [:named_table, :protected])
    {:ok, %{}}
  end

  @impl Hook
  def put(key, value, group) do
    GenServer.call(__MODULE__, {:put, key, value, group})
  end

  @impl Hook
  def resolve_callback(module, {_, _} = fun_key, args) do
    case GenServer.call(__MODULE__, {:resolve_callback, module, fun_key, args}) do
      {:ok, ret} ->
        ret

      :error ->
        {function_name, arity} = fun_key
        Callbacks.raise_no_callback_found(module, function_name, arity, self())
    end
  end

  @doc """
  Start a GenServer.
  """
  @spec start_link([]) :: GenServer.on_start()
  def start_link([]) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  defp do_fallback({src, dest}) do
    {fallbacks, group_state} =
      src
      |> __fetch__()
      |> case do
        {:ok, %{fallbacks: fallbacks} = group_state} -> {fallbacks, group_state}
        {:ok, group_state} -> {[], group_state}
      end

    group_state = Map.put(group_state, :fallbacks, Enum.concat(fallbacks, [dest]))
    :ets.insert(Hook, {src, group_state})
  end

  defp do_fetch(group, groups, match_fun) do
    case :ets.lookup(Hook, group) do
      [] ->
        case match_fun.(term_map(group)) do
          {:ok, _} = x -> x
          :error -> {:error, groups}
        end

      [{_, group_state}] ->
        case match_fun.(group_state) do
          {:ok, _} = x ->
            x

          :error ->
            %{fallbacks: fallbacks} = group_state
            {:error, fallbacks ++ groups}
        end
    end
  end

  defp get_ancestors(pid) when is_pid(pid) do
    pid
    |> Process.info(:dictionary)
    |> case do
      nil ->
        :error

      {_, dictionary} ->
        dictionary
        |> Keyword.get(:"$ancestors")
        |> case do
          [_ | _] = ancestors -> {:ok, ancestors}
          _ -> :error
        end
    end
  end

  defp get_ancestors(_), do: :error

  defp term_map(group) do
    %{fallbacks: [], group: group, mappings: %{}}
  end

  defp raise_no_mapping_found(term) do
    raise("Hook: failed to resolve a mapping for #{inspect(term)}")
  end

  defp resolve_group(group) do
    case GenServer.whereis(group) do
      nil -> group
      pid -> pid
    end
  end
end

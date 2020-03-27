defmodule Hook.Callbacks do
  @moduledoc false

  alias Hook.Server

  def assert(group_state) do
    case get(group_state, :unresolved, false) do
      [] -> :ok
      callbacks -> raise_unresolved_callbacks(group_state.group, callbacks)
    end
  end

  def define(module, function_name, function, opts) do
    name = Module.concat([Hook, module])
    body = [generate_functions(module)]

    unless function_exported?(name, :__info__, 1) do
      Module.create(name, body, Macro.Env.location(__ENV__))
    end

    count = Keyword.fetch!(opts, :count)
    functions = [{count, function}]
    {:arity, arity} = :erlang.fun_info(function, :arity)
    fun_key = {function_name, arity}
    group = Keyword.fetch!(opts, :group)
    {:ok, group_state} = Server.__fetch__(group)
    group_state = append(group_state, module, fun_key, name, functions)
    :ets.insert(Hook, {group, group_state})
    :ok
  end

  def get(group_state, type, include_infinity) do
    case Map.fetch(group_state.mappings, :callbacks) do
      {:ok, callbacks} -> reduce_callbacks(callbacks, type, include_infinity)
      _ -> []
    end
  end

  def get_all(group_state) do
    %{
      resolved: get(group_state, :resolved, true),
      unresolved: get(group_state, :unresolved, true)
    }
  end

  def raise_no_callback_found(module, fun, arity, pid) do
    raise "Hook: failed to resolve a #{inspect(module)}.#{fun}/#{arity} callback for #{
            inspect(pid)
          }"
  end

  def resolve(group_state, module, {function_name, arity} = fun_key, args, caller) do
    group_state
    |> get_and_update_in([:mappings, :callbacks, module, fun_key], fn
      nil ->
        raise_no_callback_found(module, function_name, arity, caller)

      %{unresolved: []} ->
        raise_no_callback_found(module, function_name, arity, caller)

      %{unresolved: [{:infinity, cb} | []]} = fun_map ->
        {apply(cb, args),
         %{
           resolved: fun_map.resolved ++ [{:infinity, caller, cb}],
           unresolved: fun_map.unresolved
         }}

      %{unresolved: [{1, cb} | unresolved]} = fun_map ->
        fun_map = %{
          resolved: Map.get(fun_map, :resolved, []) ++ [{1, caller, cb}],
          unresolved: unresolved
        }

        {apply(cb, args), fun_map}

      %{unresolved: [{count, cb} | unresolved]} = fun_map ->
        {apply(cb, args),
         %{
           resolved: fun_map.resolved ++ [{count, caller, cb}],
           unresolved: [{count - 1, cb} | unresolved]
         }}
    end)
  end

  defp append(group_state, module, fun_key, name, functions) do
    case group_state do
      # update fun_key
      %{mappings: %{callbacks: %{^module => %{^fun_key => %{unresolved: acc_functions}}}}} =
          group_state ->
        functions = join_functions(acc_functions, functions)
        put_in(group_state, [:mappings, :callbacks, module, fun_key, :unresolved], functions)

      # define fun_key for the first time
      %{mappings: %{callbacks: %{^module => _}}} = group_state ->
        put_in(group_state, [:mappings, :callbacks, module, fun_key], %{
          resolved: [],
          unresolved: functions
        })

      # define the module for the first time
      %{mappings: %{callbacks: %{}}} = group_state ->
        fun_map = %{fun_key => %{resolved: [], unresolved: functions}}

        group_state
        |> put_in([:mappings, module], name)
        |> put_in([:mappings, :callbacks, module], fun_map)

      # define callbacks for the first time
      group_state ->
        callbacks = %{module => %{fun_key => %{resolved: [], unresolved: functions}}}

        group_state
        |> put_in([:mappings, module], name)
        |> put_in([:mappings, :callbacks], callbacks)
    end
  end

  defp join_functions(old, new) do
    case Enum.split_with(new, fn {count, _} -> count == :infinity end) do
      {[], finite_new} ->
        case Enum.split(old, -1) do
          {top, [{:infinity, _}] = tail} -> top ++ finite_new ++ tail
          _ -> old ++ finite_new
        end

      {infinity_new, finite_new} ->
        old =
          case Enum.split(old, -1) do
            {top, [{:infinity, _}]} -> top
            _ -> old
          end

        old ++ finite_new ++ [List.last(infinity_new)]
    end
  end

  defp callbacks_to_string(callbacks) do
    callbacks
    |> Enum.map(fn
      {count, module, {function_name, arity}} ->
        "{#{count}, #{inspect(module)}.#{function_name}/#{inspect(arity)}}"

      {count, pid, module, {function_name, arity}} ->
        "{#{count}, #{inspect(pid)}, #{inspect(module)}.#{function_name}/#{inspect(arity)}}"
    end)
    |> Enum.join(", ")
  end

  defp generate_functions(module) do
    for {fun, arity} <- module.__info__(:functions) do
      args =
        0..arity
        |> Enum.to_list()
        |> tl()
        |> Enum.map(&Macro.var(:"arg#{&1}", Elixir))

      quote location: :keep do
        def unquote(fun)(unquote_splicing(args)) do
          Hook.Server.resolve_callback(
            unquote(module),
            {unquote(fun), unquote(arity)},
            unquote(args)
          )
        end
      end
    end
  end

  defp raise_unresolved_callbacks(pid, callbacks) do
    raise "Hook: unresolved callbacks for #{inspect(pid)}: #{callbacks_to_string(callbacks)}"
  end

  defp reduce_callbacks(callbacks, type, include_infinity) do
    Enum.reduce(callbacks, [], fn {module, fun_map}, acc ->
      reduce_fun_map(type, include_infinity, module, fun_map, acc)
    end)
  end

  defp reduce_fun_map(type, include_infinity, module, fun_map, acc) do
    Enum.reduce(fun_map, [], fn {fun_key, %{^type => functions}}, acc ->
      reduce_functions(include_infinity, fun_key, module, functions, acc)
    end) ++ acc
  end

  defp reduce_functions(include_infinity, {function_name, arity}, module, functions, acc) do
    Enum.reduce(functions, [], fn
      {:infinity = count, _}, acc ->
        cond do
          include_infinity -> [{count, module, {function_name, arity}} | acc]
          true -> acc
        end

      {count, function}, acc ->
        {:arity, arity} = :erlang.fun_info(function, :arity)
        [{count, module, {function_name, arity}} | acc]

      {count, pid, function}, acc ->
        {:arity, arity} = :erlang.fun_info(function, :arity)
        [{count, pid, module, {function_name, arity}} | acc]
    end) ++ acc
  end
end

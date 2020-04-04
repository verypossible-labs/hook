defmodule Hook.Callbacks do
  @moduledoc false

  alias Hook.Server

  def assert(group_state) do
    case get(group_state, :unresolved, [0, :infinity]) do
      [] -> :ok
      callbacks -> raise_unresolved_callbacks(group_state.group, callbacks)
    end
  end

  def define(module, function_name, function, opts) do
    name = Module.concat([Hook, module])
    {body, function_names} = generate_functions(module)
    {:arity, arity} = :erlang.fun_info(function, :arity)
    fun_key = {function_name, arity}

    case function_name in function_names do
      true ->
        unless function_exported?(name, :__info__, 1) do
          Module.create(name, body, Macro.Env.location(__ENV__))
        end

        count = Keyword.fetch!(opts, :count)
        functions = [{count, function}]
        group = Keyword.fetch!(opts, :group)
        {:ok, group_state} = Server.__fetch__(group)
        group_state = append(group_state, module, fun_key, name, functions)
        :ets.insert(Hook, {group, group_state})
        :ok

      false ->
        {:error, {:not_public_function, module, fun_key}}
    end
  end

  def get(group_state, type, excludes \\ []) do
    case Map.fetch(group_state.mappings, :callbacks) do
      {:ok, callbacks} -> reduce_callbacks(callbacks, type, excludes)
      _ -> []
    end
  end

  def get_all(group_state) do
    %{
      resolved: get(group_state, :resolved),
      unresolved: get(group_state, :unresolved)
    }
  end

  def raise_callback_refuted(module, fun_key, pid) do
    raise(
      "Hook: attempted to resolve refuted callback #{format_function(module, fun_key)} for #{
        inspect(pid)
      }"
    )
  end

  def raise_no_callback_found(module, fun_key, pid) do
    raise "Hook: failed to resolve a #{format_function(module, fun_key)} callback for #{
            inspect(pid)
          }"
  end

  def raise_not_public_function(module, fun_key) do
    raise "Hook: failed to define a #{format_function(module, fun_key)} callback because that is not a public function on that module"
  end

  def resolve(group_state, module, {function_name, arity} = fun_key, caller) do
    group_state
    |> get_and_update_in([:mappings, :callbacks, module, fun_key], fn
      nil ->
        raise_no_callback_found(module, {function_name, arity}, caller)

      %{unresolved: []} ->
        raise_no_callback_found(module, {function_name, arity}, caller)

      %{unresolved: [{:infinity, cb} | []]} = fun_map ->
        get = {:ok, cb}

        update = %{
          resolved: fun_map.resolved ++ [{:infinity, caller, cb}],
          unresolved: fun_map.unresolved
        }

        {get, update}

      %{unresolved: [{1, cb} | unresolved]} = fun_map ->
        get = {:ok, cb}

        update = %{
          resolved: Map.get(fun_map, :resolved, []) ++ [{1, caller, cb}],
          unresolved: unresolved
        }

        {get, update}

      %{unresolved: [{0, _cb} | unresolved]} = fun_map ->
        get = {:error, :refute}
        update = %{fun_map | unresolved: unresolved}
        {get, update}

      %{unresolved: [{count, cb} | unresolved]} = fun_map ->
        get = {:ok, cb}

        update = %{
          resolved: fun_map.resolved ++ [{count, caller, cb}],
          unresolved: [{count - 1, cb} | unresolved]
        }

        {get, update}
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
      {count, module, fun_key} ->
        "{#{count}, #{format_function(module, fun_key)}}"

      {count, pid, module, fun_key} ->
        "{#{count}, #{inspect(pid)}, #{format_function(module, fun_key)}}"
    end)
    |> Enum.join(", ")
  end

  defp generate_functions(module) do
    {ast, function_names} =
      for {function_name, arity} <- module.__info__(:functions), reduce: {[], []} do
        {acc_1, acc_2} ->
          args =
            0..arity
            |> Enum.to_list()
            |> tl()
            |> Enum.map(&Macro.var(:"arg#{&1}", Elixir))

          ast =
            quote location: :keep do
              def unquote(function_name)(unquote_splicing(args)) do
                Hook.Server.resolve_callback(
                  unquote(module),
                  {unquote(function_name), unquote(arity)},
                  unquote(args)
                )
              end
            end

          {[ast | acc_1], [function_name | acc_2]}
      end

    {Enum.reverse(ast), Enum.reverse(function_names)}
  end

  defp format_function(module, {function_name, arity}) do
    "#{inspect(module)}.#{function_name}/#{arity}"
  end

  defp raise_unresolved_callbacks(pid, callbacks) do
    raise "Hook: unresolved callbacks for #{inspect(pid)}: #{callbacks_to_string(callbacks)}"
  end

  defp reduce_callbacks(callbacks, type, excludes) do
    Enum.reduce(callbacks, [], fn {module, fun_map}, acc ->
      reduce_fun_map(type, excludes, module, fun_map, acc)
    end)
  end

  defp reduce_fun_map(type, excludes, module, fun_map, acc) do
    Enum.reduce(fun_map, [], fn {fun_key, %{^type => functions}}, acc ->
      reduce_functions(excludes, fun_key, module, functions, acc)
    end) ++ acc
  end

  defp reduce_functions(excludes, {function_name, arity}, module, functions, acc) do
    functions
    |> Enum.filter(fn tuple -> elem(tuple, 0) not in excludes end)
    |> Enum.reduce([], fn
      {count, _function}, acc -> [{count, module, {function_name, arity}} | acc]
      {count, pid, _function}, acc -> [{count, pid, module, {function_name, arity}} | acc]
    end)
    |> Enum.concat(acc)
  end
end

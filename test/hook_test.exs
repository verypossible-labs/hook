defmodule HookTest do
  use ExUnit.Case, async: false

  doctest Hook

  setup do
    {:ok, _pid} = Hook.Server.start_link([])
    :ok
  end

  describe "put/3 and fetch/2" do
    test "default group" do
      :ok = Hook.put(:key, :value)
      assert {:ok, :value} == Hook.fetch(:key)
      assert :value == Hook.fetch!(:key)
      assert :error == Hook.fetch(:bad_key)

      assert %RuntimeError{message: "Hook: failed to resolve a mapping for :bad_key"} ==
               catch_error(Hook.fetch!(:bad_key))
    end

    test "provided group", context do
      :ok = Hook.put(:key, :value, context.test)
      assert {:ok, :value} == Hook.fetch(:key, context.test)
      assert :value == Hook.fetch!(:key, context.test)
      assert :error == Hook.fetch(:bad_key, context.test)

      assert %RuntimeError{message: "Hook: failed to resolve a mapping for :bad_key"} ==
               catch_error(Hook.fetch!(:bad_key, context.test))
    end

    test "process isolation" do
      :ok = Hook.put(:key, :value)
      parent = self()

      spawn(fn ->
        :ok = Hook.put(:key2, :value)
        assert :error == Hook.fetch(:key)
        send(parent, :sync)
      end)

      assert_receive :sync
      assert :value == Hook.fetch!(:key)
      assert :error == Hook.fetch(:key2)
    end

    test "ancestor resolution" do
      value = :value
      :ok = Hook.put(:key, value)

      task =
        Task.async(fn -> Task.await(Task.async(fn -> assert value == Hook.fetch!(:key) end)) end)

      Task.await(task)
    end

    test "fallback resolution" do
      value = :value
      parent = self()

      pid_1 =
        spawn(fn ->
          :ok = Hook.put(:key, value)
          send(parent, :sync_1)
        end)

      pid_2 =
        spawn(fn ->
          :ok = Hook.fallback(pid_1)
          send(parent, :sync_2)
        end)

      assert_receive :sync_1
      assert_receive :sync_2
      assert :error == Hook.fetch(:key)
      Hook.fallback(pid_2)
      assert value == Hook.fetch!(:key)
    end
  end

  test "get_all/1", context do
    :ok = Hook.put(:key_1, :value_1)
    :ok = Hook.put(:key_2, :value_2, context.test)
    assert {:ok, %{key_1: :value_1}} == Hook.get_all()
    assert {:ok, %{key_2: :value_2}} == Hook.get_all(context.test)
  end

  describe "assert/0" do
    test "unresolved callback causes an error" do
      Hook.callback(DateTime, :utc_now, fn -> ~U[2015-01-13 13:00:07Z] end)
      assert %RuntimeError{message: message} = catch_error(Hook.assert())
      assert message =~ "Hook: unresolved callbacks for #PID<"
      assert message =~ ">: {1, DateTime.utc_now/0}"
    end

    test "resolved callback" do
      Hook.callback(DateTime, :utc_now, fn -> ~U[2015-01-13 13:00:07Z] end)
      Hook.resolve_callback(DateTime, {:utc_now, 0}, [])
      assert :ok = Hook.assert()
    end
  end

  describe "callback/4" do
    test "multiple separate callbacks for the same function" do
      Hook.callback(DateTime, :utc_now, fn -> ~U[2015-01-13 13:00:07Z] end)
      Hook.callback(DateTime, :utc_now, fn -> ~U[2015-01-13 13:00:07Z] end)
      Hook.resolve_callback(DateTime, {:utc_now, 0}, [])
      Hook.resolve_callback(DateTime, {:utc_now, 0}, [])
      assert :ok = Hook.assert()
    end

    test "count: 0, happy path" do
      Hook.callback(DateTime, :utc_now, fn -> ~U[2015-01-13 13:00:07Z] end, count: 0)
      assert :ok = Hook.assert()
    end

    test "count: 0, violated assertion" do
      Hook.callback(DateTime, :utc_now, fn -> ~U[2015-01-13 13:00:07Z] end, count: 0)

      assert %RuntimeError{message: message} =
               catch_error(elem(Hook.fetch(DateTime), 1).utc_now())

      assert message =~
               "Hook: attempted to resolve refuted callback DateTime.utc_now/0 for #PID<"
    end

    test "count: 2" do
      Hook.callback(DateTime, :utc_now, fn -> ~U[2015-01-13 13:00:07Z] end, count: 2)
      Hook.resolve_callback(DateTime, {:utc_now, 0}, [])
      Hook.resolve_callback(DateTime, {:utc_now, 0}, [])
      assert :ok = Hook.assert()
    end

    test "infinity-callback: multiple resolutions" do
      Hook.callback(DateTime, :utc_now, fn -> ~U[2015-01-13 13:00:07Z] end, count: :infinity)
      Hook.resolve_callback(DateTime, {:utc_now, 0}, [])
      Hook.resolve_callback(DateTime, {:utc_now, 0}, [])
      assert :ok = Hook.assert()
    end

    test "infinity-callback: go behind non-infinity callbacks" do
      Hook.callback(DateTime, :utc_now, fn -> 2 end, count: :infinity)
      Hook.callback(DateTime, :utc_now, fn -> 1 end)
      assert 1 = Hook.resolve_callback(DateTime, {:utc_now, 0}, [])
      assert 2 = Hook.resolve_callback(DateTime, {:utc_now, 0}, [])
      assert 2 = Hook.resolve_callback(DateTime, {:utc_now, 0}, [])
      Hook.callback(DateTime, :utc_now, fn -> 3 end, count: :infinity)
      assert 3 = Hook.resolve_callback(DateTime, {:utc_now, 0}, [])
      assert 3 = Hook.resolve_callback(DateTime, {:utc_now, 0}, [])
    end

    test "infinity-callback: only one at a time, last write wins" do
      Hook.callback(DateTime, :utc_now, fn -> 1 end, count: :infinity)
      Hook.callback(DateTime, :utc_now, fn -> 2 end, count: :infinity)
      assert %{unresolved: [{:infinity, DateTime, {:utc_now, 0}}]} = Hook.callbacks()
    end

    test "defining a callback for a function that is not a public function on the module fails" do
      assert %RuntimeError{message: message} =
               catch_error(Hook.callback(DateTime, :utc_now2, fn -> ~U[2015-01-13 13:00:07Z] end))

      assert message =~
               "Hook: failed to define a DateTime.utc_now2/0 callback because that is not a public function on that module"
    end
  end

  describe "resolve_callback/3" do
    test "resolving an undefined callback causes an error" do
      assert %RuntimeError{message: message} =
               catch_error(Hook.resolve_callback(DateTime, {:utc_now, 0}, []))

      assert message =~
               "Hook: failed to resolve a DateTime.utc_now/0 callback for #{inspect(self())}"
    end
  end
end

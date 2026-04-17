defmodule MirrorNeuron.Builtins.ModuleTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Builtins.Module

  defmodule DummyDelegate do
    def init(_node), do: {:ok, %{hits: 0}}
    def handle_message(_msg, state, _ctx), do: {:ok, %{state | hits: state.hits + 1}, []}
    def recover(state, _ctx), do: {:ok, state, []}
    def snapshot_state(state), do: state
    def restore_state(snap), do: {:ok, snap}
    def inspect_state(state), do: state
  end

  defmodule FailingDelegate do
    def init(_node), do: {:ok, %{}}
    def handle_message(_msg, state, _ctx), do: {:error, "failed msg", state}
    def recover(state, _ctx), do: {:error, "failed recover", state}
  end

  test "init resolves atom module and delegates" do
    node = %{config: %{"module" => MirrorNeuron.Builtins.ModuleTest.DummyDelegate}}
    assert {:ok, state} = Module.init(node)
    assert state.delegate == DummyDelegate
    assert state.delegate_state.hits == 0
  end

  test "init resolves string module and delegates" do
    node = %{config: %{"module" => "MirrorNeuron.Builtins.ModuleTest.DummyDelegate"}}
    assert {:ok, state} = Module.init(node)
    assert state.delegate == DummyDelegate
  end

  test "init fails if module not provided" do
    assert {:error, "module agent requires" <> _} = Module.init(%{config: %{}})
  end

  test "handle_message delegates to module" do
    node = %{config: %{"module" => DummyDelegate}}
    {:ok, state} = Module.init(node)

    assert {:ok, next_state, []} = Module.handle_message(%{}, state, %{})
    assert next_state.delegate_state.hits == 1
  end

  test "handle_message propagates delegate error" do
    node = %{config: %{"module" => FailingDelegate}}
    {:ok, state} = Module.init(node)

    assert {:error, "failed msg", _} = Module.handle_message(%{}, state, %{})
  end

  test "recover delegates to module" do
    node = %{config: %{"module" => DummyDelegate}}
    {:ok, state} = Module.init(node)

    assert {:ok, next_state, []} = Module.recover(state, %{})
    assert next_state.delegate_state == state.delegate_state
  end

  test "recover propagates delegate error" do
    node = %{config: %{"module" => FailingDelegate}}
    {:ok, state} = Module.init(node)

    assert {:error, "failed recover", _} = Module.recover(state, %{})
  end

  test "snapshot and restore state" do
    node = %{config: %{"module" => DummyDelegate}}
    {:ok, state} = Module.init(node)

    snap = Module.snapshot_state(state)
    assert snap["delegate"] == "Elixir.MirrorNeuron.Builtins.ModuleTest.DummyDelegate"

    assert {:ok, restored} = Module.restore_state(snap)
    assert restored.delegate == DummyDelegate
    assert restored.delegate_state == state.delegate_state
  end

  test "restore_state fails on invalid format" do
    assert {:error, _} = Module.restore_state(%{"wrong" => "format"})
  end

  test "inspect_state delegates" do
    node = %{config: %{"module" => DummyDelegate}}
    {:ok, state} = Module.init(node)

    inspected = Module.inspect_state(state)
    assert inspected["delegate"] == "Elixir.MirrorNeuron.Builtins.ModuleTest.DummyDelegate"
    assert inspected["delegate_state"] == %{hits: 0}
  end

  test "ensure_module_loaded with module_source dynamic compilation" do
    # create a dummy module
    dir = "test_module_sources"
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "dynamic.ex"), """
    defmodule DynamicTestModule do
      def init(_), do: {:ok, %{}}
    end
    """)

    on_exit(fn -> File.rm_rf!(dir) end)

    node = %{
      config: %{
        "module" => "DynamicTestModule",
        "module_source" => "dynamic.ex",
        "__payloads_path" => Path.expand(dir)
      }
    }

    assert {:ok, state} = Module.init(node)
    assert state.delegate == DynamicTestModule
  end
end

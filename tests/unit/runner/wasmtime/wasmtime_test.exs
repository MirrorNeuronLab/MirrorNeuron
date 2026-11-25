defmodule MirrorNeuron.Runner.WasmtimeTest do
  use ExUnit.Case, async: false
  alias MirrorNeuron.Runner.Wasmtime
  alias MirrorNeuron.Sandbox.WasmtimePayload

  setup do
    base = Path.join(System.tmp_dir!(), "mn-wit-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base, opts: [job_id: "wasm-test", agent_id: "one", payloads_path: base]}
  end

  test "validates a contained component and rejects links in a staged tree", %{
    base: base,
    opts: opts
  } do
    assert {:error, _} = Wasmtime.run(%{}, %{"wasm_component" => "../worker.wasm"}, opts)
    File.mkdir!(Path.join(base, "files"))
    File.ln_s!(System.tmp_dir!(), Path.join(base, "files/link"))
    assert {:error, _} = WasmtimePayload.stage("files", Path.join(base, "copied"), %{}, opts)
    refute File.exists?(Path.join(base, "copied/link"))
  end

  test "routes Wasmtime workers and rejects native images", %{base: base, opts: opts} do
    config = %{
      "runner_module" => "MirrorNeuron.Runner.Wasmtime",
      "wasm_component" => "worker.wasm"
    }

    assert "wasmtime" == MirrorNeuron.Runner.driver(config)
    File.write!(Path.join(base, "worker.wasm"), <<127, "ELF", 0, 0, 0, 0>>)
    assert {:error, reason} = Wasmtime.run(%{}, config, opts)
    assert reason =~ "component binary" or reason =~ "executable unavailable"
  end

  test "checks configuration bindings before starting a guest" do
    for fields <- [[], %{"review" => []}, %{"review" => ["review", 1]}] do
      assert {:error, _} =
               MirrorNeuron.Sandbox.Wasmtime.validate(%{
                 "wasm_component" => "phase.wasm",
                 "wasm_config_fields" => fields
               })
    end
  end

  if System.find_executable(System.get_env("MN_WASMTIME_BIN") || "wasmtime") &&
       System.find_executable(System.get_env("MN_WASI_RUSTC") || "rustc") &&
       System.get_env("MN_WASI_INTEGRATION") == "1" do
    test "executes a real WASI 0.3 command and propagates errors", %{base: base, opts: opts} do
      source = Path.join(base, "worker.rs")

      File.write!(source, """
      fn main() {
          assert!(std::env::var_os("PATH").is_none());
          assert!(std::fs::read("/etc/passwd").is_err());
          let input = std::fs::read_to_string("/job/mirror_neuron_input.json").unwrap();
          if input.contains("mapped-value") {
              assert_eq!(input, r#"{"step_input":{"selected":"mapped-value"}}"#);
          }
          if input.contains("control") { print!(r#"{{"complete_run":true}}"#); return; }
          if input.contains("overflow") { for _ in 0..200 { println!("__MN_EVENT__{{}}"); } return; }
          if input.contains("failure") { std::process::exit(7); }
          print!(r#"{{"value":42}}"#);
      }
      """)

      rustc = System.get_env("MN_WASI_RUSTC") || "rustc"

      {_, 0} =
        System.cmd(rustc, [
          "--target",
          "wasm32-wasip3",
          source,
          "-o",
          Path.join(base, "worker.wasm")
        ])

      config = %{"wasm_component" => "worker.wasm", "timeout_seconds" => 10}
      assert {:ok, %{"exit_code" => 0, "stdout" => stdout}} = Wasmtime.run(%{}, config, opts)
      assert Jason.decode!(stdout) == %{"value" => 42}

      assert {:ok, %{"exit_code" => 0}} =
               Wasmtime.run(
                 %{
                   "outputs" => %{"selected" => "mapped-value"},
                   "_mn_step" => %{},
                   "secret" => 1
                 },
                 config,
                 opts
               )

      assert {:error, "WASI commands return data" <> _} =
               Wasmtime.run(%{"control" => true}, config, opts)

      assert {:error, "worker output exceeded" <> _} =
               Wasmtime.run(%{"overflow" => true}, Map.put(config, "max_output_bytes", 200), opts)

      assert {:error, %{"exit_code" => 7}} = Wasmtime.run(%{"failure" => true}, config, opts)
    end
  end
end

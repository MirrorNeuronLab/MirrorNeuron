defmodule MirrorNeuron.Grpc.Handlers.SupportTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Bundle.{Archive, Fingerprint}
  alias MirrorNeuron.Grpc.Handlers.Support

  test "failed bundle staging removes the partially written request directory" do
    tmp_root =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_grpc_support_test_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(tmp_root) end)

    assert {:error, _reason} =
             Support.request_bundle_dir("{}", %{"../escape" => "unsafe"}, tmp_root: tmp_root)

    assert {:ok, []} = File.ls(tmp_root)
  end

  test "archived request staging is reclaimed after callback handoff" do
    root =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_grpc_handoff_test_#{System.unique_integer([:positive])}"
      )

    cache_root = Path.join(root, "cache")
    previous_cache_root = System.get_env("MN_BUNDLE_CACHE_DIR")
    System.put_env("MN_BUNDLE_CACHE_DIR", cache_root)

    on_exit(fn ->
      restore_system_env("MN_BUNDLE_CACHE_DIR", previous_cache_root)
      File.rm_rf(root)
    end)

    parent = self()

    manifest_json =
      Jason.encode!(%{
        "apiVersion" => "mn.workflow/v1",
        "kind" => "Workflow",
        "manifest_version" => "1.0",
        "graph_id" => "grpc_handoff",
        "flow" => %{
          "nodes" => [%{"node_id" => "root", "agent_type" => "router", "role" => "root"}],
          "edges" => []
        }
      })

    result =
      Support.with_request_bundle(manifest_json, %{"input.txt" => "payload"}, fn tmp_dir ->
        send(parent, {:request_bundle, tmp_dir})
        {:ok, fingerprint} = Fingerprint.compute(tmp_dir)
        cache_path = Archive.cache_path(fingerprint)
        File.mkdir_p!(Path.dirname(cache_path))
        {:ok, _copied} = File.cp_r(tmp_dir, cache_path)
        :handed_off
      end)

    assert result == :handed_off
    assert_receive {:request_bundle, tmp_dir}
    refute File.exists?(tmp_dir)

    assert [fingerprint] = File.ls!(cache_root)
    assert File.dir?(Archive.cache_path(fingerprint))
  end

  test "stable job atoms use semantic gRPC statuses" do
    assert runtime_error(:not_found).status == GRPC.Status.not_found()
    assert runtime_error(:job_already_exists).status == GRPC.Status.already_exists()
    assert runtime_error(:run_already_exists).status == GRPC.Status.already_exists()
    assert runtime_error(:confirmation_required).status == GRPC.Status.failed_precondition()
    assert runtime_error(:job_not_active).status == GRPC.Status.failed_precondition()
    assert runtime_error(:invalid_job_update).status == GRPC.Status.invalid_argument()
  end

  defp runtime_error(reason) do
    assert_raise GRPC.RPCError, fn -> Support.raise_runtime_error!(reason) end
  end

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end

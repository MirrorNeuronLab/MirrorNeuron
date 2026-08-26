defmodule MirrorNeuron.Runtime.JobResponseTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Runtime.JobResponse

  setup do
    previous_target = System.get_env("MN_NATIVE_SDK_GRPC_TARGET")
    previous_client = Application.get_env(:mirror_neuron, :native_sdk_grpc_job_response_client)
    System.put_env("MN_NATIVE_SDK_GRPC_TARGET", "127.0.0.1:55052")
    parent = self()

    Application.put_env(:mirror_neuron, :native_sdk_grpc_job_response_client, fn _target,
                                                                                 request,
                                                                                 _timeout ->
      attrs = Jason.decode!(request.resource_json)
      send(parent, {:job_response_command, attrs})

      {:ok,
       %Mirrorneuron.Cluster.V1.SetResourceResponse{
         resource_json: Jason.encode!(%{"state" => "ready"}),
         version: 1
       }}
    end)

    on_exit(fn ->
      if previous_target,
        do: System.put_env("MN_NATIVE_SDK_GRPC_TARGET", previous_target),
        else: System.delete_env("MN_NATIVE_SDK_GRPC_TARGET")

      if is_nil(previous_client),
        do: Application.delete_env(:mirror_neuron, :native_sdk_grpc_job_response_client),
        else:
          Application.put_env(
            :mirror_neuron,
            :native_sdk_grpc_job_response_client,
            previous_client
          )
    end)

    :ok
  end

  test "one owner-scoped service warms, restarts after a crash, and stops when disabled" do
    job_id = "job-response-#{System.unique_integer([:positive])}"

    definition = %{
      "job_id" => job_id,
      "blueprint_id" => "example",
      "job_name" => "Example",
      "owner_node" => to_string(MirrorNeuron.Cluster.NodeAdapter.self()),
      "status" => "active",
      "revision" => 1,
      "data_dir" => "/tmp/#{job_id}",
      "resolved_configuration" => %{},
      "manifest" => %{"response_service" => %{"enabled" => true}}
    }

    assert :ok = JobResponse.ensure_started(definition)
    assert :ok = JobResponse.ensure_started(definition)
    assert_receive {:job_response_command, %{"operation" => "start", "job_id" => ^job_id}}
    assert %{state: "ready"} = await_state(job_id, "ready")

    [{pid, _}] = Registry.lookup(MirrorNeuron.Runtime.JobResponseRegistry, job_id)
    Process.exit(pid, :kill)
    assert_receive {:job_response_command, %{"operation" => "start", "job_id" => ^job_id}}, 2_000
    assert %{state: "ready"} = await_state(job_id, "ready")

    assert :ok =
             JobResponse.ensure_started(%{
               definition
               | "revision" => 2,
                 "manifest" => %{}
             })

    assert_receive {:job_response_command, %{"operation" => "stop", "job_id" => ^job_id}}, 2_000
    assert Registry.lookup(MirrorNeuron.Runtime.JobResponseRegistry, job_id) == []
  end

  test "a degraded warm-up retries and recovers without a definition change" do
    job_id = "job-response-recovery-#{System.unique_integer([:positive])}"
    parent = self()
    {:ok, responses} = Agent.start_link(fn -> ["degraded", "ready"] end)

    Application.put_env(
      :mirror_neuron,
      :native_sdk_grpc_job_response_client,
      fn _target, request, _timeout ->
        attrs = Jason.decode!(request.resource_json)
        send(parent, {:job_response_recovery_command, attrs})

        state =
          Agent.get_and_update(responses, fn
            [next | remaining] -> {next, remaining}
            [] -> {"ready", []}
          end)

        {:ok,
         %Mirrorneuron.Cluster.V1.SetResourceResponse{
           resource_json: Jason.encode!(%{"state" => state}),
           version: 1
         }}
      end
    )

    definition = %{
      "job_id" => job_id,
      "blueprint_id" => "example",
      "job_name" => "Example",
      "owner_node" => to_string(MirrorNeuron.Cluster.NodeAdapter.self()),
      "status" => "active",
      "revision" => 1,
      "data_dir" => "/tmp/#{job_id}",
      "resolved_configuration" => %{},
      "manifest" => %{"response_service" => %{"enabled" => true}}
    }

    assert :ok = JobResponse.ensure_started(definition)

    assert_receive {:job_response_recovery_command,
                    %{"operation" => "start", "job_id" => ^job_id}}

    assert %{state: "degraded"} = await_state(job_id, "degraded")

    assert_receive {:job_response_recovery_command,
                    %{"operation" => "start", "job_id" => ^job_id}},
                   2_000

    assert %{state: "ready"} = await_state(job_id, "ready")
  end

  defp await_state(job_id, expected, attempts \\ 50)

  defp await_state(job_id, _expected, 0), do: JobResponse.status_local(job_id)

  defp await_state(job_id, expected, attempts) do
    state = JobResponse.status_local(job_id)

    if state["state"] == expected do
      %{state: state["state"]}
    else
      Process.sleep(10)
      await_state(job_id, expected, attempts - 1)
    end
  end
end

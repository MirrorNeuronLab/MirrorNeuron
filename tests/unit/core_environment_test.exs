defmodule MirrorNeuron.Runner.CoreEnvironmentTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Runner.CoreEnvironment

  test "an execution owner replaces the complete submitted Core connection" do
    saved = %{
      "MN_GRPC_TARGET" => "127.0.0.1:1",
      "MN_RUNTIME_MODEL_CONTROL_TARGET" => "submitter:55051",
      "MN_GRPC_AUTH_TOKEN" => "submitter-credential",
      "MN_AUTH_TOKEN" => "legacy-credential",
      "MN_GRPC_ADMIN_TOKEN" => "admin-credential",
      "MN_RUNTIME_CONTROL_TOKEN" => "surface-credential",
      "MN_JOB_ID" => "job-1"
    }

    bound =
      CoreEnvironment.docker_worker(
        saved,
        %{
          "MN_GRPC_ADVERTISE_PORT" => "55351",
          "MN_GRPC_PORT" => "50051",
          "MN_RUNTIME_MODEL_CONTROL_TARGET" => ""
        },
        "owner-credential"
      )

    assert bound["MN_GRPC_TARGET"] == "host.docker.internal:55351"
    assert bound["MN_RUNTIME_MODEL_CONTROL_TARGET"] == bound["MN_GRPC_TARGET"]
    assert bound["MN_GRPC_AUTH_TOKEN"] == "owner-credential"
    assert bound["MN_JOB_ID"] == "job-1"

    refute Enum.any?(
             ~w(MN_AUTH_TOKEN MN_GRPC_ADMIN_TOKEN MN_RUNTIME_CONTROL_TOKEN),
             &Map.has_key?(bound, &1)
           )
  end

  test "owner control override and credential rotation apply to every invocation" do
    runtime = %{"MN_RUNTIME_MODEL_CONTROL_TARGET" => "worker-core:55351"}
    first = CoreEnvironment.docker_worker(%{}, runtime, "first")
    second = CoreEnvironment.docker_worker(first, runtime, "rotated")
    assert second["MN_GRPC_TARGET"] == "worker-core:55351"
    assert second["MN_GRPC_AUTH_TOKEN"] == "rotated"
    # A development node without auth must never keep another node's credential.
    assert CoreEnvironment.docker_worker(second, runtime, nil)["MN_GRPC_AUTH_TOKEN"] == ""
  end
end

defmodule MirrorNeuron.Runner.HostLocal.PathsTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Runner.HostLocal.{Paths, PythonEnvironment}

  test "upload paths cannot escape or share only a string prefix with the declared root" do
    for path <- ["../outside", "/payloads-neighbor/data"] do
      assert {:error, _} = Paths.resolve_upload_source(path, "/payloads")
    end

    assert {:ok, "/payloads/nested/file"} =
             Paths.resolve_upload_source("nested/file", "/payloads")

    assert {:error, _} = Paths.resolve_upload_target("/workspace", "../other")
    assert {:ok, "/workspace/nested"} = Paths.resolve_upload_target("/workspace", "nested")
  end

  test "malformed Python declarations fail before environment or dependency lookup" do
    for declaration <- [[], "environment"] do
      assert {:error, "python_environment must be an object"} =
               PythonEnvironment.ensure_python_environment(
                 %{"python_environment" => declaration},
                 []
               )
    end

    assert {:error, _} =
             PythonEnvironment.ensure_python_environment(
               %{"python_environment" => %{"requirements" => "../requirements.txt"}},
               []
             )

    assert {:error, _} =
             PythonEnvironment.ensure_python_environment(
               %{"python_environment" => %{"packages" => [""]}},
               []
             )
  end
end

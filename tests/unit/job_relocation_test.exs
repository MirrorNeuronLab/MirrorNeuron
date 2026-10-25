defmodule MirrorNeuron.Runtime.JobRelocationTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Runtime.JobRelocation

  test "transfer attestation covers user data and evidence independently of prepared executable paths" do
    files = %{
      "job-data/input.txt" => %{"sha256" => "abc", "size" => 3, "directory" => false},
      "history/history.json" => %{"sha256" => "def", "size" => 10, "directory" => false},
      "bundle/manifest.json" => %{"sha256" => "old", "size" => 100, "directory" => false}
    }

    digest = JobRelocation.data_digest(files)
    assert byte_size(digest) == 64

    assert digest ==
             JobRelocation.data_digest(
               put_in(files, ["bundle/manifest.json", "sha256"], "prepared")
             )

    refute digest ==
             JobRelocation.data_digest(
               put_in(files, ["job-data/input.txt", "sha256"], "tampered")
             )

    refute digest == JobRelocation.data_digest(Map.delete(files, "history/history.json"))
  end
end

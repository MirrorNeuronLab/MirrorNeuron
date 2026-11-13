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

  test "decodes the federation client's response struct and rejects malformed receipts" do
    assert {:ok, %{"status" => "relocation_staged"}} =
             JobRelocation.decode_peer_receipt(%Mirrorneuron.Job.V1.JsonResponse{
               result_json: ~s({"status":"relocation_staged"})
             })

    assert {:error, :invalid_relocation_state} =
             JobRelocation.decode_peer_receipt(%Mirrorneuron.Job.V1.JsonResponse{
               result_json: "[]"
             })
  end

  test "only a completed former placement or a superseded inactive import can be replaced" do
    journal = %{"source_node" => "mini", "transfer_id" => "new"}

    previous = %{
      "status" => "relocated",
      "owner_node" => "mini",
      "relocation" => %{"target_node" => "mini", "phase" => "completed"}
    }

    assert JobRelocation.replaceable_destination?(previous, journal)
    refute JobRelocation.replaceable_destination?(Map.put(previous, "status", "active"), journal)

    refute JobRelocation.replaceable_destination?(
             Map.put(previous, "owner_node", "unrelated"),
             journal
           )

    refute JobRelocation.replaceable_destination?(
             put_in(previous, ["relocation", "phase"], "cleanup_pending"),
             journal
           )

    inactive = %{
      "status" => "relocation_staged",
      "relocation" => %{"source_node" => "mini", "transfer_id" => "aborted"}
    }

    assert JobRelocation.replaceable_destination?(inactive, journal)

    refute JobRelocation.replaceable_destination?(
             put_in(inactive, ["relocation", "source_node"], "unrelated"),
             journal
           )
  end
end

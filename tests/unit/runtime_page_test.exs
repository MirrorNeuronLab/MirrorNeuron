defmodule MirrorNeuron.Runtime.PageTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Runtime.Page

  test "continuation is stable when records are inserted between pages" do
    initial = [record("b"), record("c"), record("d")]

    assert {:ok, [first, second], token} =
             Page.paginate(initial, [page_size: 2], "jobs", %{}, & &1["id"])

    assert [first["id"], second["id"]] == ["b", "c"]
    assert is_binary(token)

    with_inserts = [record("a"), record("b"), record("c"), record("d"), record("e")]

    assert {:ok, [last], nil} =
             Page.paginate(
               with_inserts,
               [page_size: 2, page_token: token],
               "jobs",
               %{},
               & &1["id"]
             )

    assert last["id"] == "d"
  end

  test "tokens are bound to collection and filters" do
    assert {:ok, [_first], token} =
             Page.paginate(
               [record("a"), record("b")],
               [page_size: 1],
               "jobs",
               %{"archived" => false},
               & &1["id"]
             )

    assert {:error, :invalid_page_token} =
             Page.paginate(
               [record("a"), record("b")],
               [page_size: 1, page_token: token],
               "jobs",
               %{"archived" => true},
               & &1["id"]
             )

    assert {:error, :invalid_page_token} =
             Page.paginate(
               [record("a"), record("b")],
               [page_size: 1, page_token: token],
               "runs",
               %{"archived" => false},
               & &1["id"]
             )
  end

  test "composite tuple keys are encoded as cursor parts" do
    jobs = [
      %{"created_at" => "2026-08-12T18:18:20.109Z", "job_id" => "job-b"},
      %{"created_at" => "2026-08-12T18:18:20.109Z", "job_id" => "job-a"},
      %{"created_at" => "2026-08-13T18:18:20.109Z", "job_id" => "job-c"}
    ]

    key_fun = &{&1["created_at"], &1["job_id"]}

    assert {:ok, [first, second], token} =
             Page.paginate(jobs, [page_size: 2], "jobs", %{}, key_fun)

    assert [first["job_id"], second["job_id"]] == ["job-a", "job-b"]
    assert is_binary(token)

    assert {:ok, [last], nil} =
             Page.paginate(jobs, [page_size: 2, page_token: token], "jobs", %{}, key_fun)

    assert last["job_id"] == "job-c"
  end

  defp record(id), do: %{"id" => id}
end

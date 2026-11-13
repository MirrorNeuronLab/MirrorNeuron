defmodule MirrorNeuron.Runtime.SubmissionPreparationTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Runtime.SubmissionPreparation

  test "growing inputs get a fresh inactivity allowance beyond total elapsed time" do
    original = %{started_at_ms: 0}
    storage = SubmissionPreparation.progress(original, %{"observed_bytes" => 10}, 1_799_000)
    refute SubmissionPreparation.expired?(storage, 1_800_001, 1800)
    storage = SubmissionPreparation.progress(storage, %{"observed_bytes" => 20}, 3_500_000)
    refute SubmissionPreparation.expired?(storage, 5_299_999, 1800)
    assert SubmissionPreparation.expired?(storage, 5_300_000, 1800)
  end

  test "repeated polling and fluctuating unverified files cannot hide a stalled copy" do
    storage =
      SubmissionPreparation.progress(%{started_at_ms: 0}, %{"observed_bytes" => 10}, 1_000)

    for bytes <- [10, 0, 9, 10] do
      assert SubmissionPreparation.progress(storage, %{"observed_bytes" => bytes}, 1_799_000) ==
               storage
    end

    assert SubmissionPreparation.expired?(storage, 1_801_000, 1800)
  end

  test "verified file progress is independent of raw byte count" do
    storage =
      SubmissionPreparation.progress(
        %{started_at_ms: 0},
        %{"total_files" => 4, "remaining_files" => 3},
        1_000
      )

    storage =
      SubmissionPreparation.progress(
        storage,
        %{"total_files" => 4, "remaining_files" => 2},
        1_799_000
      )

    assert storage.verified_files == 2
    refute SubmissionPreparation.expired?(storage, 1_800_000, 1800)
    assert SubmissionPreparation.expired?(%{started_at_ms: 0}, 0, 0)
  end

  test "verification tasks are retired when their coordinator stops" do
    task =
      Task.async(fn ->
        receive do
          :finish -> :ready
        end
      end)

    state = %{submission_storage: %{started_at_ms: 0, check_task: task}}
    assert SubmissionPreparation.stop(state) == state
    refute Process.alive?(task.pid)
    result = SubmissionPreparation.received(state, {:ready, %{}})
    refute Map.has_key?(result.submission_storage, :check_task)
    assert result.submission_storage.check_result == {:ready, %{}}
  end
end

defmodule MirrorNeuron.Runtime.JobResponse.OwnershipTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Runtime.JobResponse

  test "a result from an older definition cannot mark its replacement ready" do
    token = make_ref()
    state = %{revision: 2, state: "starting", warm_task: {self(), make_ref(), token}}

    assert {:noreply, next} =
             JobResponse.handle_info(
               {:warm_result, token, 1, {:ok, %{"state" => "ready"}}, 0},
               state
             )

    assert next.state == "starting"
    assert next.revision == 2
    assert next.warm_task == nil
    assert_received :warm
  end

  test "late task results and monitors cannot clear the current preparation" do
    state = %{revision: 2, state: "starting", warm_task: {self(), make_ref(), make_ref()}}

    assert {:noreply, ^state} =
             JobResponse.handle_info(
               {:warm_result, make_ref(), 2, {:ok, %{"state" => "ready"}}, 0},
               state
             )

    assert {:noreply, ^state} =
             JobResponse.handle_info({:DOWN, make_ref(), :process, self(), :normal}, state)
  end

  test "duplicate warm notifications cannot start concurrent preparation tasks" do
    state = %{warm_task: {self(), make_ref(), make_ref()}}
    assert {:noreply, ^state} = JobResponse.handle_info(:warm, state)
  end

  test "an unchanged definition cannot replace live preparation state" do
    state = %{revision: 2, warm_task: {self(), make_ref(), make_ref()}}
    assert {:noreply, ^state} = JobResponse.handle_cast({:definition, %{"revision" => 2}}, state)
    refute_received :warm
  end
end

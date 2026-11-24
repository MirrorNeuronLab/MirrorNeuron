defmodule MirrorNeuron.Runtime.JobMailbox.SuiteAssignment do
  @moduledoc "Start a suite member for a committed assignment on the recipient's owner."

  alias MirrorNeuron.Runtime.RunStartRequest

  # Starting takes the recipient's Job gate. Both mailbox gates have been
  # released by this point. A resend after a timeout reuses the durable start.
  def start_delivered(result, launch \\ &start/2)

  def start_delivered(
        {:suite_assignment, %{"id" => id, "recipient_job_id" => job} = receipt},
        launch
      ) do
    with {:ok, _run} <- launch.(job, id), do: {:ok, receipt}
  end

  def start_delivered(result, _launch), do: result

  defp start(job, id) do
    RunStartRequest.run(
      job,
      "suite-assignment:" <> id,
      {"", id, false, "enqueue_if_busy"},
      fn run_id, identity ->
        MirrorNeuron.start_run_result(job,
          run_id: run_id,
          start_request_identity: identity,
          mailbox_assignment_id: id,
          admission_policy: "enqueue_if_busy"
        )
      end
    )
  end
end

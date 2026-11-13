defmodule MirrorNeuron.Cluster.Reconciler.PersistenceFailureTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Cluster.Reconciler.Evaluations

  defmodule UnavailableStore do
    def persist_recovery_eval(_, _), do: {:error, :unavailable}

    def fetch_job(_) do
      send(self(), :job_loaded_without_durable_evaluation)
      {:error, :not_found}
    end

    def update_recovery_eval(_, _), do: {:error, :unavailable}
  end

  test "failed running-state persistence stops recovery before loading or dispatching a job" do
    eval = %{"eval_id" => "eval", "job_id" => "job", "status" => "pending", "attempt" => 2}
    result = Evaluations.process_recovery_eval(eval, redis_store: UnavailableStore)
    assert result.action == :failed
    assert result.job_id == "job"
    assert result.reason =~ "could not persist running recovery eval"
    refute_received :job_loaded_without_durable_evaluation
  end
end

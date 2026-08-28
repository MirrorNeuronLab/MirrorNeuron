defmodule MirrorNeuron.Grpc.JobProjection do
  @moduledoc false

  alias MirrorNeuron.Runtime.JobResponse

  @summary_fields ~w(
    job_id blueprint_id graph_id job_name type owner_node status data_generation
    latest_run_id created_at updated_at bundle_ref retired_definition_resources
    resource_cleanup_errors
  )
  @detail_fields @summary_fields ++
                   ~w(resolved_configuration schedules schedule_ids storage)
  @bundle_ref_fields ~w(
    bundle_fingerprint bundle_storage bundle_bytes graph_id manifest_version
  )
  @run_fields ~w(
    graph_id job_name status type job_type workflow_id attempt attempt_id
    data_generation job_data_access owner_node submitted_at started_at updated_at
    completed_at cancelled_at result_ref workflow_state_ref manifest_ref
  )

  def summary(definition) when is_map(definition) do
    definition
    |> Map.take(@summary_fields)
    |> put_definition_type(definition)
    |> put_counts(definition)
    |> compact_bundle_ref()
  end

  def detail(definition) when is_map(definition) do
    definition
    |> Map.take(@detail_fields)
    |> put_definition_type(definition)
    |> put_counts(definition)
    |> put_recent_run_ids(definition)
    |> put_response_service(definition)
    |> compact_bundle_ref()
  end

  def summaries(definitions) when is_list(definitions), do: Enum.map(definitions, &summary/1)

  def run(record, run_id \\ nil) when is_map(record) do
    resolved_run_id = run_id || record["run_id"] || record["job_id"]

    stable_job_id = record["stable_job_id"]

    record
    |> Map.take(@run_fields)
    |> Map.put("job_id", stable_job_id)
    |> Map.put("run_id", resolved_run_id)
    |> Map.put_new("attempt_id", "#{resolved_run_id}:#{Map.get(record, "attempt", 1)}")
    |> compact_reference("manifest_ref")
  end

  def runs(records) when is_list(records), do: Enum.map(records, &run/1)

  def schedule(record) when is_map(record) do
    record
    |> Map.drop(["manifest", "dispatches", "active_run_ids"])
    |> Map.put("dispatch_count", list_count(record["dispatches"]))
    |> Map.put("active_run_count", active_run_count(record))
    |> compact_bundle_ref()
  end

  defp put_counts(projected, definition) do
    projected
    |> Map.put("run_count", list_count(definition["run_ids"]))
    |> Map.put("schedule_count", list_count(definition["schedule_ids"]))
  end

  defp put_definition_type(projected, definition) do
    Map.put(projected, "type", definition["type"])
  end

  defp put_recent_run_ids(projected, definition) do
    recent =
      definition
      |> Map.get("run_ids", [])
      |> Enum.take(-5)
      |> Enum.reverse()

    Map.put(projected, "recent_run_ids", recent)
  end

  defp put_response_service(projected, definition) do
    Map.put(projected, "response_service", JobResponse.status(definition))
  end

  defp compact_bundle_ref(%{"bundle_ref" => bundle_ref} = definition)
       when is_map(bundle_ref) do
    Map.put(definition, "bundle_ref", Map.take(bundle_ref, @bundle_ref_fields))
  end

  defp compact_bundle_ref(definition), do: definition

  defp compact_reference(%{} = value, field) do
    case value[field] do
      reference when is_map(reference) ->
        Map.put(value, field, Map.take(reference, @bundle_ref_fields))

      _missing ->
        value
    end
  end

  defp active_run_count(record) do
    case record["active_run_ids"] do
      run_ids when is_list(run_ids) -> length(run_ids)
      _missing -> 0
    end
  end

  defp list_count(value) when is_list(value), do: length(value)
  defp list_count(_value), do: 0
end

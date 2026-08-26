defmodule MirrorNeuron.Runtime.JobResponse do
  @moduledoc false
  use GenServer, restart: :permanent

  require Logger

  alias MirrorNeuron.Cluster.NodeAdapter
  alias MirrorNeuron.ModelServices
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.StableJob
  alias MirrorNeuron.SafeAccess

  @registry MirrorNeuron.Runtime.JobResponseRegistry
  @supervisor MirrorNeuron.Runtime.JobResponseSupervisor
  @query_timeout 50_000
  @rpc_timeout 55_000
  @warm_timeout 1_230_000
  @max_question_chars 8_000
  @max_request_id_chars 128
  @max_context_bytes 256 * 1_024
  @max_answer_bytes 64 * 1_024
  @max_retry_ms 30_000
  @states ~w(disabled starting ready degraded failed stopped)

  def start_link(definition) when is_map(definition) do
    GenServer.start_link(__MODULE__, definition, name: via(definition["job_id"]))
  end

  def child_spec(definition) do
    %{
      id: {__MODULE__, definition["job_id"]},
      start: {__MODULE__, :start_link, [definition]},
      restart: :permanent,
      shutdown: 30_000,
      type: :worker
    }
  end

  def enabled?(definition) when is_map(definition) do
    get_in(definition, ["manifest", "response_service", "enabled"]) === true
  end

  def enabled?(_definition), do: false

  def ensure_started(definition) when is_map(definition) do
    cond do
      not enabled?(definition) or definition["status"] != "active" ->
        stop(definition)

      not local_owner?(definition) ->
        stop(definition)

      not process_ready?(@supervisor) or not process_ready?(@registry) ->
        :ok

      true ->
        case lookup(definition["job_id"]) do
          {:ok, pid} ->
            GenServer.cast(pid, {:definition, definition})
            :ok

          :error ->
            case DynamicSupervisor.start_child(@supervisor, {__MODULE__, definition}) do
              {:ok, _pid} -> :ok
              {:error, {:already_started, _pid}} -> :ok
              {:error, :already_present} -> :ok
              {:error, reason} -> {:error, reason}
            end
        end
    end
  end

  def definition_changed(definition) when is_map(definition), do: ensure_started(definition)

  def stop(definition) when is_map(definition) do
    job_id = definition["job_id"]

    result =
      if enabled?(definition) or match?({:ok, _pid}, lookup(job_id)) do
        ModelServices.job_response_command(
          %{"kind" => "job_response", "operation" => "stop", "job_id" => job_id},
          27_000
        )
      else
        {:ok, %{"state" => "disabled"}}
      end

    case result do
      {:ok, _response} ->
        terminate_local(job_id)

      {:error, reason} ->
        if safe_error_code(reason) == "native_unavailable" do
          terminate_local(job_id)
        else
          {:error, {:response_service_stop_failed, safe_error_code(reason)}}
        end
    end
  end

  def stop(job_id) when is_binary(job_id) do
    case StableJob.get(job_id) do
      {:ok, definition} -> stop(definition)
      {:error, _missing} -> terminate_local(job_id)
    end
  end

  defp terminate_local(job_id) do
    case lookup(job_id) do
      {:ok, pid} ->
        try do
          DynamicSupervisor.terminate_child(@supervisor, pid)
        catch
          :exit, _ -> :ok
        end

      :error ->
        :ok
    end
  end

  def reset(definition) when is_map(definition) do
    :ok = stop(definition["job_id"])
    ensure_started(definition)
  end

  def query(job_id, attrs) when is_binary(job_id) and is_map(attrs) do
    with :ok <- validate_query(attrs),
         {:ok, definition} <- StableJob.get(job_id),
         :ok <- ensure_queryable(definition) do
      if local_owner?(definition) do
        query_local(job_id, attrs)
      else
        query_remote(definition, attrs)
      end
    end
  end

  def query_local(job_id, attrs) when is_binary(job_id) and is_map(attrs) do
    with {:ok, definition} <- StableJob.get(job_id),
         :ok <- ensure_queryable(definition),
         :ok <- normalize_start_result(ensure_started(definition)) do
      case lookup(job_id) do
        {:ok, pid} ->
          perform_query(pid, definition, attrs)

        :error ->
          {:ok, fallback(attrs, definition, "failed", "response_service_unavailable")}
      end
    end
  end

  def get_turn(job_id, turn_id) when is_binary(job_id) and is_binary(turn_id) do
    with :ok <- validate_turn_id(turn_id),
         {:ok, definition} <- StableJob.get(job_id),
         :ok <- ensure_queryable(definition),
         :ok <- ensure_agent_enabled(definition) do
      if local_owner?(definition) do
        get_turn_local(job_id, turn_id)
      else
        get_turn_remote(definition, turn_id)
      end
    end
  end

  def get_turn(_job_id, _turn_id), do: {:error, :invalid_turn_id}

  def get_turn_local(job_id, turn_id) do
    with {:ok, definition} <- StableJob.get(job_id),
         :ok <- ensure_queryable(definition),
         :ok <- ensure_agent_enabled(definition),
         :ok <- normalize_start_result(ensure_started(definition)) do
      ModelServices.job_response_command(
        %{
          "kind" => "job_response",
          "operation" => "turn",
          "job_id" => job_id,
          "turn_id" => turn_id
        },
        10_000
      )
    end
  end

  def status(definition) when is_map(definition) do
    cond do
      not enabled?(definition) ->
        %{"state" => "disabled"}

      definition["status"] != "active" ->
        %{
          "state" => "stopped",
          "stopped_at" => definition["updated_at"] || definition["created_at"]
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      local_owner?(definition) ->
        status_local(definition["job_id"])
        |> maybe_put_started(definition)

      true ->
        remote_status(definition)
        |> maybe_put_started(definition)
    end
  end

  def status_local(job_id) when is_binary(job_id) do
    case lookup(job_id) do
      {:ok, pid} ->
        try do
          GenServer.call(pid, :status, 1_000)
        catch
          :exit, _ -> %{"state" => "starting"}
        end

      :error ->
        %{"state" => "starting"}
    end
  end

  @impl true
  def init(definition) do
    now = Runtime.timestamp()
    send(self(), :warm)

    {:ok,
     %{
       definition: definition,
       revision: definition["revision"],
       state: "starting",
       started_at: now,
       updated_at: now,
       ready_at: nil,
       stopped_at: nil,
       safe_error_code: nil,
       retry_ms: 1_000
     }}
  end

  @impl true
  def handle_info(:warm, state) do
    started = System.monotonic_time(:millisecond)

    case ModelServices.job_response_command(start_payload(state.definition), @warm_timeout) do
      {:ok, result} ->
        service_state = normalize_state(result["state"], "ready")
        now = Runtime.timestamp()
        latency = System.monotonic_time(:millisecond) - started
        log_event(state.definition["job_id"], "warm", service_state, latency)
        retry_ms = maybe_retry_degraded_warm(service_state, state.retry_ms)

        {:noreply,
         %{
           state
           | state: service_state,
             ready_at: if(service_state in ["ready", "degraded"], do: now, else: state.ready_at),
             updated_at: now,
             safe_error_code: nil,
             retry_ms: retry_ms
         }}

      {:error, reason} ->
        code = safe_error_code(reason)
        log_event(state.definition["job_id"], "warm", "failed", nil, code)
        Process.send_after(self(), :warm, state.retry_ms)

        {:noreply,
         %{
           state
           | state: "failed",
             updated_at: Runtime.timestamp(),
             safe_error_code: code,
             retry_ms: min(state.retry_ms * 2, @max_retry_ms)
         }}
    end
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  defp maybe_retry_degraded_warm("degraded", retry_ms) do
    Process.send_after(self(), :warm, retry_ms)
    min(retry_ms * 2, @max_retry_ms)
  end

  defp maybe_retry_degraded_warm(_service_state, _retry_ms), do: 1_000

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public_state(state), state}

  @impl true
  def handle_cast({:query_result, service_state, error_code}, state) do
    {:noreply,
     %{
       state
       | state: service_state,
         updated_at: Runtime.timestamp(),
         safe_error_code: error_code
     }}
  end

  def handle_cast({:definition, definition}, state) do
    if definition["revision"] == state.revision do
      {:noreply, state}
    else
      send(self(), :warm)

      {:noreply,
       %{
         state
         | definition: definition,
           revision: definition["revision"],
           state: "starting",
           updated_at: Runtime.timestamp(),
           safe_error_code: nil
       }}
    end
  end

  defp perform_query(pid, definition, attrs) do
    started = System.monotonic_time(:millisecond)

    result =
      ModelServices.job_response_command(
        %{
          "kind" => "job_response",
          "operation" => "query",
          "job_id" => definition["job_id"],
          "question" => attrs["question"],
          "conversation_id" => attrs["conversation_id"],
          "request_id" => attrs["request_id"],
          "context" => attrs["context"] || %{}
        },
        @query_timeout
      )

    latency = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, answer} ->
        service_state = normalize_state(get_in(answer, ["service", "state"]), "ready")
        log_event(definition["job_id"], "query", service_state, latency)
        GenServer.cast(pid, {:query_result, service_state, nil})
        {:ok, answer}

      {:error, reason} ->
        code = safe_error_code(reason)

        if code == "request_conflict" do
          log_event(definition["job_id"], "failure", "ready", latency, code)
          {:error, :request_conflict}
        else
          log_event(definition["job_id"], "fallback", "degraded", latency, code)
          GenServer.cast(pid, {:query_result, "degraded", code})
          {:ok, fallback(attrs, definition, "degraded", code)}
        end
    end
  end

  @impl true
  def terminate(_reason, state) do
    _ =
      ModelServices.job_response_command(
        %{
          "kind" => "job_response",
          "operation" => "stop",
          "job_id" => state.definition["job_id"]
        },
        27_000
      )

    :ok
  end

  defp start_payload(definition) do
    %{
      "kind" => "job_response",
      "operation" => "start",
      "job_id" => definition["job_id"],
      "blueprint_id" => definition["blueprint_id"],
      "job_data_dir" => definition["data_dir"],
      "manifest" => definition["manifest"] || %{},
      "configuration" => definition["resolved_configuration"] || %{},
      "revision" => definition["revision"]
    }
  end

  defp validate_query(attrs) do
    question = attrs["question"]
    conversation_id = attrs["conversation_id"]
    request_id = attrs["request_id"]

    cond do
      not is_binary(question) or String.trim(question) == "" ->
        {:error, :question_required}

      String.length(question) > @max_question_chars ->
        {:error, :question_too_long}

      conversation_id not in [nil, ""] and not valid_uuid?(conversation_id) ->
        {:error, :invalid_conversation_id}

      not is_nil(request_id) and not is_binary(request_id) ->
        {:error, :invalid_request_id}

      is_binary(request_id) and String.length(request_id) > @max_request_id_chars ->
        {:error, :request_id_too_long}

      not is_map(attrs["context"] || %{}) ->
        {:error, :invalid_job_context}

      encoded_context_size(attrs["context"] || %{}) > @max_context_bytes ->
        {:error, :job_context_too_large}

      true ->
        :ok
    end
  end

  defp ensure_queryable(definition) do
    cond do
      not enabled?(definition) -> {:error, :response_service_disabled}
      definition["status"] != "active" -> {:error, :job_not_active}
      true -> :ok
    end
  end

  defp ensure_agent_enabled(definition) do
    if bounded_agent?(definition),
      do: :ok,
      else: {:error, :response_agent_disabled}
  end

  defp bounded_agent?(definition) do
    get_in(definition, ["manifest", "response_service", "agent", "kind"]) == "bounded_mcp"
  end

  defp validate_turn_id(turn_id) do
    if valid_uuid?(turn_id), do: :ok, else: {:error, :invalid_turn_id}
  end

  defp get_turn_remote(definition, turn_id) do
    with {:ok, owner} <- SafeAccess.node_name_to_atom(definition["owner_node"]) do
      case NodeAdapter.rpc_call(
             owner,
             __MODULE__,
             :get_turn_local,
             [definition["job_id"], turn_id],
             @rpc_timeout
           ) do
        {:badrpc, _reason} -> {:error, :owner_node_unavailable}
        result -> result
      end
    else
      _ -> {:error, :owner_node_unavailable}
    end
  end

  defp query_remote(definition, attrs) do
    with {:ok, owner} <- SafeAccess.node_name_to_atom(definition["owner_node"]) do
      case NodeAdapter.rpc_call(
             owner,
             __MODULE__,
             :query_local,
             [definition["job_id"], attrs],
             @rpc_timeout
           ) do
        {:badrpc, _reason} ->
          {:ok, fallback(attrs, definition, "failed", "owner_node_unavailable")}

        result ->
          result
      end
    else
      _ -> {:ok, fallback(attrs, definition, "failed", "owner_node_unavailable")}
    end
  end

  defp remote_status(definition) do
    with {:ok, owner} <- SafeAccess.node_name_to_atom(definition["owner_node"]),
         result when is_map(result) <-
           NodeAdapter.rpc_call(owner, __MODULE__, :status_local, [definition["job_id"]], 1_000) do
      result
    else
      _ -> %{"state" => "starting"}
    end
  end

  defp fallback(attrs, definition, service_state, warning_code) do
    context = attrs["context"] || %{}
    profile = if is_map(context["profile"]), do: context["profile"], else: %{}
    latest = if is_map(context["latest_run"]), do: context["latest_run"], else: nil

    name =
      safe_string(
        profile["name"] || definition["job_name"] || definition["blueprint_id"] || "This job",
        512,
        "This job"
      )

    job_state = safe_string(context["state"], 100, "unknown")

    parts = ["#{name} is currently #{String.replace(to_string(job_state), "_", " ")}."]

    parts =
      if is_binary(profile["mission"]) and String.trim(profile["mission"]) != "" do
        parts ++ ["Its declared purpose is: #{String.slice(profile["mission"], 0, 1_200)}"]
      else
        parts
      end

    parts =
      if is_map(latest) do
        parts ++
          [
            "The latest run (#{safe_string(latest["run_id"], 200, "latest")}) is #{safe_string(latest["status"], 100, "unknown")}."
          ]
      else
        parts ++
          ["It has not started a run yet, so there is no run progress or result to report."]
      end

    answer =
      Enum.join(
        parts ++
          [
            "This is a grounded status summary; the semantic answer service was unavailable, so no additional conclusion was inferred."
          ],
        "\n\n"
      )

    response = %{
      "schema_version" => "mn.mcp.job_answer.v1",
      "answer" => String.slice(answer, 0, 12_000),
      "conversation_id" => attrs["conversation_id"] || uuid(),
      "request_id" => attrs["request_id"],
      "job_id" => definition["job_id"],
      "state" => %{
        "job" => job_state,
        "latest_run" => fallback_latest_state(latest)
      },
      "citations" => fallback_citations(context["evidence"]),
      "warnings" => [
        "A deterministic answer was returned because the response service was unavailable.",
        warning_code
      ],
      "service" => %{"state" => service_state},
      "model" => %{"used" => false, "fallback" => true},
      "conversation_persisted" => false
    }

    response =
      if bounded_agent?(definition) do
        Map.merge(response, %{
          "schema_version" => "mn.mcp.job_answer.v3",
          "turn" => %{
            "turn_id" => uuid(),
            "state" => "completed",
            "updated_at" => Runtime.timestamp()
          },
          "effects" => []
        })
      else
        response
      end

    fit_fallback(response)
  end

  defp fit_fallback(answer) do
    cond do
      encoded_answer_size(answer) <= @max_answer_bytes ->
        answer

      answer["citations"] != [] ->
        answer
        |> Map.update!("citations", &Enum.drop(&1, -1))
        |> fit_fallback()

      get_in(answer, ["state", "latest_run"]) != nil ->
        answer
        |> put_in(["state", "latest_run"], nil)
        |> fit_fallback()

      String.length(answer["answer"] || "") > 4_000 ->
        answer
        |> Map.update!("answer", &String.slice(&1, 0, 4_000))
        |> fit_fallback()

      length(answer["warnings"] || []) > 1 ->
        answer
        |> Map.put("warnings", ["The deterministic response was truncated to the answer limit."])
        |> fit_fallback()

      true ->
        Map.update!(answer, "answer", &String.slice(&1, 0, 1_000))
    end
  end

  defp encoded_answer_size(answer) do
    answer |> Jason.encode!() |> byte_size()
  rescue
    _ -> @max_answer_bytes + 1
  end

  defp public_state(state) do
    %{
      "state" => normalize_state(state.state, "failed"),
      "started_at" => state.started_at,
      "ready_at" => state.ready_at,
      "updated_at" => state.updated_at,
      "stopped_at" => state.stopped_at,
      "safe_error_code" => state.safe_error_code
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_state(value, _fallback) when value in @states, do: value
  defp normalize_state(_value, fallback), do: fallback

  defp safe_error_code(reason) do
    text = String.downcase(inspect(reason))

    cond do
      String.contains?(text, "unavailable") ->
        "native_unavailable"

      String.contains?(text, "saturat") ->
        "saturated"

      String.contains?(text, "deadline") or String.contains?(text, "timeout") ->
        "deadline_exceeded"

      String.contains?(text, "conflict") ->
        "request_conflict"

      true ->
        "response_failed"
    end
  end

  defp valid_uuid?(value) when is_binary(value) do
    Regex.match?(
      ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$/,
      value
    )
  end

  defp valid_uuid?(_value), do: false

  defp encoded_context_size(value) do
    value |> Jason.encode!() |> byte_size()
  rescue
    _ -> @max_context_bytes + 1
  end

  defp fallback_citations(evidence) when is_list(evidence) do
    evidence
    |> Enum.filter(&is_map/1)
    |> Enum.take(20)
    |> Enum.map(fn item ->
      %{
        "kind" => safe_string(item["kind"], 100, "job_context"),
        "record_id" => safe_string(item["record_id"], 200, "evidence"),
        "summary" => safe_string(item["summary"], 800),
        "status" => safe_string(item["status"], 100)
      }
    end)
  end

  defp fallback_citations(_evidence), do: []

  defp fallback_latest_state(nil), do: nil

  defp fallback_latest_state(latest) when is_map(latest) do
    ~w(run_id status started_at updated_at completed_at finished_at)
    |> Enum.reduce(%{}, fn key, result ->
      case safe_string(latest[key], 256) do
        "" -> result
        value -> Map.put(result, key, value)
      end
    end)
  end

  defp safe_string(value, limit, fallback \\ "")

  defp safe_string(value, limit, _fallback) when is_binary(value),
    do: String.slice(value, 0, limit)

  defp safe_string(value, _limit, _fallback)
       when is_integer(value) or is_float(value) or is_boolean(value),
       do: to_string(value)

  defp safe_string(_value, _limit, fallback), do: fallback

  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = Bitwise.band(c, 0x0FFF) + 0x4000
    d = Bitwise.band(d, 0x3FFF) + 0x8000

    Enum.join(
      [hex(a, 8), hex(b, 4), hex(c, 4), hex(d, 4), hex(e, 12)],
      "-"
    )
  end

  defp hex(value, length), do: value |> Integer.to_string(16) |> String.pad_leading(length, "0")

  defp local_owner?(definition),
    do: to_string(NodeAdapter.self()) == to_string(definition["owner_node"])

  defp via(job_id), do: {:via, Registry, {@registry, job_id}}

  defp lookup(job_id) do
    if process_ready?(@registry) do
      case Registry.lookup(@registry, job_id) do
        [{pid, _value}] -> {:ok, pid}
        _ -> :error
      end
    else
      :error
    end
  end

  defp process_ready?(name), do: not is_nil(Process.whereis(name))

  defp maybe_put_started(value, definition) do
    case definition["updated_at"] || definition["created_at"] do
      timestamp when is_binary(timestamp) and timestamp != "" ->
        Map.put_new(value, "started_at", timestamp)

      _missing ->
        value
    end
  end

  defp normalize_start_result(:ok), do: :ok
  defp normalize_start_result({:error, reason}), do: {:error, reason}

  defp log_event(job_id, operation, state, latency_ms, error_code \\ nil) do
    Logger.info(
      "job response lifecycle",
      job_id: job_id,
      operation: operation,
      state: state,
      latency_ms: latency_ms,
      error_code: error_code
    )
  end
end

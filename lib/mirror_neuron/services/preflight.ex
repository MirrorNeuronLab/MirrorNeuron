defmodule MirrorNeuron.ServicePreflight do
  @moduledoc false

  alias MirrorNeuron.{JobBundle, ServiceCheck, ServiceRegistry, ServiceSpec}

  def run(%JobBundle{manifest: manifest} = bundle, opts \\ []) do
    if MirrorNeuron.BlueprintValidation.force?(manifest) do
      :ok
    else
      config = Keyword.get(opts, :config) || config_from_bundle(bundle) || %{}
      env = Keyword.get(opts, :env) || manifest_environment(manifest)

      manifest
      |> ServiceSpec.required_services()
      |> check_services(
        Keyword.merge(opts,
          config: config,
          env: env,
          bundle_root: bundle.root_path,
          job_id: Map.get(manifest, :graph_id)
        )
      )
      |> case do
        {:ok, %{"ok" => true}} ->
          :ok

        {:ok, report} ->
          {:error, "service_requirements_not_met: " <> Jason.encode!(report)}
      end
    end
  end

  def check_services(services, opts \\ []) do
    services = List.wrap(services)

    results =
      services
      |> Enum.with_index()
      |> Enum.map(fn {service, index} -> check_required_service(service, index, opts) end)

    issues =
      results
      |> Enum.flat_map(fn
        %{"ok" => false, "required" => true, "issue" => issue} -> [issue]
        _ -> []
      end)

    {:ok, validation_report(issues, results)}
  end

  defp check_required_service(service, index, opts) when is_map(service) do
    context = %{
      "job_id" => Keyword.get(opts, :job_id),
      "node" => Keyword.get(opts, :node) || to_string(Node.self()),
      "config" => Keyword.get(opts, :config, %{}),
      "env" => Keyword.get(opts, :env, %{}),
      "bundle_root" => Keyword.get(opts, :bundle_root)
    }

    service = ServiceSpec.resolve_service(service, context)
    label = Map.get(service, "name") || "service_#{index}"
    required = ServiceSpec.required?(service)

    cond do
      direct_check_service?(service) ->
        service = maybe_put_implicit_tcp_check(service)
        health = ServiceCheck.check_service(service, bundle_root: Keyword.get(opts, :bundle_root))
        ok = Map.get(health, "status") in ["passing", "warning"] or not required

        %{
          "name" => label,
          "type" => "service",
          "required" => required,
          "ok" => ok,
          "status" => Map.get(health, "status"),
          "health" => health
        }
        |> maybe_put_issue(
          not ok,
          issue("service.health_failed", "#{label} is not healthy",
            source: "services",
            path: label,
            expected: "passing service health",
            actual: health
          )
        )

      true ->
        check_registry_requirement(service, label, required)
    end
  end

  defp check_required_service(_service, index, _opts) do
    label = "required_services.#{index}"

    validation_issue =
      issue("service.requirement_type", "#{label} must be an object",
        source: "services",
        path: label
      )

    %{
      "name" => label,
      "type" => "service",
      "required" => true,
      "ok" => false,
      "status" => "invalid",
      "issue" => validation_issue
    }
  end

  defp direct_check_service?(service) do
    Map.get(service, "checks", []) != [] or
      is_binary(Map.get(service, "address")) or
      not is_nil(Map.get(service, "port")) or
      Enum.any?(Map.get(service, "checks", []), &Map.get(&1, "url"))
  end

  defp maybe_put_implicit_tcp_check(%{"checks" => []} = service) do
    cond do
      Map.get(service, "url") ->
        Map.put(service, "checks", [
          %{
            "name" => Map.get(service, "name", "http"),
            "type" => "http",
            "url" => Map.get(service, "url"),
            "required" => Map.get(service, "required", true)
          }
        ])

      Map.get(service, "address") || Map.get(service, "port") ->
        Map.put(service, "checks", [
          %{
            "name" => Map.get(service, "name", "tcp"),
            "type" => "tcp",
            "address" => Map.get(service, "address"),
            "port" => Map.get(service, "port"),
            "required" => Map.get(service, "required", true)
          }
        ])

      true ->
        service
    end
  end

  defp maybe_put_implicit_tcp_check(service), do: service

  defp check_registry_requirement(service, label, required) do
    tags = Map.get(service, "tags", [])

    case ServiceRegistry.resolve(label, tags: tags) do
      {:ok, instances} when instances != [] ->
        %{
          "name" => label,
          "type" => "service",
          "required" => required,
          "ok" => true,
          "status" => "passing",
          "instances" => redact_instances(instances)
        }

      {:ok, []} ->
        ok = not required

        result = %{
          "name" => label,
          "type" => "service",
          "required" => required,
          "ok" => ok,
          "status" => if(ok, do: "optional_missing", else: "missing"),
          "instances" => []
        }

        maybe_put_issue(
          result,
          not ok,
          issue("service.required_missing", "#{label} has no passing registered instances",
            source: "services",
            path: label,
            expected: "passing registered service",
            actual: %{"name" => label, "tags" => tags}
          )
        )

      {:error, reason} ->
        ok = not required

        result = %{
          "name" => label,
          "type" => "service",
          "required" => required,
          "ok" => ok,
          "status" => if(ok, do: "registry_unavailable", else: "failed"),
          "error" => to_string(reason)
        }

        maybe_put_issue(
          result,
          not ok,
          issue("service.registry_unavailable", "#{label} could not be resolved: #{reason}",
            source: "services",
            path: label,
            expected: "registry lookup succeeds",
            actual: reason
          )
        )
    end
  end

  defp validation_report(issues, results) do
    normalized = Enum.map(issues, &normalize_issue/1)

    %{
      "version" => "validation.report/v1",
      "ok" => normalized == [],
      "status" => if(normalized == [], do: "passed", else: "failed"),
      "error_count" => length(normalized),
      "errors" => Enum.map(normalized, &issue_message/1),
      "issues" => normalized,
      "results" => Enum.map(results, &Map.drop(&1, ["issue"]))
    }
  end

  defp issue(code, message, opts) do
    source = opts[:source] || "services"
    path = opts[:path] || ""

    base = %{
      "code" => code,
      "message" => message,
      "help" => opts[:help] || "",
      "severity" => opts[:severity] || "error",
      "location" => %{
        "source" => source,
        "path" => path,
        "pointer" => json_pointer(source, path)
      }
    }

    base
    |> maybe_put(
      "expected",
      ServiceCheck.redact_value(opts[:expected]),
      Keyword.has_key?(opts, :expected)
    )
    |> maybe_put(
      "actual",
      ServiceCheck.redact_value(opts[:actual]),
      Keyword.has_key?(opts, :actual)
    )
  end

  defp normalize_issue(%{} = issue), do: issue

  defp normalize_issue(other),
    do: issue("service.validation_failed", to_string(other), source: "services")

  defp issue_message(issue) do
    location = Map.get(issue, "location", %{})
    path = Map.get(location, "path")
    message = Map.get(issue, "message") || Map.get(issue, "code") || "Service validation failed"

    if is_binary(path) and path != "" and not String.contains?(message, path),
      do: "#{path}: #{message}",
      else: message
  end

  defp maybe_put(map, _key, _value, false), do: map
  defp maybe_put(map, key, value, _condition), do: Map.put(map, key, value)

  defp maybe_put_issue(map, false, _issue), do: map
  defp maybe_put_issue(map, true, issue), do: Map.put(map, "issue", issue)

  defp redact_instances(instances) do
    Enum.map(instances, fn instance ->
      instance
      |> Map.take([
        "id",
        "name",
        "address",
        "port",
        "node",
        "job_id",
        "agent_id",
        "tags",
        "status",
        "health"
      ])
      |> ServiceCheck.redact_value()
    end)
  end

  defp config_from_bundle(%JobBundle{root_path: root_path}) when is_binary(root_path) do
    [
      Path.join([root_path, "config", "default.json"]),
      Path.join([root_path, "config", "overwrite.json"])
    ]
    |> Enum.reduce(%{}, fn path, acc ->
      case File.read(path) do
        {:ok, raw} ->
          case Jason.decode(raw) do
            {:ok, decoded} when is_map(decoded) -> deep_merge(acc, decoded)
            _ -> acc
          end

        _ ->
          acc
      end
    end)
  end

  defp config_from_bundle(_bundle), do: %{}

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, old, new -> deep_merge(old, new) end)
  end

  defp deep_merge(_left, right), do: right

  defp manifest_environment(manifest) do
    manifest
    |> Map.get(:nodes, [])
    |> Enum.find_value(%{}, fn node ->
      node
      |> Map.get(:config, %{})
      |> map_get("environment")
      |> case do
        env when is_map(env) -> stringify_map(env)
        _ -> nil
      end
    end)
  end

  defp map_get(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp map_get(_map, _key), do: nil

  defp stringify_map(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      {key, stringify_value(value)}
    end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp json_pointer(source, path) do
    parts =
      [source | String.split(to_string(path || ""), [".", "[", "]"], trim: true)]
      |> Enum.reject(&(to_string(&1) == ""))
      |> Enum.map(&escape_pointer/1)

    "/" <> Enum.join(parts, "/")
  end

  defp escape_pointer(value) do
    value
    |> to_string()
    |> String.replace("~", "~0")
    |> String.replace("/", "~1")
  end
end

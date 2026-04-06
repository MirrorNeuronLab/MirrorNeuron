defmodule MirrorNeuron.Builtins.Module do
  use MirrorNeuron.AgentTemplate

  @impl true
  def init(node) do
    with {:ok, delegate} <- resolve_delegate(node.config),
         {:ok, delegate_state} <- delegate.init(node) do
      {:ok, %{delegate: delegate, delegate_state: delegate_state, config: node.config}}
    end
  end

  @impl true
  def handle_message(message, state, context) do
    case state.delegate.handle_message(message, state.delegate_state, context) do
      {:ok, next_delegate_state, actions} ->
        {:ok, %{state | delegate_state: next_delegate_state}, actions}

      {:error, reason, next_delegate_state} ->
        {:error, reason, %{state | delegate_state: next_delegate_state}}
    end
  end

  @impl true
  def recover(state, context) do
    case state.delegate.recover(state.delegate_state, context) do
      {:ok, next_delegate_state, actions} ->
        {:ok, %{state | delegate_state: next_delegate_state}, actions}

      {:error, reason, next_delegate_state} ->
        {:error, reason, %{state | delegate_state: next_delegate_state}}
    end
  end

  @impl true
  def snapshot_state(%{delegate: delegate, delegate_state: delegate_state} = state) do
    %{
      "delegate" => Atom.to_string(delegate),
      "delegate_state" => delegate.snapshot_state(delegate_state),
      "config" => state.config
    }
  end

  @impl true
  def restore_state(%{
        "delegate" => delegate_name,
        "delegate_state" => snapshot,
        "config" => config
      }) do
    with {:ok, delegate} <- resolve_delegate(%{"module" => delegate_name}),
         {:ok, delegate_state} <- delegate.restore_state(snapshot) do
      {:ok, %{delegate: delegate, delegate_state: delegate_state, config: config}}
    end
  end

  def restore_state(snapshot), do: {:error, {:invalid_module_snapshot, snapshot}}

  @impl true
  def inspect_state(%{delegate: delegate, delegate_state: delegate_state, config: config}) do
    %{
      "delegate" => Atom.to_string(delegate),
      "delegate_state" => delegate.inspect_state(delegate_state),
      "config" => config
    }
  end

  defp resolve_delegate(config) do
    case Map.get(config, "module") || Map.get(config, :module) do
      nil ->
        {:error, "module agent requires config.module"}

      module when is_atom(module) ->
        ensure_module_loaded(module, config)

      module_name when is_binary(module_name) ->
        try do
          module =
            module_name
            |> String.split(".", trim: true)
            |> Enum.map(&String.to_atom/1)
            |> Module.concat()

          ensure_module_loaded(module, config)
        rescue
          _ -> {:error, "invalid module agent #{inspect(module_name)}"}
        end

      other ->
        {:error, "invalid module agent #{inspect(other)}"}
    end
  end

  defp ensure_module_loaded(module, config) do
    if Code.ensure_loaded?(module) do
      {:ok, module}
    else
      with :ok <- maybe_compile_module_sources(config),
           true <- Code.ensure_loaded?(module) do
        {:ok, module}
      else
        false ->
          {:error, "module agent #{inspect(module)} is not available"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp maybe_compile_module_sources(config) do
    case Map.get(config, "module_source") || Map.get(config, :module_source) do
      nil ->
        :ok

      source ->
        payloads_path = Map.get(config, "__payloads_path") || Map.get(config, :__payloads_path)

        if is_nil(payloads_path) do
          {:error, "module_source requires payloads path in runtime context"}
        else
          source_path = Path.expand(source, payloads_path)
          source_dir = Path.dirname(source_path)

          if File.exists?(source_path) do
            source_dir
            |> Path.join("*.ex")
            |> Path.wildcard()
            |> Enum.sort()
            |> Enum.each(&Code.compile_file/1)

            :ok
          else
            {:error, "module source does not exist: #{source_path}"}
          end
        end
    end
  end
end

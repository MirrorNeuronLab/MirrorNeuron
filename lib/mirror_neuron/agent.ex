defmodule MirrorNeuron.Agent do
  @moduledoc """
  Agent behavior used by Core workers.

  `recover/2`, `snapshot_state/1`, and `restore_state/1` are retained for source
  compatibility for one release. Core no longer calls them; runtime loss starts
  a clean job attempt from the manifest and its declared inputs.

  `{:checkpoint, ...}` actions are also deprecated and ignored by Core. They
  remain in the action type only for source compatibility until the next major
  release.
  """
  @type action ::
          {:emit, String.t(), map()}
          | {:emit, String.t(), term(), keyword()}
          | {:emit_to, String.t(), String.t(), map()}
          | {:emit_to, String.t(), String.t(), term(), keyword()}
          | {:emit_message, map()}
          | {:event, atom(), map()}
          | {:checkpoint, map()}
          | {:complete_step, map()}
          | {:complete_run, map()}

  @callback init(node :: map()) :: {:ok, map()} | {:error, term()}
  @callback handle_message(message :: map(), state :: map(), context :: map()) ::
              {:ok, map(), [action()]} | {:error, term(), map()}
  @doc "Deprecated compatibility callback; Core does not invoke it."
  @callback recover(state :: map(), context :: map()) ::
              {:ok, map(), [action()]} | {:error, term(), map()}
  @doc "Deprecated compatibility callback; Core does not invoke it."
  @callback snapshot_state(state :: map()) :: term()
  @doc "Deprecated compatibility callback; Core does not invoke it."
  @callback restore_state(snapshot :: term()) :: {:ok, map()} | {:error, term()}
  @callback inspect_state(state :: map()) :: term()

  @optional_callbacks recover: 2, snapshot_state: 1, restore_state: 1, inspect_state: 1

  def payload(message), do: MirrorNeuron.Message.body(message)
  def type(message), do: MirrorNeuron.Message.type(message)
  def from(message), do: MirrorNeuron.Message.from(message)
  def to(message), do: MirrorNeuron.Message.to(message)
  def headers(message), do: MirrorNeuron.Message.headers(message)
  def artifacts(message), do: MirrorNeuron.Message.artifacts(message)
  def stream(message), do: MirrorNeuron.Message.stream(message)
  def envelope(message), do: MirrorNeuron.Message.envelope(message)
end

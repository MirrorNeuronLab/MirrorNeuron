defmodule MirrorNeuron.Cluster.RuntimeIdentity do
  @moduledoc "Identity validation for installer-managed Core processes."

  def health(expected \\ System.get_env("MN_NODE_NAME"), actual \\ Node.self()) do
    expected = to_string(expected || "")
    actual = to_string(actual)

    %{
      "expected" => expected,
      "actual" => actual,
      "valid" => valid_name?(expected) and valid_name?(actual) and expected == actual
    }
  end

  def valid_name?(name) when is_binary(name),
    do:
      name != "nonode@nohost" and
        Regex.match?(~r/\A[A-Za-z0-9_][A-Za-z0-9_.-]*@[A-Za-z0-9][A-Za-z0-9_.-]*\z/, name)

  def valid_name?(_), do: false

  # Unmanaged mix/test processes retain their explicit development contract.
  def validate! do
    if System.get_env("MN_NODE_NAME") != nil and not health()["valid"] do
      raise "MN_NODE_IDENTITY_INVALID: Core must run with its configured node identity. Run mn runtime start; restore the original configuration if identities conflict."
    end

    :ok
  end
end

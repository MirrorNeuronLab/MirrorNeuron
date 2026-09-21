defmodule MirrorNeuron.Cluster.RuntimeIdentityTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Cluster.RuntimeIdentity

  test "requires a named VM with exactly the configured identity" do
    assert RuntimeIdentity.health("mirror_neuron_test@127.0.0.1", :"mirror_neuron_test@127.0.0.1")[
             "valid"
           ]

    for name <- [nil, "", "nonode@nohost", "missinghost", "bad name@host", "a@b@c"] do
      refute RuntimeIdentity.health(name, :nonode@nohost)["valid"]
      refute RuntimeIdentity.valid_name?(name)
    end

    refute RuntimeIdentity.health("a@host", :b@host)["valid"]
    assert RuntimeIdentity.health("a@10.0.4.27", :"a@10.0.4.27")["valid"]
  end
end

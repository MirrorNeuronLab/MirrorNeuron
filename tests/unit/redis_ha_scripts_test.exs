defmodule MirrorNeuron.RedisHAScriptsTest do
  use ExUnit.Case, async: true

  @scripts [
    "scripts/redis_ha.sh",
    "scripts/test_redis_sentinel_ha.sh",
    "scripts/test_redis_sentinel_two_box_ha.sh",
    "scripts/start_cluster_node.sh",
    "scripts/cluster_cli.sh"
  ]

  test "redis and cluster shell helpers pass bash syntax checks" do
    for script <- @scripts do
      assert {_, 0} = System.cmd("bash", ["-n", script], stderr_to_stdout: true)
    end
  end

  test "redis HA helpers expose help successfully" do
    for script <- ["scripts/redis_ha.sh", "scripts/test_redis_sentinel_two_box_ha.sh"] do
      assert {output, 0} = System.cmd("bash", [script, "--help"], stderr_to_stdout: true)
      assert output =~ "usage:"
    end
  end

  test "two-box smoke helper fails clearly without required remote host" do
    assert {output, status} =
             System.cmd("bash", ["scripts/test_redis_sentinel_two_box_ha.sh"],
               stderr_to_stdout: true
             )

    assert status != 0
    assert output =~ "--remote-host is required"
  end
end

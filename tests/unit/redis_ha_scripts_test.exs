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

  test "redis HA join refuses to start without a Redis password" do
    tmp_dir = tmp_path()
    redis_server = fake_redis_server(tmp_dir)
    redis_cli = fake_redis_cli(tmp_dir)

    assert {output, status} =
             System.cmd("bash", ["scripts/redis_ha.sh", "join", "--data-dir", tmp_dir],
               env: [
                 {"MN_REDIS_SERVER_BIN", redis_server},
                 {"MN_REDIS_CLI_BIN", redis_cli},
                 {"MN_REDIS_PASSWORD", ""},
                 {"MN_REDIS_SENTINEL_PASSWORD", ""}
               ],
               stderr_to_stdout: true
             )

    assert status != 0
    assert output =~ "MN_REDIS_PASSWORD is required"
    refute File.exists?(Path.join(tmp_dir, "redis-server.log"))
  end

  test "redis HA join configures Redis and Sentinel authentication" do
    tmp_dir = tmp_path()
    redis_server = fake_redis_server(tmp_dir)
    redis_cli = fake_redis_cli(tmp_dir)

    assert {_output, 0} =
             System.cmd("bash", ["scripts/redis_ha.sh", "join", "--data-dir", tmp_dir],
               env: [
                 {"MN_REDIS_SERVER_BIN", redis_server},
                 {"MN_REDIS_CLI_BIN", redis_cli},
                 {"MN_REDIS_PASSWORD", "shared-secret"}
               ],
               stderr_to_stdout: true
             )

    redis_server_log = File.read!(Path.join(tmp_dir, "redis-server.log"))
    sentinel_conf = File.read!(Path.join([tmp_dir, "sentinel", "sentinel.conf"]))
    redis_cli_log = File.read!(Path.join(tmp_dir, "redis-cli.log"))

    assert redis_server_log =~ "--requirepass shared-secret --masterauth shared-secret"
    assert sentinel_conf =~ ~s(requirepass "shared-secret")
    assert sentinel_conf =~ ~s(sentinel sentinel-pass "shared-secret")
    assert redis_cli_log =~ "SENTINEL SET mirror-neuron auth-pass shared-secret"
  end

  defp tmp_path do
    path = Path.join(
      System.tmp_dir!(),
      "mirror_neuron_redis_ha_test_#{System.unique_integer([:positive])}"
    )

    File.rm_rf!(path)
    path
  end

  defp fake_redis_server(tmp_dir) do
    File.mkdir_p!(tmp_dir)

    path = Path.join(tmp_dir, "fake_redis_server.sh")

    File.write!(path, """
    #!/usr/bin/env bash
    printf '%s\n' "$*" >> #{Path.join(tmp_dir, "redis-server.log")}
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp fake_redis_cli(tmp_dir) do
    File.mkdir_p!(tmp_dir)

    path = Path.join(tmp_dir, "fake_redis_cli.sh")

    File.write!(path, """
    #!/usr/bin/env bash
    args=("$@")
    command=()
    i=0
    while [ "$i" -lt "${#args[@]}" ]; do
      arg="${args[$i]}"
      case "$arg" in
        -h|-p|-a|--user)
          i=$((i + 2))
          ;;
        --no-auth-warning)
          i=$((i + 1))
          ;;
        *)
          command=("${args[@]:$i}")
          break
          ;;
      esac
    done

    printf '%s\n' "${command[*]}" >> #{Path.join(tmp_dir, "redis-cli.log")}

    case "${command[*]}" in
      "PING")
        exit 1
        ;;
      "INFO replication")
        printf 'role:master\n'
        ;;
      "SENTINEL get-master-addr-by-name mirror-neuron")
        ;;
    esac

    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end
end

defmodule MirrorNeuron.Runner.OpenShellTest.OwnershipTest do
  use MirrorNeuron.OpenShellCase, async: false

  alias MirrorNeuron.Sandbox.OpenShellJobSandbox

  test "does not clean SDK-owned OpenShell containers when gateway deletion fails" do
    Application.ensure_all_started(:mirror_neuron)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_openshell_docker_cleanup_test_#{System.unique_integer([:positive])}"
      )

    sandboxes_dir = Path.join(tmp_dir, "sandboxes")
    containers_dir = Path.join(tmp_dir, "containers")
    removed_log = Path.join(tmp_dir, "removed.log")
    fake_cli = Path.join(tmp_dir, "fake_openshell.sh")
    fake_docker = Path.join(tmp_dir, "fake_docker.sh")
    job_id = "job-docker-cleanup-#{System.unique_integer([:positive])}"

    File.mkdir_p!(sandboxes_dir)
    File.mkdir_p!(containers_dir)

    File.write!(
      fake_cli,
      """
      #!/usr/bin/env bash
      set -euo pipefail

      sandbox_root() {
        local name="$1"
        printf "%s/%s" "$FAKE_SANDBOXES_DIR" "$name"
      }

      subcommand="$2"
      case "$subcommand" in
        get)
          name="$3"
          test -d "$(sandbox_root "$name")"
          ;;
        create)
          name=""
          args=("$@")
          i=2
          while [ "$i" -lt "$#" ]; do
            current="${args[$i]}"
            if [ "$current" = "--name" ]; then
              i=$((i + 1))
              name="${args[$i]}"
            elif [ "$current" = "--" ]; then
              break
            fi
            i=$((i + 1))
          done
          mkdir -p "$(sandbox_root "$name")"
          ;;
        delete)
          echo "gateway unavailable" >&2
          exit 1
          ;;
        *)
          echo "unsupported fake openshell subcommand: $subcommand" >&2
          exit 2
          ;;
      esac
      """
    )

    File.write!(
      fake_docker,
      """
      #!/usr/bin/env bash
      set -euo pipefail

      command="$1"
      shift
      case "$command" in
        ps)
          for container in "$FAKE_DOCKER_CONTAINERS"/*; do
            [ -e "$container" ] || continue
            name="$(basename "$container")"
            printf "id-%s\\t%s\\n" "$name" "$name"
          done
          ;;
        rm)
          if [ "${1:-}" = "-f" ]; then
            shift
          fi
          for id in "$@"; do
            name="${id#id-}"
            printf "%s\\n" "$name" >> "$FAKE_DOCKER_REMOVED_LOG"
            rm -f "$FAKE_DOCKER_CONTAINERS/$name"
          done
          ;;
        *)
          echo "unsupported fake docker command: $command" >&2
          exit 2
          ;;
      esac
      """
    )

    File.chmod!(fake_cli, 0o755)
    File.chmod!(fake_docker, 0o755)

    config = %{
      "sandbox_cli" => fake_cli,
      "no_auto_providers" => true,
      "tty" => false,
      "sandbox_name" => "prepared-docker-cleanup",
      "reuse_shared_sandbox" => true
    }

    env_backup = %{
      "FAKE_SANDBOXES_DIR" => System.get_env("FAKE_SANDBOXES_DIR"),
      "FAKE_DOCKER_CONTAINERS" => System.get_env("FAKE_DOCKER_CONTAINERS"),
      "FAKE_DOCKER_REMOVED_LOG" => System.get_env("FAKE_DOCKER_REMOVED_LOG"),
      "MN_DOCKER_BIN" => System.get_env("MN_DOCKER_BIN")
    }

    try do
      System.put_env("FAKE_SANDBOXES_DIR", sandboxes_dir)
      System.put_env("FAKE_DOCKER_CONTAINERS", containers_dir)
      System.put_env("FAKE_DOCKER_REMOVED_LOG", removed_log)
      System.put_env("MN_DOCKER_BIN", fake_docker)

      assert {:ok, sandbox} = OpenShellJobSandbox.ensure(job_id, config)
      container_name = "openshell-#{sandbox["sandbox_name"]}-port-mapping"
      File.touch!(Path.join(containers_dir, container_name))

      assert :ok = OpenShellJobSandbox.cleanup_job_local(job_id)
      assert File.exists?(Path.join(containers_dir, container_name))
      refute File.exists?(removed_log)

      changed_node_container_name =
        "openshell-mirror-neuron-job-#{String.downcase(job_id)}-old-node-port-mapping"

      File.touch!(Path.join(containers_dir, changed_node_container_name))
      assert :ok = OpenShellJobSandbox.cleanup_job_local(job_id, config)
      assert File.exists?(Path.join(containers_dir, changed_node_container_name))
    after
      OpenShellJobSandbox.cleanup_job_local(job_id)

      Enum.each(env_backup, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(tmp_dir)
    end
  end

  test "does not retain local ownership of SDK-prepared OpenShell sandboxes" do
    Application.ensure_all_started(:mirror_neuron)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_openshell_cleanup_retry_#{System.unique_integer([:positive])}"
      )

    sandboxes_dir = Path.join(tmp_dir, "sandboxes")
    allow_delete = Path.join(tmp_dir, "allow-delete")
    fake_cli = Path.join(tmp_dir, "fake-openshell")
    fake_docker = Path.join(tmp_dir, "fake-docker")
    job_id = "job-openshell-cleanup-retry"
    previous_docker = System.get_env("MN_DOCKER_BIN")

    File.mkdir_p!(sandboxes_dir)

    File.write!(fake_cli, """
    #!/usr/bin/env bash
    set -euo pipefail
    command="$2"
    name="$3"
    case "$command" in
      get)
        test -d "#{sandboxes_dir}/$name"
        ;;
      create)
        name=""
        args=("$@")
        i=2
        while [ "$i" -lt "$#" ]; do
          if [ "${args[$i]}" = "--name" ]; then
            i=$((i + 1))
            name="${args[$i]}"
            break
          fi
          i=$((i + 1))
        done
        mkdir -p "#{sandboxes_dir}/$name"
        ;;
      delete)
        if [ -f "#{allow_delete}" ]; then
          rm -rf "#{sandboxes_dir}/$name"
          exit 0
        fi
        echo "sandbox is busy" >&2
        exit 9
        ;;
    esac
    """)

    File.write!(fake_docker, """
    #!/usr/bin/env bash
    if [ "$1" = "ps" ]; then
      exit 0
    fi
    exit 0
    """)

    File.chmod!(fake_cli, 0o755)
    File.chmod!(fake_docker, 0o755)
    System.put_env("MN_DOCKER_BIN", fake_docker)

    config = %{
      "sandbox_cli" => fake_cli,
      "shared_sandbox_prefix" => "custom-cleanup-prefix",
      "no_auto_providers" => true,
      "tty" => false,
      "sandbox_name" => "prepared-cleanup-retry"
    }

    try do
      assert {:ok, %{"sandbox_name" => "prepared-cleanup-retry"}} =
               OpenShellJobSandbox.ensure(job_id, config)

      assert :ok = OpenShellJobSandbox.cleanup_job_local(job_id)
      assert Registry.lookup(MirrorNeuron.Sandbox.Registry, job_id) == []
    after
      File.touch!(allow_delete)
      OpenShellJobSandbox.cleanup_job_local(job_id, config)

      if is_nil(previous_docker),
        do: System.delete_env("MN_DOCKER_BIN"),
        else: System.put_env("MN_DOCKER_BIN", previous_docker)

      File.rm_rf!(tmp_dir)
    end
  end
end

defmodule MirrorNeuron.ConfigTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Config
  alias MirrorNeuron.Config.Schema

  @dotenv_keys [
    "MN_ENV",
    "MN_REDIS_NAMESPACE",
    "MN_REDIS_HOST",
    "MN_REDIS_URL",
    "MN_GRPC_PORT",
    "MN_API_PORT",
    "MN_NETWORK_ONLY",
    "MN_NETWORK_JOIN_TOKEN",
    "MN_GRPC_AUTH_TOKEN",
    "MN_COOKIE"
  ]

  setup do
    previous_env = Map.new(@dotenv_keys, &{&1, System.get_env(&1)})
    previous_app = Map.new([:api_port], &{&1, Application.get_env(:mirror_neuron, &1)})

    on_exit(fn ->
      Enum.each(previous_env, fn {key, value} -> restore_env(key, value) end)
      Enum.each(previous_app, fn {key, value} -> restore_app_env(key, value) end)
    end)

    Enum.each(@dotenv_keys, &System.delete_env/1)

    :ok
  end

  test "loads .env defaults when real environment variables are unset" do
    root = tmp_dir()
    File.write!(Path.join(root, ".env"), "MN_REDIS_NAMESPACE=dotenv_default\n")

    assert %{env: "dev"} = Config.load_env_files!(root)
    assert System.get_env("MN_REDIS_NAMESPACE") == "dotenv_default"
  end

  test ".env environment file overrides .env defaults" do
    root = tmp_dir()
    File.write!(Path.join(root, ".env"), "MN_REDIS_NAMESPACE=base\n")
    File.write!(Path.join(root, ".env.dev"), "MN_REDIS_NAMESPACE=dev\n")

    Config.load_env_files!(root)

    assert System.get_env("MN_REDIS_NAMESPACE") == "dev"
  end

  test "real environment variables override .env files" do
    root = tmp_dir()
    File.write!(Path.join(root, ".env"), "MN_GRPC_PORT=8000\n")
    File.write!(Path.join(root, ".env.dev"), "MN_GRPC_PORT=9000\n")
    System.put_env("MN_GRPC_PORT", "8080")

    Config.load_env_files!(root)

    assert Config.integer("MN_GRPC_PORT", :grpc_port) == 8_080
  end

  test "MN_ENV defaults to dev and loads .env.dev when unset" do
    root = tmp_dir()
    File.write!(Path.join(root, ".env.dev"), "MN_REDIS_NAMESPACE=dev_default\n")

    assert %{env: "dev"} = Config.load_env_files!(root)
    assert System.get_env("MN_ENV") == "dev"
    assert System.get_env("MN_REDIS_NAMESPACE") == "dev_default"
  end

  test "MN_ENV development loads .env.dev" do
    root = tmp_dir()
    File.write!(Path.join(root, ".env.dev"), "MN_REDIS_NAMESPACE=development_alias\n")
    System.put_env("MN_ENV", "development")

    assert %{env: "dev"} = Config.load_env_files!(root)
    assert System.get_env("MN_REDIS_NAMESPACE") == "development_alias"
  end

  test "MN_ENV test loads .env.test" do
    root = tmp_dir()
    File.write!(Path.join(root, ".env.test"), "MN_REDIS_NAMESPACE=test_namespace\n")
    System.put_env("MN_ENV", "test")

    assert %{env: "test"} = Config.load_env_files!(root)
    assert System.get_env("MN_REDIS_NAMESPACE") == "test_namespace"
  end

  test "MN_ENV production loads .env.prod if present" do
    root = tmp_dir()
    File.write!(Path.join(root, ".env.prod"), "MN_REDIS_NAMESPACE=prod_namespace\n")
    System.put_env("MN_ENV", "production")

    assert %{env: "prod"} = Config.load_env_files!(root)
    assert System.get_env("MN_REDIS_NAMESPACE") == "prod_namespace"
  end

  test "production can build config without any .env files" do
    root = tmp_dir()
    System.put_env("MN_ENV", "production")
    System.put_env("MN_GRPC_AUTH_TOKEN", "auth-token")

    assert %{env: "prod", loaded_files: []} = Config.load_env_files!(root)
    app_env = Config.app_env!()

    assert Keyword.fetch!(app_env, :redis_url) == "redis://localhost:6379/0"
    assert Keyword.fetch!(app_env, :grpc_auth_token) == "auth-token"
  end

  test "missing required startup config raises a clear error" do
    System.put_env("MN_NETWORK_ONLY", "true")

    assert_raise ArgumentError,
                 "MN_NETWORK_JOIN_TOKEN is required when MN_NETWORK_ONLY=true",
                 fn ->
                   Config.validate!()
                 end
  end

  test "invalid type parsing raises a clear error" do
    System.put_env("MN_GRPC_PORT", "not-a-port")

    assert_raise ArgumentError, ~r/MN_GRPC_PORT must be an integer/, fn ->
      Config.validate!()
    end
  end

  test "secret values do not appear in validation errors" do
    secret = "super-secret-auth-token"
    System.put_env("MN_ENV", "prod")
    System.put_env("MN_GRPC_AUTH_TOKEN", secret)
    System.put_env("MN_COOKIE", "mirrorneuron")

    error =
      assert_raise ArgumentError, fn ->
        Config.validate!()
      end

    refute Exception.message(error) =~ secret
  end

  test "schema includes CLI and API facing keys" do
    System.put_env("MN_API_PORT", "8081")
    Application.put_env(:mirror_neuron, :api_port, 8_000)

    assert Schema.spec_by_env("MN_API_PORT").key == :api_port
    assert Config.integer("MN_API_PORT", :api_port) == 8_081
  end

  test "executable resolves commands installed in common user bin directories" do
    previous_home = System.get_env("HOME")
    previous_path = System.get_env("PATH")
    previous_value = Application.get_env(:mirror_neuron, :test_tool_bin)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_config_test_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    bin_dir = Path.join([tmp_dir, ".local", "bin"])
    tool_path = Path.join(bin_dir, "test-tool")

    try do
      File.mkdir_p!(bin_dir)
      File.write!(tool_path, "#!/usr/bin/env sh\nexit 0\n")
      File.chmod!(tool_path, 0o755)

      System.put_env("HOME", tmp_dir)
      System.put_env("PATH", "/usr/bin:/bin")
      System.delete_env("MN_TEST_TOOL_BIN")
      Application.put_env(:mirror_neuron, :test_tool_bin, "test-tool")

      assert Config.executable("MN_TEST_TOOL_BIN", :test_tool_bin) == tool_path
    after
      restore_env("HOME", previous_home)
      restore_env("PATH", previous_path)

      if previous_value == nil do
        Application.delete_env(:mirror_neuron, :test_tool_bin)
      else
        Application.put_env(:mirror_neuron, :test_tool_bin, previous_value)
      end
    end
  end

  test "validate rejects invalid runtime control timing settings" do
    previous_job_call_timeout = System.get_env("MN_JOB_CALL_TIMEOUT_MS")
    previous_cancel_job_call_timeout = System.get_env("MN_CANCEL_JOB_CALL_TIMEOUT_MS")
    previous_ack_timeout = System.get_env("MN_MESSAGE_ACK_TIMEOUT_MS")
    previous_lease_renew = System.get_env("MN_MESSAGE_LEASE_RENEW_MS")

    try do
      System.put_env("MN_JOB_CALL_TIMEOUT_MS", "0")

      assert_raise ArgumentError, ~r/MN_JOB_CALL_TIMEOUT_MS/, fn ->
        Config.validate!()
      end

      System.delete_env("MN_JOB_CALL_TIMEOUT_MS")
      System.put_env("MN_CANCEL_JOB_CALL_TIMEOUT_MS", "0")

      assert_raise ArgumentError, ~r/MN_CANCEL_JOB_CALL_TIMEOUT_MS/, fn ->
        Config.validate!()
      end

      System.delete_env("MN_CANCEL_JOB_CALL_TIMEOUT_MS")
      System.put_env("MN_MESSAGE_ACK_TIMEOUT_MS", "0")

      assert_raise ArgumentError, ~r/MN_MESSAGE_ACK_TIMEOUT_MS/, fn ->
        Config.validate!()
      end

      System.put_env("MN_MESSAGE_ACK_TIMEOUT_MS", "1000")
      System.put_env("MN_MESSAGE_LEASE_RENEW_MS", "1000")

      assert_raise ArgumentError, ~r/MN_MESSAGE_LEASE_RENEW_MS/, fn ->
        Config.validate!()
      end
    after
      restore_env("MN_JOB_CALL_TIMEOUT_MS", previous_job_call_timeout)
      restore_env("MN_CANCEL_JOB_CALL_TIMEOUT_MS", previous_cancel_job_call_timeout)
      restore_env("MN_MESSAGE_ACK_TIMEOUT_MS", previous_ack_timeout)
      restore_env("MN_MESSAGE_LEASE_RENEW_MS", previous_lease_renew)
    end
  end

  defp tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_config_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp restore_app_env(name, nil), do: Application.delete_env(:mirror_neuron, name)
  defp restore_app_env(name, value), do: Application.put_env(:mirror_neuron, name, value)
end

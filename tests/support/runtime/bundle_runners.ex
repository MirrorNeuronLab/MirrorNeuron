defmodule MirrorNeuron.RuntimeTest.BundlePathEchoRunner do
  def run(_payload, _config, opts) do
    bundle_root = Keyword.get(opts, :bundle_root)
    manifest_path = Keyword.get(opts, :manifest_path)
    payloads_path = Keyword.get(opts, :payloads_path)

    {:ok,
     %{
       "sandbox_name" => "bundle-path-echo",
       "exit_code" => 0,
       "stdout" =>
         Jason.encode!(%{
           "complete_run" => %{
             "bundle_root" => bundle_root,
             "manifest_path" => manifest_path,
             "payloads_path" => payloads_path,
             "bundle_exists" => File.dir?(bundle_root || ""),
             "manifest_exists" => File.exists?(manifest_path || ""),
             "payloads_exists" => File.dir?(payloads_path || "")
           }
         }),
       "stderr" => "",
       "logs" => ""
     }}
  end
end

defmodule MirrorNeuron.RuntimeTest.AllocationEchoRunner do
  def run(_payload, config, _opts) do
    environment = Map.get(config, "environment", %{})

    {:ok,
     %{
       "sandbox_name" => "allocation-echo",
       "exit_code" => 0,
       "stdout" =>
         Jason.encode!(%{
           "complete_run" => %{
             "allocation" => Map.get(config, "__mirror_neuron_allocation"),
             "env" => environment
           }
         }),
       "stderr" => "",
       "logs" => ""
     }}
  end
end

defmodule MirrorNeuron.RuntimeTest.ProfiledCompleteRunner do
  def run(_payload, config, _opts) do
    {:ok,
     %{
       "sandbox_name" => "profiled-complete",
       "exit_code" => 0,
       "stdout" =>
         Jason.encode!(%{
           "complete_run" => %{
             "profile" => Map.get(config, "execution_profile"),
             "image" => Map.get(config, "from")
           }
         }),
       "stderr" => "",
       "logs" => ""
     }}
  end
end

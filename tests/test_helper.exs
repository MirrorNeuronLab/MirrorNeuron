temp_dir = Application.fetch_env!(:mirror_neuron, :temp_dir)
System.put_env("MN_TEMP_DIR", temp_dir)
File.mkdir_p!(temp_dir)

# Core's production runtime always has a node-local native SDK sidecar. Keep
# component tests deterministic while still exercising the ownership calls
# added to cancellation and runner cleanup: individual boundary tests replace
# this client when they need to assert a failure or exact wire payload.
System.put_env(
  "MN_NATIVE_SDK_GRPC_TARGET",
  System.get_env("MN_NATIVE_SDK_GRPC_TARGET") || "127.0.0.1:55052"
)

Application.put_env(
  :mirror_neuron,
  :native_sdk_grpc_native_resource_client,
  fn _target, request, _timeout ->
    attrs = Jason.decode!(request.resource_json)

    result =
      case attrs["operation"] do
        "register" ->
          external_id = attrs["external_id"] || "resource"
          %{"resource_id" => "test-native-resource:#{external_id}", "errors" => []}

        _operation ->
          %{"removed_count" => 0, "errors" => []}
      end

    {:ok,
     %Mirrorneuron.Cluster.V1.SetResourceResponse{
       resource_json: Jason.encode!(result),
       version: 1
     }}
  end
)

ExUnit.start()

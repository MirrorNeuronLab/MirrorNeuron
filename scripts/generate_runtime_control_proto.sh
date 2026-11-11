#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
sdk_dir="$(cd "${1:-../mn-python-sdk}" && pwd)"
mix deps.compile protobuf
plugin="$(mktemp)"
trap 'rm -f "$plugin"' EXIT
cat >"$plugin" <<EOF
#!/usr/bin/env bash
elixir -e 'Code.append_paths(Path.wildcard("$PWD/_build/dev/lib/*/ebin")); Application.load(:protobuf); Protobuf.Protoc.CLI.main([])'
EOF
chmod +x "$plugin"
protoc -I proto --plugin="protoc-gen-elixir=$plugin" --elixir_out=plugins=grpc:lib/mirror_neuron_grpc proto/runtime_control.proto
mix format lib/mirror_neuron_grpc/runtime_control.pb.ex
cp proto/runtime_control.proto "$sdk_dir/mn_sdk/proto/runtime_control.proto"
if [ -n "${PROTO_PYTHON:-}" ]; then
  "$PROTO_PYTHON" -m grpc_tools.protoc \
    -I "$sdk_dir" --python_out="$sdk_dir" --grpc_python_out="$sdk_dir" "$sdk_dir/mn_sdk/proto/runtime_control.proto"
else
  uv run --no-project --with grpcio-tools==1.82.1 python -m grpc_tools.protoc \
    -I "$sdk_dir" --python_out="$sdk_dir" --grpc_python_out="$sdk_dir" "$sdk_dir/mn_sdk/proto/runtime_control.proto"
fi

#!/usr/bin/env bash
# Regenerate the public Job and observability bindings in Core and its sibling Python SDK.
set -euo pipefail
cd "$(dirname "$0")/.."
sdk_dir="${1:-../mn-python-sdk}"
mix deps.compile protobuf
plugin="$(mktemp)"
trap 'rm -f "$plugin"' EXIT
cat > "$plugin" <<EOF
#!/usr/bin/env bash
elixir -e 'Code.append_paths(Path.wildcard("$PWD/_build/dev/lib/*/ebin")); Application.load(:protobuf); Protobuf.Protoc.CLI.main([])'
EOF
chmod +x "$plugin"
protoc -I proto --plugin="protoc-gen-elixir=$plugin" --elixir_out=plugins=grpc:lib/mirror_neuron_grpc proto/job.proto proto/observability.proto
mix format lib/mirror_neuron_grpc/job.pb.ex lib/mirror_neuron_grpc/observability.pb.ex
cp proto/job.proto proto/observability.proto "$sdk_dir/mn_sdk/proto/"
uv run --no-project --with grpcio-tools==1.82.1 python -m grpc_tools.protoc \
  -I proto --python_out="$sdk_dir/mn_sdk/proto" --grpc_python_out="$sdk_dir/mn_sdk/proto" proto/job.proto proto/observability.proto
python3 - "$sdk_dir/mn_sdk/proto/job_pb2_grpc.py" "$sdk_dir/mn_sdk/proto/observability_pb2_grpc.py" <<'PY'
import pathlib, sys
for filename in sys.argv[1:]:
    path = pathlib.Path(filename)
    name = path.name.removesuffix("_grpc.py")
    path.write_text(path.read_text().replace(f"import {name} as", f"from . import {name} as"))
PY

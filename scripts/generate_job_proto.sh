#!/usr/bin/env bash
# Regenerate the public Job bindings in Core and its sibling Python SDK.
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
protoc -I proto --plugin="protoc-gen-elixir=$plugin" --elixir_out=plugins=grpc:lib/mirror_neuron_grpc proto/job.proto
cp proto/job.proto "$sdk_dir/mn_sdk/proto/job.proto"
uv run --no-project --with grpcio-tools==1.82.1 python -m grpc_tools.protoc \
  -I proto --python_out="$sdk_dir/mn_sdk/proto" --grpc_python_out="$sdk_dir/mn_sdk/proto" proto/job.proto
python3 - "$sdk_dir/mn_sdk/proto/job_pb2_grpc.py" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text(path.read_text().replace('import job_pb2 as job__pb2', 'from . import job_pb2 as job__pb2'))
PY

# HostLocal uses the same Python 3.12 as the native SDK, API, and CLI. Both
# stages use Bookworm and pinned multi-architecture digests.
ARG PYTHON_IMAGE=python:3.12.14-slim-bookworm@sha256:392307d22300de8b5986851a12d9176dfc0fc073e65bf6523ebd7dcbeb23564e
ARG ELIXIR_IMAGE=hexpm/elixir:1.18.4-erlang-28.3-debian-bookworm-20260610-slim@sha256:00153b7780e105e742099378fca72d35c21825890d721a838b8a0a1432bdcb1a
FROM rust:1.100.0-slim-bookworm AS wasmtime-host
WORKDIR /build
COPY native/wasmtime-runner ./
RUN cargo build --locked --release

FROM ${PYTHON_IMAGE} AS python-runtime
FROM ${ELIXIR_IMAGE}

COPY --from=python-runtime /usr/local/ /usr/local/
COPY --from=wasmtime-host /build/target/release/mn-wasmtime-runner /usr/local/bin/
ENV PATH="/usr/local/bin:${PATH}"

ARG CORE_RELEASE_TAG=""
ARG CORE_REVISION=""
ARG ERL_AFLAGS=""

LABEL org.opencontainers.image.title="MirrorNeuron Core" \
      org.opencontainers.image.version="${CORE_RELEASE_TAG}" \
      org.opencontainers.image.revision="${CORE_REVISION}"

# Install system dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates \
    git \
    make \
    g++ \
    libssl-dev \
    protobuf-compiler \
    curl \
    libbz2-1.0 \
    libdb5.3 \
    libexpat1 \
    libffi8 \
    libgdbm6 \
    libgdbm-compat4 \
    liblzma5 \
    xz-utils \
    libncursesw6 \
    libreadline8 \
    libsqlite3-0 \
    libuuid1 \
    zlib1g \
    && rm -rf /var/lib/apt/lists/*

RUN ldconfig \
    && test -x /usr/local/bin/python3.12 \
    && python3.12 -c 'import sys; assert sys.version_info[:2] == (3, 12), sys.version' \
    && test "$(readlink -f "$(command -v python3)")" = "/usr/local/bin/python3.12" \
    && python3 -c 'import bz2, ctypes, dbm.gnu, lzma, readline, sqlite3, ssl, zlib' \
    && python3 --version \
    && python3 -m pip --version

# LiteLLM 1.95 still imports FastAPI's get_flat_dependant helper, which was
# removed in FastAPI 0.140. Keep the proxy on the newest compatible FastAPI
# line until LiteLLM removes that import.
RUN python3 -m pip install --no-cache-dir --break-system-packages \
    "litellm[proxy]==1.100.1" \
    "fastapi>=0.136.3,<0.140" \
    "grpcio>=1.82.1" \
    "protobuf>=7.35.1"
RUN python3 -c "import grpc; from google.protobuf import runtime_version; runtime_version.ValidateProtobufRuntimeVersion(runtime_version.Domain.PUBLIC, 7, 35, 1, '', 'context.proto')"

# Correct provider usage normalization in the installed library at build time.
# This preserves reported counts through federated gateway streams; the source
# hash and real streaming tests prevent an unreviewed upstream change.
COPY scripts/install_litellm_usage_fix.py /tmp/install_litellm_usage_fix.py
COPY tests/gateway/test_streaming_usage.py /tmp/test_streaming_usage.py
RUN python3 /tmp/install_litellm_usage_fix.py \
    && LITELLM_LOCAL_MODEL_COST_MAP=True python3 /tmp/test_streaming_usage.py \
    && rm /tmp/install_litellm_usage_fix.py /tmp/test_streaming_usage.py

# WASI 0.3 execution on the Core node.
ARG WASMTIME_VERSION=51.0.0
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
      amd64) arch=x86_64; digest=a18020674fac4107f329bc9ed720ea9c88e4b30a61e8a527787bcce051123d32 ;; \
      arm64) arch=aarch64; digest=a263f34aefad1b24ba4d9ca635ddfea415f4acfe3f3f1bb6d4525c34fc6a7397 ;; \
      *) exit 1 ;; \
    esac; \
    archive="wasmtime-v${WASMTIME_VERSION}-${arch}-linux"; \
    curl --fail --silent --show-error --location --retry 3 \
      "https://github.com/bytecodealliance/wasmtime/releases/download/v${WASMTIME_VERSION}/${archive}.tar.xz" -o /tmp/wasmtime.tar.xz; \
    echo "${digest}  /tmp/wasmtime.tar.xz" | sha256sum -c -; \
    tar -xJf /tmp/wasmtime.tar.xz -C /usr/local/bin --strip-components=1 "${archive}/wasmtime"; \
    rm /tmp/wasmtime.tar.xz; \
    wasmtime --version

ARG DOCKER_CLI_VERSION=29.2.1
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      arm64) docker_target="aarch64" ;; \
      amd64) docker_target="x86_64" ;; \
      *) echo "unsupported architecture for Docker CLI: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fLsS -o /tmp/docker-cli.tgz \
      "https://download.docker.com/linux/static/stable/${docker_target}/docker-${DOCKER_CLI_VERSION}.tgz"; \
    tar -xzf /tmp/docker-cli.tgz -C /tmp docker/docker; \
    install -m 0755 /tmp/docker/docker /usr/local/bin/docker; \
    rm -rf /tmp/docker /tmp/docker-cli.tgz; \
    docker --version

ARG OPENSHELL_VERSION=v0.0.47
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      arm64) openshell_target="aarch64-unknown-linux-musl"; openshell_sha="a6aa05593aa5bd6936bbb87fa3958510c1a6d82ef11b8ed8498e884de50847c0" ;; \
      amd64) openshell_target="x86_64-unknown-linux-musl"; openshell_sha="75ea23c19c23a931ac34b274f719c60dd20c6f788f2a4551862ec17572d84c17" ;; \
      *) echo "unsupported architecture for OpenShell: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fLsS -o /tmp/openshell.tar.gz \
      "https://github.com/NVIDIA/OpenShell/releases/download/${OPENSHELL_VERSION}/openshell-${openshell_target}.tar.gz"; \
    echo "${openshell_sha}  /tmp/openshell.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/openshell.tar.gz -C /usr/local/bin openshell; \
    chmod 0755 /usr/local/bin/openshell; \
    rm -f /tmp/openshell.tar.gz; \
    openshell --version

# Install hex and rebar
RUN mix local.rebar --force && mix local.hex --force

WORKDIR /app

# Copy dependency files and fetch deps
COPY mix.exs mix.lock ./
RUN test -s mix.exs && grep -q "use Mix.Project" mix.exs || \
    (echo "Invalid mix.exs copied into Docker build context" >&2; exit 1)
RUN mix deps.get
RUN mix deps.compile

# Copy the rest of the application
COPY . .

# Compile the application
RUN mix compile

EXPOSE 50051 4369 4370

# Set the default command
CMD ["sh", "-c", "if [ -n \"$MN_NODE_NAME\" ]; then if [ -z \"$MN_COOKIE\" ] || [ \"$MN_COOKIE\" = \"mirrorneuron\" ]; then echo \"MN_COOKIE must be set to a non-default secret when MN_NODE_NAME enables distributed Erlang\" >&2; exit 1; fi; dist_port=\"${MN_DIST_PORT:-4370}\"; unset ERL_EPMD_ADDRESS; epmd -daemon; exec elixir --name \"$MN_NODE_NAME\" --cookie \"$MN_COOKIE\" --erl \"-kernel inet_dist_listen_min ${dist_port} inet_dist_listen_max ${dist_port}\" -S mix run --no-halt; else exec mix run --no-halt; fi"]

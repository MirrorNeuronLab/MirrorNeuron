FROM elixir:1.16-slim

# Install system dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates \
    git \
    make \
    g++ \
    libssl-dev \
    protobuf-compiler \
    curl \
    python3 \
    python3-pip \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --no-cache-dir --break-system-packages "litellm[proxy]>=1.72.0"

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

# Copy the rest of the application
COPY . .

# Compile the application
RUN mix compile

EXPOSE 50051 4369 4370

# Set the default command
CMD ["sh", "-c", "if [ -n \"$MN_NODE_NAME\" ]; then if [ -z \"$MN_COOKIE\" ] || [ \"$MN_COOKIE\" = \"mirrorneuron\" ]; then echo \"MN_COOKIE must be set to a non-default secret when MN_NODE_NAME enables distributed Erlang\" >&2; exit 1; fi; dist_port=\"${MN_DIST_PORT:-4370}\"; unset ERL_EPMD_ADDRESS; epmd -daemon; exec elixir --name \"$MN_NODE_NAME\" --cookie \"$MN_COOKIE\" --erl \"-kernel inet_dist_listen_min ${dist_port} inet_dist_listen_max ${dist_port}\" -S mix run --no-halt; else exec mix run --no-halt; fi"]

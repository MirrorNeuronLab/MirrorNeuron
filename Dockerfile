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
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

ARG OPENSHELL_VERSION=v0.0.16
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      arm64) openshell_target="aarch64-unknown-linux-musl"; openshell_sha="7301b47e37f498e6535c0fa3c1f8db505d385719cbe94de10fc1dc69b83e37fb" ;; \
      amd64) openshell_target="x86_64-unknown-linux-musl"; openshell_sha="c95ffd08705f3fce6198e5cb9992fa4e8c5eea63b581758c761db5925b92fec5" ;; \
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
RUN mix deps.get

# Copy the rest of the application
COPY . .

# Compile the application
RUN mix compile

EXPOSE 50051 4369 9000-9010

# Set the default command
CMD ["sh", "-c", "if [ -n \"$MN_NODE_NAME\" ]; then elixir --name $MN_NODE_NAME --cookie ${MN_COOKIE:-mirrorneuron} --erl \"-kernel inet_dist_listen_min 9000 inet_dist_listen_max 9010\" -S mix run --no-halt; else mix run --no-halt; fi"]

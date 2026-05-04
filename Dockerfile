FROM elixir:1.16-slim

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git \
    make \
    g++ \
    libssl-dev \
    protobuf-compiler \
    curl \
    python3 \
    && rm -rf /var/lib/apt/lists/*

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

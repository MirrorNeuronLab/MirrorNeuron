# MirrorNeuron Architecture

MirrorNeuron is designed as an Elixir/BEAM runtime for orchestrating multi-agent workflows with bounded sandbox execution. Currently, the `mn` CLI and the HTTP API act as two shells interfacing directly with the internal core components.

In the future, introducing a unified SDK layer would abstract these internal interfaces, allowing both the CLI and the Web API to consume the same stable public boundary.

## System Context

The overall system architecture involves the Developer/Operator interacting with MirrorNeuron, which in turn manages execution via OpenShell.

```mermaid
graph LR
  linkStyle default fill:#ffffff

  subgraph diagram ["System Context View: MirrorNeuron"]
    style diagram fill:#ffffff,stroke:#ffffff

    1["<div style='font-weight: bold'>Developer / Operator</div><div style='font-size: 70%; margin-top: 0px'>[Person]</div><div style='font-size: 80%; margin-top:10px'>Interacts with MirrorNeuron<br />to submit jobs, monitor<br />execution, and manage the<br />cluster.</div>"]
    style 1 fill:#08427b,stroke:#052e56,color:#ffffff
    15("<div style='font-weight: bold'>OpenShell</div><div style='font-size: 70%; margin-top: 0px'>[Software System]</div><div style='font-size: 80%; margin-top:10px'>Provides bounded sandbox<br />execution environments.</div>")
    style 15 fill:#1168bd,stroke:#0b4884,color:#ffffff
    2("<div style='font-weight: bold'>MirrorNeuron</div><div style='font-size: 70%; margin-top: 0px'>[Software System]</div><div style='font-size: 80%; margin-top:10px'>Elixir/BEAM runtime for<br />orchestrating multi-agent<br />workflows with bounded<br />sandbox execution.</div>")
    style 2 fill:#1168bd,stroke:#0b4884,color:#ffffff

    1-. "<div>Uses for terminal operations</div><div style='font-size: 70%'></div>" .->2
    2-. "<div>Executes commands in isolated<br />sandboxes</div><div style='font-size: 70%'></div>" .->15

  end
```

## Containers

Zooming in, we see the main components that make up MirrorNeuron:
*   **CLI Tool (mn)**: Terminal-first interface.
*   **REST API**: HTTP API.
*   **Core Runtime**: Built on Elixir/BEAM, handles orchestration and state.
*   **Sandbox Manager**: Handles OpenShell interaction.
*   **Persistence Store**: Redis for state.

```mermaid
graph LR
  linkStyle default fill:#ffffff

  subgraph diagram ["Container View: MirrorNeuron"]
    style diagram fill:#ffffff,stroke:#ffffff

    1["<div style='font-weight: bold'>Developer / Operator</div><div style='font-size: 70%; margin-top: 0px'>[Person]</div><div style='font-size: 80%; margin-top:10px'>Interacts with MirrorNeuron<br />to submit jobs, monitor<br />execution, and manage the<br />cluster.</div>"]
    style 1 fill:#08427b,stroke:#052e56,color:#ffffff
    15("<div style='font-weight: bold'>OpenShell</div><div style='font-size: 70%; margin-top: 0px'>[Software System]</div><div style='font-size: 80%; margin-top:10px'>Provides bounded sandbox<br />execution environments.</div>")
    style 15 fill:#1168bd,stroke:#0b4884,color:#ffffff

    subgraph 2 ["MirrorNeuron"]
      style 2 fill:#ffffff,stroke:#0b4884,color:#0b4884

      11("<div style='font-weight: bold'>Sandbox Manager</div><div style='font-size: 70%; margin-top: 0px'>[Container: Elixir]</div><div style='font-size: 80%; margin-top:10px'>Manages the lifecycle of<br />OpenShell sandboxes for<br />isolated execution.</div>")
      style 11 fill:#438dd5,stroke:#2e6295,color:#ffffff
      14("<div style='font-weight: bold'>Persistence Store</div><div style='font-size: 70%; margin-top: 0px'>[Container: Redis]</div><div style='font-size: 80%; margin-top:10px'>Stores job state, agent<br />snapshots, and event history.</div>")
      style 14 fill:#438dd5,stroke:#2e6295,color:#ffffff
      3("<div style='font-weight: bold'>CLI Tool (mn)</div><div style='font-size: 70%; margin-top: 0px'>[Container: Elixir Escript]</div><div style='font-size: 80%; margin-top:10px'>Provides terminal-first<br />tooling for interacting with<br />MirrorNeuron.</div>")
      style 3 fill:#438dd5,stroke:#2e6295,color:#ffffff
      4("<div style='font-weight: bold'>REST API</div><div style='font-size: 70%; margin-top: 0px'>[Container: Plug / Bandit]</div><div style='font-size: 80%; margin-top:10px'>HTTP API for inspection,<br />control, and external<br />integration (e.g., Web UI).</div>")
      style 4 fill:#438dd5,stroke:#2e6295,color:#ffffff
      5("<div style='font-weight: bold'>Core Runtime</div><div style='font-size: 70%; margin-top: 0px'>[Container: Elixir / BEAM]</div><div style='font-size: 80%; margin-top:10px'>Handles orchestration,<br />supervision, message routing,<br />clustering, and persistence.</div>")
      style 5 fill:#438dd5,stroke:#2e6295,color:#ffffff
    end

    1-. "<div>Uses for terminal operations</div><div style='font-size: 70%'></div>" .->3
    1-. "<div>Uses via Web UI or scripts</div><div style='font-size: 70%'></div>" .->4
    3-. "<div>Submits jobs, monitors,<br />controls via Erlang RPC</div><div style='font-size: 70%'></div>" .->5
    4-. "<div>Inspects and controls via<br />Elixir API</div><div style='font-size: 70%'></div>" .->5
    5-. "<div>Persists state, events, and<br />metrics</div><div style='font-size: 70%'></div>" .->14
    5-. "<div>Requests execution of agent<br />logic</div><div style='font-size: 70%'></div>" .->11
    11-. "<div>Executes commands in isolated<br />sandboxes</div><div style='font-size: 70%'></div>" .->15

  end
```

## Core Runtime Components

The core logic within the BEAM node relies on several GenServers and internal modules to route messages and coordinate jobs.

```mermaid
graph LR
  linkStyle default fill:#ffffff

  subgraph diagram ["Component View: MirrorNeuron - Core Runtime"]
    style diagram fill:#ffffff,stroke:#ffffff

    subgraph 2 ["MirrorNeuron"]
      style 2 fill:#ffffff,stroke:#0b4884,color:#0b4884

      subgraph 5 ["Core Runtime"]
        style 5 fill:#ffffff,stroke:#2e6295,color:#2e6295

        10("<div style='font-weight: bold'>Lease Manager</div><div style='font-size: 70%; margin-top: 0px'>[Component: GenServer]</div><div style='font-size: 80%; margin-top:10px'>Manages execution leases to<br />bound sandbox capacity.</div>")
        style 10 fill:#85bbf0,stroke:#5d82a8,color:#ffffff
        6("<div style='font-weight: bold'>Job Coordinator</div><div style='font-size: 70%; margin-top: 0px'>[Component: GenServer]</div><div style='font-size: 80%; margin-top:10px'>Manages the lifecycle of a<br />job, including starting<br />agents, handling terminal<br />states, and cleanup.</div>")
        style 6 fill:#85bbf0,stroke:#5d82a8,color:#ffffff
        7("<div style='font-weight: bold'>Agent Worker</div><div style='font-size: 70%; margin-top: 0px'>[Component: GenServer]</div><div style='font-size: 80%; margin-top:10px'>Represents a logical agent in<br />a workflow, holds state, and<br />coordinates with OpenShell<br />for execution.</div>")
        style 7 fill:#85bbf0,stroke:#5d82a8,color:#ffffff
        8("<div style='font-weight: bold'>Message Router</div><div style='font-size: 70%; margin-top: 0px'>[Component: Elixir]</div><div style='font-size: 80%; margin-top:10px'>Routes messages between<br />agents within the same job.</div>")
        style 8 fill:#85bbf0,stroke:#5d82a8,color:#ffffff
        9("<div style='font-weight: bold'>Event Bus</div><div style='font-size: 70%; margin-top: 0px'>[Component: Registry]</div><div style='font-size: 80%; margin-top:10px'>Publishes and subscribes to<br />job-related events.</div>")
        style 9 fill:#85bbf0,stroke:#5d82a8,color:#ffffff
      end

    end

    6-. "<div>Supervises and controls</div><div style='font-size: 70%'></div>" .->7
    7-. "<div>Sends and receives messages</div><div style='font-size: 70%'></div>" .->8
    6-. "<div>Publishes lifecycle events</div><div style='font-size: 70%'></div>" .->9
    7-. "<div>Publishes state changes and<br />errors</div><div style='font-size: 70%'></div>" .->9
    7-. "<div>Requests execution leases</div><div style='font-size: 70%'></div>" .->10

  end
```

## Sandbox Manager Components

The component that bridges Elixir space to the external OpenShell environments.

```mermaid
graph LR
  linkStyle default fill:#ffffff

  subgraph diagram ["Component View: MirrorNeuron - Sandbox Manager"]
    style diagram fill:#ffffff,stroke:#ffffff

    subgraph 2 ["MirrorNeuron"]
      style 2 fill:#ffffff,stroke:#0b4884,color:#0b4884

      subgraph 11 ["Sandbox Manager"]
        style 11 fill:#ffffff,stroke:#2e6295,color:#2e6295

        12("<div style='font-weight: bold'>Job Sandbox</div><div style='font-size: 70%; margin-top: 0px'>[Component: Elixir]</div><div style='font-size: 80%; margin-top:10px'>Interfaces with OpenShell to<br />create, manage, and execute<br />commands within a sandbox.</div>")
        style 12 fill:#85bbf0,stroke:#5d82a8,color:#ffffff
        13("<div style='font-weight: bold'>OpenShell Client</div><div style='font-size: 70%; margin-top: 0px'>[Component: System.cmd]</div><div style='font-size: 80%; margin-top:10px'>Low-level client for<br />interacting with the<br />OpenShell CLI/Daemon.</div>")
        style 13 fill:#85bbf0,stroke:#5d82a8,color:#ffffff
      end

    end

    12-. "<div>Uses to interact with<br />OpenShell</div><div style='font-size: 70%'></div>" .->13

  end
```

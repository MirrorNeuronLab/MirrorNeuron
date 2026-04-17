workspace "MirrorNeuron" "Architecture of the MirrorNeuron runtime" {

    model {
        user = person "Developer / Operator" "Interacts with MirrorNeuron to submit jobs, monitor execution, and manage the cluster."

        mirror_neuron = softwareSystem "MirrorNeuron" "Elixir/BEAM runtime for orchestrating multi-agent workflows with bounded sandbox execution." {
            
            cli = container "CLI Tool (mn)" "Provides terminal-first tooling for interacting with MirrorNeuron." "Elixir Escript"
            
            api = container "REST API" "HTTP API for inspection, control, and external integration (e.g., Web UI)." "Plug / Bandit"

            core_runtime = container "Core Runtime" "Handles orchestration, supervision, message routing, clustering, and persistence." "Elixir / BEAM" {
                job_coordinator = component "Job Coordinator" "Manages the lifecycle of a job, including starting agents, handling terminal states, and cleanup." "GenServer"
                agent_worker = component "Agent Worker" "Represents a logical agent in a workflow, holds state, and coordinates with OpenShell for execution." "GenServer"
                message_router = component "Message Router" "Routes messages between agents within the same job." "Elixir"
                event_bus = component "Event Bus" "Publishes and subscribes to job-related events." "Registry"
                lease_manager = component "Lease Manager" "Manages execution leases to bound sandbox capacity." "GenServer"
            }

            sandbox_manager = container "Sandbox Manager" "Manages the lifecycle of OpenShell sandboxes for isolated execution." "Elixir" {
                job_sandbox = component "Job Sandbox" "Interfaces with OpenShell to create, manage, and execute commands within a sandbox." "Elixir"
                open_shell_client = component "OpenShell Client" "Low-level client for interacting with the OpenShell CLI/Daemon." "System.cmd"
            }
            
            redis_store = container "Persistence Store" "Stores job state, agent snapshots, and event history." "Redis"
        }

        openshell = softwareSystem "OpenShell" "Provides bounded sandbox execution environments." "Rust/Go (External)"

        # Relationships between people and software systems
        user -> cli "Uses for terminal operations"
        user -> api "Uses via Web UI or scripts"

        # Relationships between containers
        cli -> core_runtime "Submits jobs, monitors, controls via Erlang RPC"
        api -> core_runtime "Inspects and controls via Elixir API"
        
        core_runtime -> redis_store "Persists state, events, and metrics"
        core_runtime -> sandbox_manager "Requests execution of agent logic"
        
        sandbox_manager -> openshell "Executes commands in isolated sandboxes"

        # Relationships between components (Internal to Core Runtime)
        job_coordinator -> agent_worker "Supervises and controls"
        agent_worker -> message_router "Sends and receives messages"
        job_coordinator -> event_bus "Publishes lifecycle events"
        agent_worker -> event_bus "Publishes state changes and errors"
        agent_worker -> lease_manager "Requests execution leases"

        # Relationships between components (Internal to Sandbox Manager)
        job_sandbox -> open_shell_client "Uses to interact with OpenShell"
    }

    views {
        systemContext mirror_neuron "SystemContext" {
            include *
            autoLayout
        }

        container mirror_neuron "Containers" {
            include *
            autoLayout
        }

        component core_runtime "CoreRuntimeComponents" {
            include *
            autoLayout
        }
        
        component sandbox_manager "SandboxManagerComponents" {
            include *
            autoLayout
        }

        theme default
    }
}

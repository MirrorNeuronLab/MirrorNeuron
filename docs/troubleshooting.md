# Troubleshooting

This guide collects the most common operational failures seen during local and two-box testing.

## Redis issues

### Redis is not running

Symptoms:

- runtime tests fail immediately
- `mirror_neuron run ...` hangs or errors

Check:

```bash
docker ps
docker exec mirror-neuron-redis redis-cli ping
```

Fix:

```bash
docker rm -f mirror-neuron-redis 2>/dev/null || true
docker run -d --name mirror-neuron-redis -p 6379:6379 redis:7
```

## OpenShell issues

### gateway is not reachable

Symptoms:

- transport errors
- connection reset by peer
- jobs fail before worker code starts

Check:

```bash
openshell status
openshell sandbox list
```

Reset:

```bash
openshell gateway destroy --name openshell
openshell gateway start
openshell status
```

### stale sandboxes slow everything down

Symptoms:

- long provisioning delays
- tiny jobs feel slow
- repeated benchmark runs degrade over time

Clean prime-test sandboxes:

```bash
NO_COLOR=1 openshell sandbox list | awk 'NR>1 && index($1, "prime-worker-")==1 {print $1}' | xargs -I{} openshell sandbox delete {}
```

## Cluster issues

### `:nodistribution`

Check:

```bash
epmd -names
nc -vz 127.0.0.1 4369
```

Fix:

- make sure `epmd` is running
- use fixed Erlang distribution ports
- verify local firewall rules

### Invalid challenge reply

Symptoms:

- `[error] ** Connection attempt from node :"node2@192.168.4.173" rejected. Invalid challenge reply. **`
- Nodes fail to form a cluster even when IP and ports are fully reachable

Fix:

- This is an **Erlang Cookie mismatch**. Both nodes must share the exact same secret cookie.
- If you are running nodes on different physical machines, they will auto-generate different cookies by default.
- Set the cookie explicitly on both boxes before starting: `export MIRROR_NEURON_COOKIE="my_shared_secret"`

### HTTP port `eaddrinuse` (4000 already in use)

Symptoms:

- `[error] Running MirrorNeuron.API.Router with Bandit 1.10.4 at http failed, port 4000 already in use`
- `** (EXIT) shutdown: failed to start child: :listener`

Fix:

- By default, the MirrorNeuron HTTP API binds to port `4000`. 
- If you run multiple nodes on the same machine, or if you accidentally configure the Erlang `--bind` to port 4000, they will clash.
- Override the HTTP API port for one of the nodes: `export MIRROR_NEURON_API_PORT=4001`
- Make sure your Erlang `--bind` distribution port (e.g. `4370`) is completely different from your `MIRROR_NEURON_API_PORT`.

### runtime node name already in use

Symptoms:

- `the name mn1@... seems to be in use`
- `eaddrinuse`

Fix:

- stop the old runtime first
- avoid starting the same box twice

### cluster forms but work does not land on both boxes

Possible causes:

- job is too small
- remote bundle sync failed
- stale CLI/control nodes are confusing routing
- one box has less executor capacity

Check:

```bash
bash scripts/cluster_cli.sh --box1-ip 192.168.4.29 --box2-ip 192.168.4.35 --self-ip 192.168.4.29 -- inspect nodes
./mirror_neuron monitor --box1-ip 192.168.4.29 --box2-ip 192.168.4.35 --self-ip 192.168.4.29
```

## Monitor issues

### monitor shows too many old jobs

This usually means Redis still contains older job metadata.

Options:

- ignore completed jobs with `--running-only`
- delete old jobs manually if needed

### monitor JSON has build noise

Use the checked-in wrapper:

- `./mirror_neuron monitor`

It starts the app in a cleaner mode than raw `mix run`.

## LLM example issues

### Gemini API key missing

Symptoms:

- local LLM e2e fails quickly
- cluster LLM harness fails at the first codegen stage

Fix:

```bash
export GEMINI_API_KEY="..."
```

### Python version mismatch across boxes

Symptoms:

- code works on box 1 but fails on box 2
- typing-related syntax errors on older Python versions

Check:

```bash
python3 --version
```

Try to keep both boxes on a compatible Python version.

## When a run feels slower than expected

Common reasons:

- OpenShell provisioning cost
- cold image pulls
- stale gateway state
- large numbers of very tiny executor tasks
- low executor concurrency

If the workflow itself is tiny but runtime is slow, look first at:

- sandbox lifecycle overhead
- gateway health
- whether jobs are being oversharded

## Good diagnostic commands

```bash
./mirror_neuron inspect nodes
./mirror_neuron events <job_id>
./mirror_neuron inspect agents <job_id>
./mirror_neuron monitor
openshell status
openshell sandbox list
epmd -names
```

# Divisibility Monitor Example

This is a simple long-lived MirrorNeuron workflow that keeps running until you stop it manually.

## What it does

1. `question_generator` emits a new random divisibility question every 1.5 seconds.
2. `answer_agent` answers `yes` or `no` and logs the result.
3. The generator re-schedules itself after every answer, so the job stays active until you press `Ctrl+C` or cancel the job.

## How to run

From the project root:

```bash
./mirror_neuron validate examples/divisibility_monitor
./mirror_neuron run examples/divisibility_monitor --no-await
```

For a detached end-to-end launcher that starts a background runtime, submits the job, prints the `job_id`, and exits while leaving the job running:

```bash
bash examples/divisibility_monitor/run_divisibility_e2e.sh
```

If you want to watch the job after starting it:

```bash
./mirror_neuron monitor
./mirror_neuron agent list <job_id>
./mirror_neuron events <job_id>
```

## Notes

- This example does not use OpenShell.
- It is intentionally open-ended, so there is no final result summary unless you manually cancel the job.
- It uses `local_restart` recovery, so old interrupted runs are not automatically resumed across fresh local CLI invocations.

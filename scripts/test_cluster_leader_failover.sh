#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BOX1_IP="127.0.0.1"
BOX2_IP="127.0.0.1"

echo "Starting node 1 (Leader Candidate 1)"
MIRROR_NEURON_DIST_PORT=4371 bash scripts/start_cluster_node.sh --box1-ip $BOX1_IP --box2-ip $BOX2_IP --box 1 &
NODE1_PID=$!

sleep 5

echo "Starting node 2 (Leader Candidate 2)"
MIRROR_NEURON_DIST_PORT=4372 bash scripts/start_cluster_node.sh --box1-ip $BOX1_IP --box2-ip $BOX2_IP --box 2 &
NODE2_PID=$!

sleep 5

echo "Submitting test job..."
JOB_ID=$(bash scripts/cluster_cli.sh --box1-ip $BOX1_IP --box2-ip $BOX2_IP --self-ip $BOX1_IP -- run examples/research_flow | grep -o 'job-[a-zA-Z0-9-]*')
echo "Job submitted: $JOB_ID"

sleep 5

echo "Killing Node 1 to trigger leader failover and job recovery on Node 2..."
kill -9 $NODE1_PID

echo "Waiting for recovery..."
sleep 15

echo "Checking if job completed on Node 2..."
STATUS=$(bash scripts/cluster_cli.sh --box1-ip $BOX1_IP --box2-ip $BOX2_IP --self-ip $BOX2_IP -- inspect job $JOB_ID | grep -i status)
echo "Job status after failover: $STATUS"

echo "Cleaning up..."
kill -9 $NODE2_PID || true
echo "Leader failover and recovery test completed."

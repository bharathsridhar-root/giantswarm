#!/bin/bash
# Deploys the factory telemetry simulator to the lab's kind cluster.
# Run from a shell with KUBECONFIG pointed at the lab (state/kubeconfig).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

kubectl apply -f "$SCRIPT_DIR/manifests.yaml"

kubectl create configmap factory-simulator -n factory \
  --from-file=simulate.py="$SCRIPT_DIR/simulate.py" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart deployment/factory-simulator -n factory
kubectl rollout status deployment/factory-simulator -n factory --timeout=120s

echo
echo "Deployed. Verify Prometheus is scraping it:"
echo "  kubectl get servicemonitor -n factory"
echo "Then, through muster (x_mcp-prometheus_execute_query), try the PromQL:"
echo "  factory_machine_temperature_celsius"

#!/usr/bin/env bash
# Sample the HPA, the replica count and pod CPU every 5s, as CSV on stdout.
#
#   bash deploy/scripts/watch-hpa.sh [release] [namespace] > hpa.csv
#
# This is the local stand-in for the CloudWatch dashboard's "Running tasks
# (autoscaling in action)" widget. Scaling is only interesting next to the
# percentiles it was supposed to protect, so run it alongside k6 and line the
# timestamps up afterwards.
set -euo pipefail

RELEASE="${1:-booklog}"
NS="${2:-booklog}"
INTERVAL="${INTERVAL:-5}"

echo "ts,desired,current,ready,cpu_target_pct,cpu_current_pct,pod_cpu_millicores,pg_connections"
while true; do
  ts=$(date -u +%H:%M:%S)

  read -r desired current ready <<<"$(kubectl get hpa "$RELEASE" -n "$NS" \
    -o jsonpath='{.status.desiredReplicas} {.status.currentReplicas} {.spec.minReplicas}' 2>/dev/null || echo "- - -")"
  ready=$(kubectl get deploy "$RELEASE" -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "-")

  target=$(kubectl get hpa "$RELEASE" -n "$NS" \
    -o jsonpath='{.spec.metrics[?(@.resource.name=="cpu")].resource.target.averageUtilization}' 2>/dev/null || echo "-")
  cur=$(kubectl get hpa "$RELEASE" -n "$NS" \
    -o jsonpath='{.status.currentMetrics[?(@.resource.name=="cpu")].resource.current.averageUtilization}' 2>/dev/null || echo "-")

  millis=$(kubectl top pods -n "$NS" -l app.kubernetes.io/component=api --no-headers 2>/dev/null \
    | awk '{gsub(/m$/,"",$2); s+=$2} END {print (NR ? s : "-")}')

  # The number the load test says actually matters. Needs the dev Postgres;
  # against RDS, read DatabaseConnections in CloudWatch instead.
  conns=$(kubectl exec -n "$NS" deploy/"$RELEASE"-postgres -- \
    psql -U booktracker -d booktracker -tAc \
    "select count(*) from pg_stat_activity where backend_type='client backend'" 2>/dev/null | tr -d '[:space:]')

  echo "${ts},${desired:--},${current:--},${ready:--},${target:--},${cur:--},${millis:--},${conns:--}"
  sleep "$INTERVAL"
done

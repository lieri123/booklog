#!/usr/bin/env bash
# Delete the kind cluster. Nothing here costs money, so this is just tidiness -
# unlike scripts/teardown.ps1, which exists because AWS keeps billing.
set -euo pipefail
kind delete cluster --name booklog

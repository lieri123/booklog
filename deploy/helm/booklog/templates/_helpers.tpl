{{/* Name helpers */}}
{{- define "booklog.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "booklog.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "booklog.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "booklog.labels" -}}
helm.sh/chart: {{ include "booklog.chart" . }}
{{ include "booklog.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "booklog.selectorLabels" -}}
app.kubernetes.io/name: {{ include "booklog.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "booklog.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "booklog.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "booklog.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) -}}
{{- end -}}

{{- define "booklog.secretName" -}}
{{- if .Values.database.existingSecret -}}
{{- .Values.database.existingSecret -}}
{{- else -}}
{{- printf "%s-credentials" (include "booklog.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
The JWT secret must survive an upgrade: regenerating it logs every user out.
Reuse the value already in the cluster when one exists, mirroring why the
Terraform random_password for the JWT secret is only defensible because
rotating it does nothing worse than invalidate sessions.
*/}}
{{- define "booklog.jwtSecret" -}}
{{- if .Values.database.jwtSecret -}}
{{- .Values.database.jwtSecret -}}
{{- else -}}
{{- $name := printf "%s-credentials" (include "booklog.fullname" .) -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace $name -}}
{{- $key := .Values.database.secretKeys.jwtSecret -}}
{{- if and $existing (hasKey $existing.data $key) -}}
{{- index $existing.data $key | b64dec -}}
{{- else -}}
{{- randAlphaNum 48 -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Where the application points. PgBouncer, when enabled, sits in between. */}}
{{- define "booklog.appDbHost" -}}
{{- if .Values.pgbouncer.enabled -}}
{{- printf "%s-pgbouncer" (include "booklog.fullname" .) -}}
{{- else -}}
{{- include "booklog.postgresHost" . -}}
{{- end -}}
{{- end -}}

{{- define "booklog.appDbPort" -}}
{{- if .Values.pgbouncer.enabled -}}
{{- .Values.pgbouncer.port -}}
{{- else -}}
{{- .Values.database.port -}}
{{- end -}}
{{- end -}}

{{/* The real Postgres, whatever is in front of it. */}}
{{- define "booklog.postgresHost" -}}
{{- if .Values.database.host -}}
{{- .Values.database.host -}}
{{- else if .Values.devPostgres.enabled -}}
{{- printf "%s-postgres" (include "booklog.fullname" .) -}}
{{- else -}}
{{- fail "\n\nbooklog: set database.host to your Postgres endpoint, or devPostgres.enabled=true for a throwaway in-cluster database (kind/k3s only).\n" -}}
{{- end -}}
{{- end -}}

{{/*
The connection budget.

This is the load test's finding (docs/load-test.md) turned into an install-time
assertion. The application is bound by Postgres connections, not CPU: each pod
opens its own asyncpg pool of POOL_MAX_SIZE, and asyncpg's acquire() waits
rather than raising when the pool is exhausted, so exceeding the budget shows up
as latency and a rising error rate - never as a connection error. Nothing in the
HPA's CPU signal can detect it, which is why the ceiling has to be enforced
here, before the cluster is allowed to discover it under load.
*/}}
{{- define "booklog.peakPods" -}}
{{- if .Values.autoscaling.enabled -}}
{{- .Values.autoscaling.maxReplicas -}}
{{- else -}}
{{- .Values.replicaCount -}}
{{- end -}}
{{- end -}}

{{- define "booklog.budgetReport" -}}
{{- $peak := int (include "booklog.peakPods" .) -}}
{{- $pool := int .Values.app.poolMaxSize -}}
{{- $max := int .Values.database.maxConnections -}}
{{- $reserved := int .Values.connectionBudget.reserved -}}
{{- $available := min (sub $max $reserved) (div (mul $max (int .Values.connectionBudget.utilizationTarget)) 100) -}}
{{- if .Values.pgbouncer.enabled -}}
{{- $demand := mul (int .Values.pgbouncer.replicaCount) (int .Values.pgbouncer.defaultPoolSize) -}}
{{- printf "pgbouncer: %d replicas x %d server connections = %d of %d available (max_connections %d - %d reserved). App side: %d pods x %d = %d client connections against %d max_client_conn." (int .Values.pgbouncer.replicaCount) (int .Values.pgbouncer.defaultPoolSize) $demand $available $max $reserved $peak $pool (mul $peak $pool) (mul (int .Values.pgbouncer.replicaCount) (int .Values.pgbouncer.maxClientConn)) -}}
{{- else -}}
{{- printf "direct: %d peak pods x %d pool = %d of %d usable (max_connections %d, %d reserved, %d%% utilization ceiling)." $peak $pool (mul $peak $pool) $available $max $reserved (int .Values.connectionBudget.utilizationTarget) -}}
{{- end -}}
{{- end -}}

{{- define "booklog.checkConnectionBudget" -}}
{{- if .Values.connectionBudget.enforce -}}
{{- $peak := int (include "booklog.peakPods" .) -}}
{{- $pool := int .Values.app.poolMaxSize -}}
{{- $max := int .Values.database.maxConnections -}}
{{- $reserved := int .Values.connectionBudget.reserved -}}
{{- $available := min (sub $max $reserved) (div (mul $max (int .Values.connectionBudget.utilizationTarget)) 100) -}}
{{- if .Values.pgbouncer.enabled -}}
{{- $demand := mul (int .Values.pgbouncer.replicaCount) (int .Values.pgbouncer.defaultPoolSize) -}}
{{- if gt $demand $available -}}
{{- fail (printf "\n\nbooklog: connection budget exceeded (pgbouncer).\n\n  pgbouncer replicas   %d\n  default_pool_size    %d\n  server connections   %d\n  usable               %d  (max_connections %d, %d reserved, %d%% ceiling)\n\nLower pgbouncer.replicaCount or pgbouncer.defaultPoolSize, or move to a larger\ninstance class and raise database.maxConnections to match.\n" (int .Values.pgbouncer.replicaCount) (int .Values.pgbouncer.defaultPoolSize) $demand $available $max $reserved (int .Values.connectionBudget.utilizationTarget)) -}}
{{- end -}}
{{- $clients := mul $peak $pool -}}
{{- $capacity := mul (int .Values.pgbouncer.replicaCount) (int .Values.pgbouncer.maxClientConn) -}}
{{- if gt $clients $capacity -}}
{{- fail (printf "\n\nbooklog: pgbouncer max_client_conn too low.\n\n  peak pods x pool     %d\n  max_client_conn      %d across %d replicas = %d\n\nRaise pgbouncer.maxClientConn.\n" $clients (int .Values.pgbouncer.maxClientConn) (int .Values.pgbouncer.replicaCount) $capacity) -}}
{{- end -}}
{{- else -}}
{{- $demand := mul $peak $pool -}}
{{- if gt $demand $available -}}
{{- fail (printf "\n\nbooklog: connection budget exceeded.\n\n  peak pods            %d   (autoscaling.maxReplicas)\n  pool per pod         %d   (app.poolMaxSize)\n  peak demand          %d\n  usable               %d   (max_connections %d, %d reserved, %d%% ceiling)\n\nThis is the failure docs/load-test.md measured: raising the ceiling from 6 to\n10 pods put 100 connections against ~112, and throughput FELL from 122.9 to\n117.5 req/s while the error rate went from 0.00%% to 1.72%%. asyncpg's pool\nwaits rather than raising, so you will see it as latency, and db_connection_errors\nwill read 0 throughout.\n\nPick one:\n  - lower autoscaling.maxReplicas to %d or less\n  - lower app.poolMaxSize\n  - set pgbouncer.enabled=true  (transaction pooling; the documented fix)\n  - resize the database and raise database.maxConnections to match\n\nOr set connectionBudget.enforce=false if you are deliberately reproducing the\nfailure for a comparison run.\n" $peak $pool $demand $available $max $reserved (int .Values.connectionBudget.utilizationTarget) (div $available $pool)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

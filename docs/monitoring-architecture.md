# Monitoring architecture (M1)

Monitoring M1 adds Prometheus and Grafana for technical/platform health of the
OmniVise deployment on the homelab k3s cluster and on AWS EKS. This document
describes the **repository-owned monitoring contract** (#145): the content and
values that both environments install, and the rules the infrastructure roots
must follow when consuming it.

Delivery sequence: #144 backend metrics (done) ∥ #145 contract (this document) →
#146 homelab Terraform → #147 homelab acceptance → #148 AWS adaptation → #149 AWS
acceptance. Terraform roots, cluster changes and live acceptance are **not**
part of the contract and are not implemented by it.

## Layout

```text
monitoring/
  versions.yaml               pinned charts (+ artifact sha256), release name, toolchain
  expected-targets.yaml       expected / intentionally disabled scrape jobs per environment
  metric-allowlist.txt        metric names rules and dashboards may reference
  values/base.yaml            shared semantics
  values/homelab.yaml         homelab sizing + retention
  values/aws.yaml             AWS sizing + retention
  values/generated/content.yaml   GENERATED rules + dashboards layer (committed)
  rules/*.rules.yaml          alert rules, promtool format (source of truth)
  rules/tests/*.test.yaml     promtool unit tests
  dashboards/*.json           Grafana dashboards (source of truth)
  scripts/                    install-tools, fetch-chart, render-content, render, check-*, validate
  scripts/tests/              validator self-tests and fixtures
```

`monitoring/.tools/` (pinned toolchain) and `monitoring/.cache/` (verified chart
artifacts) are local and git-ignored.

## Release and values contract

| Property | Value |
|---|---|
| Chart | `prometheus-community/kube-prometheus-stack` `93.9.0` (see `docs/monitoring-versions.md`) |
| Helm release name | `kube-prometheus-stack` (`versions.yaml` `helmRelease.name`) |
| Namespace | `monitoring` |
| Values merge order | `base.yaml` → `<env>.yaml` → `generated/content.yaml` |

The release name is part of the contract: rendered object and ServiceMonitor
names derive from it, and `expected-targets.yaml` records them.

Consumers (CI, #146, #148) must pass the three values files in exactly this
order. A Terraform root may layer **its own storage values after them**
(see [Sizing and storage ownership](#sizing-and-storage-ownership)); it must not
re-implement the rule or dashboard injection.

## Single injection mechanism for rules and dashboards

`monitoring/scripts/render-content.sh` is the only transformation from the
source files to chart values:

- `rules/<name>.rules.yaml` → `additionalPrometheusRulesMap.<name>` (the promtool
  file content verbatim; the chart renders one `PrometheusRule`
  `kube-prometheus-stack-<name>` per file);
- `dashboards/<name>.json` → `grafana.dashboards.omnivise.<name>.json` (the raw
  JSON string; the Grafana subchart renders the ConfigMap
  `kube-prometheus-stack-grafana-dashboards-omnivise`, provisioned through the
  `omnivise` file provider defined in `base.yaml`).

The output `values/generated/content.yaml` is committed. Both CI and the
Terraform roots consume that file, so there is no second transformation to keep
equivalent. CI regenerates it and fails on any difference (drift check), and the
render contract asserts that the rendered `PrometheusRule` objects and dashboard
ConfigMap equal the source files.

Dashboard size: the rendered dashboards ConfigMap must stay at or below
**512 KiB**. This is a project safety limit chosen well below the Kubernetes
object and Helm release-Secret limits (1 MiB); it is not itself a Kubernetes
limit.

The Grafana subchart adds a `download-dashboards` init container
(`curlimages/curl`) whenever `grafana.dashboards` is set, including for inline
JSON. It is accepted as chart behaviour, carries explicit requests/limits and
must appear in the #148 image list.

## Shared semantics (`base.yaml`)

- `crds.enabled: false` — the release never owns Prometheus Operator CRDs.
- `defaultRules.create: false`, `grafana.defaultDashboardsEnabled: false` — only
  repository-owned rules and dashboards. Dashboards therefore use raw metrics
  only (the chart's recording rules do not exist).
- Alertmanager disabled (no notifications in M1).
- `kubeEtcd`, `kubeScheduler`, `kubeControllerManager`, `kubeProxy` disabled
  (embedded in k3s, managed on EKS). `coreDns` enabled.
- Prometheus: scrape and evaluation interval `30s`.
- Shared-cluster hardening, each verified on the rendered output:
  - `prometheusOperator.admissionWebhooks.enabled: false` with
    `prometheusOperator.tls.enabled: false`. Without the webhook patch job nothing
    creates the operator TLS secret, so chart `93.9.0` refuses to render with TLS
    left on. Result: no cluster-scoped `*WebhookConfiguration`, no certgen hook Jobs.
  - `prometheusInstanceNamespaces`, `alertmanagerInstanceNamespaces`,
    `alertmanagerConfigNamespaces`, `thanosRulerInstanceNamespaces` = `[monitoring]`.
    These render the operator flags `--prometheus-instance-namespaces=monitoring`,
    `--alertmanager-instance-namespaces=monitoring`,
    `--alertmanager-config-namespaces=monitoring`, and
    `--thanos-ruler-instance-namespaces=monitoring`. Per the operator `v0.95.2`
    flag help, these restrict which instance CRs it reconciles and take precedence
    over `--namespaces`. The operator never reconciles another owner's
    Prometheus/Alertmanager/ThanosRuler. ServiceMonitor discovery is unaffected,
    and the rendered RBAC is unchanged.
  - `grafana.testFramework.enabled: false` (no `helm test` hook Pod).
  - `grafana.sidecar.dashboards.enabled: false`. Dashboards are inline, so Grafana
    does not watch ConfigMaps cluster-wide. The datasource sidecar remains and
    watches its own namespace only. Its Alertmanager datasource is disabled.

## Grafana Secret contract

- Grafana reads its admin credentials from the Secret **`grafana-admin`** in
  `monitoring`, keys **`admin-user`** and **`admin-password`**
  (`grafana.admin.existingSecret`, `userKey`, `passwordKey`).
- The Secret is provisioned **outside Git and outside Terraform/HCP state** (an
  explicit secret-provisioning exception, see #146/#148 runbooks). Terraform and
  Helm reference it by name only. It is never read by a Terraform data source.
- The password is never committed in any form.
- Render contract (CI): no Grafana admin Secret is rendered, no Secret carries
  `admin-user`/`admin-password` keys, and `GF_SECURITY_ADMIN_USER` /
  `GF_SECURITY_ADMIN_PASSWORD` are `secretKeyRef`s to `grafana-admin` with these
  keys.
- Grafana is reachable only in-cluster: Service `ClusterIP`, no Ingress, and
  anonymous access explicitly disabled (`[auth.anonymous] enabled = false`).

## Expected targets and the effective `job` contract

`expected-targets.yaml` lists, per environment, the enabled jobs (with the
rendered ServiceMonitor that produces each) and the intentionally disabled jobs.
Job labels are **never inferred from ServiceMonitor names**. The validator
derives the effective Prometheus `job` for every rendered ServiceMonitor endpoint
with the operator's own order. The order was checked in `pkg/prometheus/promcfg.go`
of operator `v0.95.2`: the Service name, then the Service label named by
`jobLabel` if present, then the endpoint `relabelings`, which are appended last
and therefore win. The derived job must equal the recorded one. A job that
cannot be derived from the render fails validation.

Explicit `job` relabelings are configured wherever a job would otherwise depend
on a Service that this chart does not render, or on a release-derived name:

| ServiceMonitor | Selected Service | Job source | Effective `job` |
|---|---|---|---|
| `kube-prometheus-stack-apiserver` | `default/kubernetes` (not rendered) | explicit relabeling | `apiserver` |
| `kube-prometheus-stack-kubelet` | `kube-system/kube-prometheus-stack-kubelet` (operator-managed, not rendered) | explicit relabeling on all endpoints | `kubelet` |
| `kube-prometheus-stack-kube-state-metrics` | rendered | `jobLabel: app.kubernetes.io/name` | `kube-state-metrics` |
| `kube-prometheus-stack-prometheus-node-exporter` | rendered | `jobLabel: jobLabel` | `node-exporter` |
| `kube-prometheus-stack-coredns` | rendered (`kube-system`, chart-owned headless Service) | `jobLabel: jobLabel` | `coredns` |
| `kube-prometheus-stack-prometheus` | release-derived name | explicit relabeling (both endpoints) | `prometheus` |
| `kube-prometheus-stack-operator` | release-derived name | explicit relabeling | `prometheus-operator` |
| `kube-prometheus-stack-grafana` | release-derived name | explicit relabeling | `grafana` |
| `backend` | `omnivise-iot/backend` port `http` (#144 contract) | explicit relabeling | `backend` |

The backend ServiceMonitor is created through `prometheus.additionalServiceMonitors`.
That key was verified against the chart `93.9.0` values; the chart emits it inside
a `kind: List` wrapper. It selects `app.kubernetes.io/name=backend`,
`app.kubernetes.io/component=api` in namespace `omnivise-iot`, port `http`, path
`/metrics`. `up{job="backend"}` is therefore guaranteed by the relabeling, not
by the Service name.

Disabled jobs: `kube-etcd`, `kube-scheduler`, `kube-controller-manager`,
`kube-proxy` (embedded in k3s / managed by EKS) and `alertmanager` (not deployed).
The rendered ServiceMonitor set must equal the enabled list exactly, so a
ServiceMonitor for a disabled job always fails validation. The optional
`serviceMonitorPattern` is an extra guard.

## Rules

Ten alerts, technical/platform health only:

| Alert | Scope | For | Severity |
|---|---|---|---|
| `TargetDown` (`up == 0` for the enabled expected jobs) | expected jobs | 5m | critical |
| `KubePodCrashLooping` | `omnivise-iot`, `monitoring` | 5m | warning |
| `ContainerOOMKilled` | `omnivise-iot`, `monitoring` | 0m | warning |
| `KubeDeploymentReplicasMismatch` | `omnivise-iot`, `monitoring` | 10m | warning |
| `KubeStatefulSetReplicasMismatch` | `omnivise-iot`, `monitoring` | 10m | warning |
| `KubeNodeNotReady` | cluster | 5m | critical |
| `KubeNodeMemoryPressure` | cluster | 5m | warning |
| `KubeNodeDiskPressure` | cluster | 5m | warning |
| `PrometheusRuleEvaluationFailures` | `job="prometheus"` | 5m | warning |
| `BackendHighErrorRatio` (5xx / all > 5%) | `job="backend"` | 10m | critical |

- Workload rules are namespace-scoped because the homelab cluster is shared:
  they must not alert on other tenants' workloads.
- `TargetDown` detects targets that are down. A job that is missing entirely
  (no series) is caught by the render cross-check and by the acceptance runs
  (#147/#149), not by this alert.
- `ContainerOOMKilled` combines
  `increase(kube_pod_container_status_restarts_total[10m]) > 0` with
  `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1` on
  `(namespace, pod, container)`. The terminated-reason series stays at 1 until
  the next termination, so on its own it would fire indefinitely after one
  historic OOM kill. Restarts alone would also fire for non-OOM crashes. The
  alert therefore fires only within 10 minutes of a restart whose last
  termination reason was OOMKilled. The tests cover both false-positive cases.
- `BackendHighErrorRatio` with zero traffic evaluates to `NaN` and does not fire
  (tested).
- Every alert has `severity` ∈ {`warning`, `critical`}, `summary` and
  `description`, and at least one firing and one explicit non-firing
  (`exp_alerts: []`) promtool test case (enforced).

## Dashboards

| uid | Content |
|---|---|
| `omnivise-backend-red-jvm` | request rate by route, 5xx ratio, p50/p95/p99 latency, status mix, JVM heap, GC pause, threads, process CPU, file descriptors |
| `omnivise-platform-health` | expected targets `up`, node CPU/memory/filesystem, node conditions, not-ready pods, restarts, deployment availability, container CPU/memory, Prometheus head series and rule failures |

All panels use the `${datasource}` template variable (type `prometheus`), not a
chart-generated datasource uid. Backend metric names follow
`docs/backend-metrics.md`. The JVM/process names were confirmed against the
backend's Micrometer `1.12.3` binders. A mismatch found live is flagged by
#147 and fixed in this contract.

## Domain-metric policy

Rules and dashboard panels may reference only metrics on
`monitoring/metric-allowlist.txt`: `up`, `kube_*`, `node_*`, `kubelet_*`,
`container_*`, `prometheus_*`, `jetty_server_requests_seconds_*`, `jvm_*`,
`process_*`. `monitoring/scripts/promql_policy.py` enforces this. It is a
fail-closed lint, not a PromQL parser. It rejects these:
- any metric outside the allowlist;
- `__name__` matchers;
- unknown functions;
- template variables outside matchers or ranges;
- any construct it cannot classify.

Sensor, reading, device and alert-threshold metrics are therefore excluded.

## CRD ownership: conditional CRD-root model

Prometheus Operator CRDs are cluster-scoped and never owned by the monitoring
release. Ownership is decided per environment by a read-only gate
(`kubectl get crd -o name | grep monitoring.coreos.com`):

- **OWNED:** no `monitoring.coreos.com` CRDs exist. A dedicated CRD root
  (`infra/homelab-monitoring-crds` in #146, `infra/aws-monitoring-crds` in #148),
  with its own HCP workspace, installs the pinned `prometheus-operator-crds`
  chart. Only that root may destroy them, and only after verifying that no
  operator CRs remain from any owner.
- **EXTERNAL:** compatible CRDs exist and are owned by the platform or another
  consumer. No CRD root or workspace is created, and the CRDs are consumed as an
  external cluster contract. OmniVise never mutates, reinstalls, adopts, imports
  or deletes them. A read-only precondition check verifies that they exist and
  that their operator version is compatible with the pinned `v0.95.2`.

Invariant: *a monitoring CRD root may destroy only CRDs that it unambiguously
owns.* Expected on AWS (dedicated cluster): OWNED. Homelab: decided by the #146
gate.

## Sizing and storage ownership

| Concern | Owner |
|---|---|
| Retention time | `homelab.yaml` (`7d`), `aws.yaml` (`3d`) — checked per environment |
| Requests/limits of every rendered container | `homelab.yaml`, `aws.yaml` — validation fails if any container lacks cpu/memory requests or limits |
| Homelab storage (PVC ~5Gi `local-path`, `retentionSize`) | `infra/homelab-monitoring` (#146), layered after the contract values. #146 cannot edit `homelab.yaml`. |
| AWS storage (`emptyDir`, `sizeLimit`, `retentionSize`) and final sizing | #148 (owns `aws.yaml` from then on) |
| `monitoring` namespace, quota, LimitRange | homelab: platform; AWS: `infra/aws-monitoring` (#148) |

**Initial sizing values.** These are not accepted capacity. The homelab footprint
is measured in #147, and AWS sizing is refined in #148 and proven in #149. Both
environments currently use the same baseline:

| Container | CPU req / limit | Memory req / limit |
|---|---|---|
| prometheus | 100m / 500m | 512Mi / 1Gi |
| config-reloader (sidecar; also the init container) | 10m / 50m | 25Mi / 50Mi |
| prometheus-operator | 50m / 200m | 64Mi / 128Mi |
| grafana | 50m / 250m | 128Mi / 256Mi |
| grafana-sc-datasources | 10m / 100m | 64Mi / 128Mi |
| download-dashboards (init) | 10m / 50m | 32Mi / 64Mi |
| kube-state-metrics | 20m / 100m | 64Mi / 128Mi |
| node-exporter (per node) | 20m / 100m | 32Mi / 64Mi |
| **Steady-state total, single node** (init containers excluded) | **260m / 1300m** | **889Mi / 1778Mi** |

## Known trade-offs and risks (handed to #146 / #148)

- **kube-state-metrics is cluster-wide.** It collects all namespaces and uses a
  ClusterRole. Restricting it would create RBAC in the application namespace,
  crossing ownership. On a shared homelab this collects other tenants' object
  metadata and increases series count. Rules and dashboards filter by
  namespace, and #147 measures the cost.
- **node-exporter** uses `hostNetwork` on port `9100`. If another node-exporter
  already runs on the homelab nodes, the DaemonSet will conflict. This is a #146
  gate check. No speculative port change is made here.
- **`kube-system` writes.** The chart creates a headless CoreDNS metrics Service
  in `kube-system`, and the operator manages the kubelet Service there. If that
  is not permitted on the shared homelab, the #146 gate must surface it.
- The chart's ClusterRoles/ClusterRoleBindings (operator, Prometheus,
  kube-state-metrics) are cluster-scoped. Admission webhooks are not.

## Validation (CI job `monitoring-validate`)

```bash
monitoring/scripts/install-tools.sh   # pinned helm 3.22.1, promtool 3.16.0, yq 4.54.3 (sha256-verified, idempotent)
monitoring/scripts/validate.sh
```

`validate.sh` runs these steps in order:
1. Fetches the stack chart once and verifies its SHA256.
2. Runs the generated-content drift check.
3. For each environment (`homelab`, `aws`), independently: renders
   `base → env → generated/content` from that verified local chart and asserts
   the render contract.
4. Rule checks: promtool check and test, the test-coverage rule, the TargetDown
   job-set comparison, and the domain policy.
5. Dashboard checks.
6. `check-versions.sh --offline-contract`.
7. The validator self-tests.

The render contract asserts:
- no Alertmanager, Ingress, admission webhooks or `helm test` hooks are rendered;
- every Service is `ClusterIP`;
- the Grafana Secret contract holds, and anonymous access is off;
- no dashboard sidecar is rendered;
- every container, including the Prometheus CR and the config-reloader, has
  requests and limits;
- the operator namespace scope is set;
- retention matches the environment;
- the rendered rules and dashboards equal their sources, within the size limit;
- the rendered ServiceMonitor set and effective jobs match `expected-targets.yaml`.

The self-tests (`scripts/tests/run.sh`) prove that each check rejects a broken
variant for the stated reason. The broken variants are:
- a domain metric in the policy helper, in rules and in dashboards;
- generated-content drift;
- a ServiceMonitor that is disabled, unexpected or missing;
- a rendered Grafana Secret or a plain-text password;
- anonymous Grafana access;
- a missing request or limit;
- an effective-job mismatch, or a job that cannot be derived;
- operator scope, webhook, Ingress or retention violations;
- an alert without a non-firing test;
- TargetDown drift;
- a hard-coded datasource uid;
- a tampered chart artifact.

CI validates with the pinned Helm 3, the same major version that the Terraform
helm provider embeds. A different local Helm major version produces only a
warning.

Kubernetes schema validation of the rendered output (e.g. kubeconform) is out
of scope for M1 and is a possible follow-up.

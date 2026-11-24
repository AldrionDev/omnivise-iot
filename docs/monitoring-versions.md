# Monitoring chart versions

## Pinned versions

| Component                                       | Chart version | App version |
| ----------------------------------------------- | ------------- | ----------- |
| `prometheus-community/kube-prometheus-stack`    | `93.9.0`      | `v0.95.2`   |
| `prometheus-community/prometheus-operator-crds` | `33.0.2`      | `v0.95.2`   |

The authoritative pins, including the chart artifact SHA256 digests and the
validation toolchain, live in `monitoring/versions.yaml`. This table is checked
against that file on every CI run (`check-versions.sh --offline-contract`).

These versions are intentionally pinned and must not be updated independently
without re-running the compatibility proof documented below.

## Chart artifact integrity

Each pinned chart is identified by the SHA256 of its `.tgz` artifact, recorded in
`monitoring/versions.yaml`. The digests match the `digest` fields of the
`prometheus-community` Helm repository index for these versions (checked
2026-11-24).

`monitoring/scripts/fetch-chart.sh` downloads a chart once into
`monitoring/.cache/charts/`, verifies the digest, and fails closed on mismatch.
Every render (CI, self-tests, version checks) uses that exact verified local
artifact; nothing renders from the remote repository reference directly.

## Kubernetes compatibility

`kube-prometheus-stack` `93.9.0` declares:

```text
kubeVersion: '>=1.25.0-0'
```

The monitoring M1 AWS target is EKS Kubernetes `1.36`
(`infra/aws-platform/variables.tf`), which satisfies this declared constraint.

Homelab k3s compatibility is conditional: `kubernetesCompatibility.homelabTarget`
stays `null` until the homelab monitoring gate (#146) establishes the concrete
k3s version. Once set, the same constraint check applies to it.

The repository contract in `monitoring/versions.yaml` records:

```yaml
kubernetesCompatibility:
  stackConstraint: ">=1.25.0-0"
  eksTarget: "1.36"
  homelabTarget: null
```

## Prometheus Operator compatibility

The pinned stack chart and the standalone CRD chart both use Prometheus Operator
app version `v0.95.2`.

The `kube-prometheus-stack` chart contains an embedded local `crds` subchart
rather than declaring the standalone `prometheus-operator-crds` chart as a
versioned external dependency. Therefore matching `appVersion` values alone are
not treated as sufficient compatibility evidence: the rendered CRD objects of
both charts are compared.

This is a real risk, not a formality. An earlier probe pair
(`kube-prometheus-stack` `92.18.0` with `prometheus-operator-crds` `33.0.0`)
renders ten CRDs on both sides whose object content differs (205 lines of
normalised diff, reproduced 2026-11-24 with the same comparison method).

## Reproducible compatibility proof

The proof is executable and is the authority for this document:

```bash
monitoring/scripts/install-tools.sh
monitoring/scripts/check-versions.sh --verify-upstream
```

It fetches both pinned charts (SHA256-verified), checks their `Chart.yaml`
metadata against `monitoring/versions.yaml`, checks the Kubernetes constraint,
compares the operator `appVersion`s, renders the stack's embedded `crds` subchart
and the standalone CRD chart with `helm template --include-crds`, and requires
exactly ten `CustomResourceDefinition` objects on each side with identical object
content. The comparison parses the YAML and compares the objects sorted by name,
so Helm source comments, blank lines and document separators do not affect it.

### Recorded result

Run on 2026-11-24 with Helm `v3.22.1` (pinned toolchain):

```text
[monitoring] version contract OK (offline): kube-prometheus-stack 93.9.0, kubeVersion >=1.25.0-0, eksTarget 1.36
chart pair: kube-prometheus-stack 93.9.0 (v0.95.2) / prometheus-operator-crds 33.0.2 (v0.95.2)
stack embedded CRDs: 10, standalone CRD chart: 10
  alertmanagerconfigs.monitoring.coreos.com  0.95.2
  alertmanagers.monitoring.coreos.com  0.95.2
  podmonitors.monitoring.coreos.com  0.95.2
  probes.monitoring.coreos.com  0.95.2
  prometheusagents.monitoring.coreos.com  0.95.2
  prometheuses.monitoring.coreos.com  0.95.2
  prometheusrules.monitoring.coreos.com  0.95.2
  scrapeconfigs.monitoring.coreos.com  0.95.2
  servicemonitors.monitoring.coreos.com  0.95.2
  thanosrulers.monitoring.coreos.com  0.95.2
CRD object content: identical (10 objects)
[monitoring] upstream verification OK (2026-11-24T17:16:40Z)
```

Therefore `kube-prometheus-stack` `93.9.0` and `prometheus-operator-crds`
`33.0.2` are treated as a compatible chart pair for monitoring M1. The pinned
operator version `v0.95.2` is also the reference for the EXTERNAL-mode CRD
compatibility check in #146.

## Ownership model

The monitoring stack does not own the Prometheus Operator CRDs.
`kube-prometheus-stack` is rendered with:

```yaml
crds:
  enabled: false
```

The CRDs are managed separately (the pinned `prometheus-operator-crds` chart in
OWNED mode, or an external owner in EXTERNAL mode; see
`docs/monitoring-architecture.md`). This keeps the lifecycle of cluster-scoped
CRDs separate from the monitoring stack release and prevents multiple releases
or Terraform roots from managing the same CRD resources.

## Upgrade rule

Any change to either pinned chart version must:

1. update the version, `appVersion` and artifact `sha256` in
   `monitoring/versions.yaml` from live Helm repository evidence;
2. run `monitoring/scripts/check-versions.sh --verify-upstream` and record its
   output and date in this document;
3. run `monitoring/scripts/validate.sh`.

A version pair must not be accepted solely because both charts are recent or
because their `appVersion` fields appear compatible. If the rendered CRD object
definitions differ, the pair is incompatible until the differences are
understood and explicitly accepted.

The daily CI job runs only `--offline-contract`, so pull requests do not depend
on the availability of the CRD chart; `--verify-upstream` is mandatory for
version bumps and for acceptance evidence.

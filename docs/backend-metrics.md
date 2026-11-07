# Backend Metrics

## Endpoint

`GET /metrics`

Returns Prometheus text exposition format (exposition version 0.0.4).

**Content-Type:** `text/plain; version=0.0.4; charset=utf-8`

No authentication is required. The endpoint is not proxied by the frontend Nginx
and is not accessible from the internet via the Ingress.

---

## Metric contract

### JVM and process metrics

| Metric prefix         | Source                     |
|-----------------------|----------------------------|
| `jvm_memory_*`        | `JvmMemoryMetrics`         |
| `jvm_gc_*`            | `JvmGcMetrics`             |
| `jvm_threads_*`       | `JvmThreadMetrics`         |
| `process_files_*`     | `FileDescriptorMetrics`    |
| `process_cpu_usage`   | `ProcessorMetrics`         |
| `system_cpu_usage`    | `ProcessorMetrics`         |

### HTTP request metrics

Jetty request metrics are exposed via the Javalin `MicrometerPlugin`.

**Metric name:** `jetty_server_requests_seconds_*`

Exposed series:

| Suffix          | Type      |
|-----------------|-----------|
| `_count`        | counter   |
| `_sum`          | gauge     |
| `_bucket`       | histogram |

---

## HTTP label contract

Each `jetty_server_requests_seconds_*` series carries the following labels:

| Label       | Values                                                      |
|-------------|-------------------------------------------------------------|
| `exception` | exception class name, or `none` when no exception occurred  |
| `method`    | HTTP method (`GET`, `POST`, …)                              |
| `outcome`   | Micrometer outcome string (`SUCCESS`, `CLIENT_ERROR`, …)    |
| `status`    | HTTP status code as string (`200`, `404`, …)                |
| `uri`       | route template or `NOT_FOUND` (see below)                   |

The bounded-cardinality guarantee applies primarily to the `uri` label.
The other labels (`exception`, `method`, `outcome`, `status`) are low-cardinality
by nature and do not require additional filtering.

---

## URI label — route-template based, bounded cardinality

The `uri` label is set by Javalin's `MicrometerPlugin` to the **route template**,
not the raw request path.

Declared routes resolve to their template:

| Template                      | Example path                           |
|-------------------------------|----------------------------------------|
| `/api/devices/{deviceId}`     | `/api/devices/device-001`              |
| `/api/sensors/latest`         | `/api/sensors/latest?deviceId=d-01`    |
| `/api/sensors/history`        | `/api/sensors/history?deviceId=...`    |
| `/api/alerts`                 | `/api/alerts?state=firing`             |
| `/api/alerts/active`          | `/api/alerts/active`                   |
| `/api/alerts/rules`           | `/api/alerts/rules`                    |
| `/health`                     | `/health`                              |
| `/metrics`                    | `/metrics`                             |
| `/`                           | `/`                                    |

### NOT_FOUND fallback

Requests to paths not matching any declared route receive `uri="NOT_FOUND"`.
This prevents unbounded cardinality from random crawlers or path-scanning probes.

### Banned / high-cardinality label values

The following must never appear as `uri` label values:

| Banned value class                     | Why                               |
|----------------------------------------|-----------------------------------|
| Raw device IDs (e.g. `device-001`)     | Per-device path, 50+ distinct IDs |
| Random path segments                   | Unbounded crawler traffic         |
| Query string parameters and values     | Unbounded (tokens, IDs, filters)  |

---

## Histogram buckets

HTTP request latency buckets (seconds):

| Bucket    | Milliseconds |
|-----------|-------------|
| `le="0.01"`  | 10 ms    |
| `le="0.025"` | 25 ms    |
| `le="0.05"`  | 50 ms    |
| `le="0.1"`   | 100 ms   |
| `le="0.25"`  | 250 ms   |
| `le="0.5"`   | 500 ms   |
| `le="1.0"`   | 1 s      |
| `le="+Inf"`  | unbounded |

**Rationale:** A small, fixed bucket set covering the expected latency range of this
backend. The 10–50 ms buckets provide fine-grained resolution for fast in-cluster
reads. The 100–500 ms range separates normal database query latency from degraded
responses. The 1 s bucket distinguishes clearly slow requests from the unbounded
`+Inf` tail.

---

## Kubernetes Service contract

The backend `kubernetes_service_v1.backend` in `infra/modules/application/workloads.tf`
exposes a stable Service for Prometheus scraping:

| Property           | Value                                      |
|--------------------|--------------------------------------------|
| Service name       | `backend`                                  |
| Selector labels    | `app.kubernetes.io/name=backend`, `app.kubernetes.io/component=api` |
| Port name          | `http`                                     |
| Port               | `8080`                                     |
| Protocol           | `TCP`                                      |
| Type               | `ClusterIP`                                |

The port name `http` is stable and must not be changed, as it is the discovery
key for Prometheus `ServiceMonitor` resources when they are added.

---

## Docker Compose development notes

- The backend container exposes port `8080` to the host in `docker-compose.yml`
  for local development access to `/metrics`.
- The frontend Nginx does **not** proxy `/metrics`. The endpoint is not part of
  the public API surface and must not be routed through the application Ingress.
- `mongo-express` is a local development tool and must not be deployed to shared,
  homelab, or cloud environments.

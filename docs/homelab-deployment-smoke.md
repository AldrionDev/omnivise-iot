# Homelab Deployment Smoke Runbook

## Purpose

This runbook describes one controlled, reproducible OmniVise IoT deployment to
the shared homelab k3s platform from an exact repository commit.

It proves the complete runtime data path:

```text
sensor-simulator
      -> MongoDB rs0 PRIMARY (omnivise_iot.sensor_readings)
      -> MongoDB Change Stream
      -> backend
      -> WebSocket /ws/sensors
      -> frontend Nginx
      -> Traefik
      -> browser / client
```

The deployment uses exact Git SHA image tags, the local homelab registry, the
least-privilege `omnivise-iot-deployer` kubeconfig for Terraform, HCP Terraform
remote state in Local execution mode, a saved Terraform plan, and explicit
maintainer approval before apply. The canonical external hostname is
`omnivise-iot.homelab.home.arpa` over plain HTTP.

This reviewed runbook is the manual reference for the later Homelab Delivery
automation milestone. That automation must be derived from this proven manual
path, not from a different deployment architecture.

---

## Status and change discipline

This file is the ONLY repository change for issue #40.

It must reach its final, reviewed form BEFORE `VERIFY_WORKTREE` and independent
review. Once the live Human Gates begin, this file MUST NOT be edited.

Actual live deployment results, command transcripts, digests, and quota usage
numbers are recorded in the Engineering Workflow Human Gate records and in the
pull request evidence, never by mutating this file. A post-review change to this
tracked file would produce a different reviewed candidate and invalidate the
Engineering Workflow v1 fingerprint and gate-evidence contract.

This file contains only placeholder names and command templates. It must not
contain any HCP token, kubeconfig content, Kubernetes bearer token, Terraform
state, tracked Terraform plan, registry credential, image digest, or the
homelab host LAN IP.

---

## Roles and identities

Two distinct identities are used and must never be conflated.

1. Terraform plan/apply identity: the operator-issued least-privilege kubeconfig
   from `AldrionDev/homelab-platform#42`.

   ```text
   context:          omnivise-iot-deployer
   service account:  system:serviceaccount:omnivise-iot:omnivise-iot-deployer
   namespace:        omnivise-iot
   ```

   Never substitute an admin kubeconfig for Terraform plan/apply because it is
   more permissive.

2. Deep runtime inspection identity: a separate operator/admin kubeconfig used
   only for actions the deployer RBAC intentionally does not allow, such as
   `kubectl exec` into the MongoDB Pod for read-only `mongosh`, controlled
   MongoDB Pod recreation, and backend `/health` inspection through an
   operator-run port-forward.

Do not broaden the `omnivise-iot-deployer` RBAC to make any verification step
more convenient. If a verification needs more than the deployer identity allows,
use the operator/admin identity for that step only.

---

## Operator-supplied runtime values (names only)

Supplied by the operator at run time, outside Git. Names only, no values here.

```text
HOMELAB_REGISTRY        = <HOST_LAN_IP>:5000        # plain-HTTP local registry authority
GIT_SHA                 = <rev-parse HEAD of the separate clean deployment checkout>
DEPLOYER_KUBECONFIG     = <path to the omnivise-iot-deployer kubeconfig>
DEPLOYER_CONTEXT        = omnivise-iot-deployer
OPERATOR_KUBECONFIG     = <path to the operator/admin kubeconfig>   # deep runtime inspection only
```

HCP Terraform authentication is provided through an operator-managed credential
mechanism outside Git (for example a locally exported `TF_TOKEN_*` or an
untracked CLI credentials file). The token is never placed in Terraform source,
`*.tfvars`, Git, this document, or a committed shell transcript.

An operator `/etc/hosts` entry of the form
`<HOST_LAN_IP> omnivise-iot.homelab.home.arpa` may be required on the operator
workstation. It is optional, operator-managed, and only added after explicit
maintainer approval (see the Human Gate sequence).

---

## Prerequisites

### Dependency gate

Do not begin the live deployment until all of the following are true.

Merged OmniVise issues:

```text
#33  deployment-safe MongoDB runtime connection contract
#34  deterministic Terraform verification
#35  Terraform/HCP application bootstrap (HCP workspace Human Gates resolved)
#36  persistent single-node MongoDB rs0 workload
#37  deployment-safe frontend Nginx DNS resolution
#38  backend/frontend/simulator workloads and Services
#39  Traefik routing
```

Merged AND successfully applied platform issues:

```text
AldrionDev/homelab-platform#41   omnivise-iot Namespace + ResourceQuota
AldrionDev/homelab-platform#42   omnivise-iot-deployer identity + least-privilege RBAC + kubeconfig
```

HCP Terraform workspace gate from #35 resolved:

```text
workspace:        omnivise-iot-k8s
execution mode:   Local
```

The platform Namespace and ResourceQuota from `#41` and the deployer RBAC from
`#42` must already be applied to the cluster before the OmniVise application
Terraform plan is created.

### Tooling

The operator workstation needs:

```text
git
a container build tool (for example docker or buildah)
a Registry V2 query tool (for example curl)
terraform  >= 1.9.0
kubectl
mongosh
a WebSocket client (for example websocat or wscat)
```

The local homelab registry is served as plain HTTP on port 5000. The operator's
container build/runtime must be configured to treat `<HOST_LAN_IP>:5000` as an
insecure (non-TLS) registry as a precondition of this smoke. The concrete IP is
not recorded in this document.

---

## 1. Exact source revision selection

Verification category: SOURCE.

The H5 issue worktree that carries this runbook is NOT usable as the container
image build context. It is expected to carry an uncommitted change (this file)
before staging, so it can never satisfy the clean-source requirement.

Create a separate clean checkout or worktree at the intended merged `main`
revision, after every implementation prerequisite above is merged.

In that separate deployment source checkout:

```bash
git status --porcelain            # must produce no output
git rev-parse HEAD                # record as GIT_SHA
```

Confirm the separate deployment source checkout:

- points at the intended merged `main` revision;
- has an empty `git status --porcelain`;
- has no locally modified `backend/Dockerfile`, `frontend/Dockerfile`, or
  `simulators/Dockerfile`;
- has no untracked build-affecting file;
- stays unchanged for the entire build and publish phase.

`GIT_SHA` is taken only from this separate clean checkout.

Forbidden build sources:

```text
the H5 issue worktree
an uncommitted source checkout
a dirty source checkout
a floating branch reference with no recorded exact SHA
a locally modified Dockerfile
```

---

## 2. Local registry image naming

Canonical, immutable image references:

```text
${HOMELAB_REGISTRY}/omnivise-iot/backend:${GIT_SHA}
${HOMELAB_REGISTRY}/omnivise-iot/frontend:${GIT_SHA}
${HOMELAB_REGISTRY}/omnivise-iot/simulator:${GIT_SHA}
```

Note the naming asymmetry: the registry image path segment is `simulator`, while
the Kubernetes Deployment and its selector labels use `sensor-simulator` and
the workload has no Service. This is expected; do not "fix" one to match the
other.

`latest` is forbidden as a deployment reference. The Terraform root also rejects
it: `backend_image_ref`, `frontend_image_ref`, and `simulator_image_ref` each
have a validation that fails on a `:latest` suffix.

GHCR and any second container registry are forbidden for this milestone. The
local homelab registry is authoritative.

A local convenience tag may exist outside the deployment proof, but Terraform
receives only the exact-SHA references above.

---

## 3. Registry write-once precheck

Verification category: REGISTRY.

Before building or pushing anything, query Registry V2 for all three exact-SHA
manifests.

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  "http://${HOMELAB_REGISTRY}/v2/omnivise-iot/backend/manifests/${GIT_SHA}"
curl -sS -o /dev/null -w '%{http_code}\n' \
  "http://${HOMELAB_REGISTRY}/v2/omnivise-iot/frontend/manifests/${GIT_SHA}"
curl -sS -o /dev/null -w '%{http_code}\n' \
  "http://${HOMELAB_REGISTRY}/v2/omnivise-iot/simulator/manifests/${GIT_SHA}"
```

Handle the result fail-closed:

```text
all three absent (e.g. 404/404/404)      -> build and push all three (sections 4-5)
all three already present (200/200/200)   -> reuse all three; never overwrite an exact-SHA tag
partial presence (any mix)                -> STOP; leave the publish gate unresolved
unexpected response (5xx, auth error,     -> STOP; leave the publish gate unresolved
  malformed body, connection failure)
```

The smoke must never silently replace an existing exact-SHA image tag.

---

## 4. Image build procedure

Perform this section only when the section 3 precheck found all three manifests
absent.

Build from the separate clean deployment source checkout at the exact recorded
`GIT_SHA`, using the repository Dockerfiles:

```text
backend    -> backend/Dockerfile      build context backend/
frontend   -> frontend/Dockerfile     build context frontend/
simulator  -> simulators/Dockerfile   build context simulators/
```

```bash
# run from the separate clean deployment source checkout root
docker build -t "${HOMELAB_REGISTRY}/omnivise-iot/backend:${GIT_SHA}"   backend
docker build -t "${HOMELAB_REGISTRY}/omnivise-iot/frontend:${GIT_SHA}"  frontend
docker build -t "${HOMELAB_REGISTRY}/omnivise-iot/simulator:${GIT_SHA}" simulators
```

Tag only with the canonical exact-SHA deployment references. Do not build any
deployment image from the H5 issue worktree.

---

## 5. Image push and registry proof

Verification category: REGISTRY.

Push all three canonical references:

```bash
docker push "${HOMELAB_REGISTRY}/omnivise-iot/backend:${GIT_SHA}"
docker push "${HOMELAB_REGISTRY}/omnivise-iot/frontend:${GIT_SHA}"
docker push "${HOMELAB_REGISTRY}/omnivise-iot/simulator:${GIT_SHA}"
```

Re-query Registry V2 for the three exact-SHA manifests and confirm:

- all three manifests exist;
- the registry returns successful manifest responses;
- the published references are exactly the requested SHA-tagged names above;
- the registry-reported digests are captured for the Human Gate / PR evidence.

Do not record concrete digests in this file. Do not proceed to Terraform if any
image is absent or any registry response is inconsistent.

---

## 6. HCP Terraform initialization

Verification category: TERRAFORM.

Run from `infra/homelab`.

```bash
cd infra/homelab
terraform fmt -check -recursive ..
terraform init            # HCP-authenticated; may read HCP Terraform state
terraform validate
```

The backend is the HCP `cloud` block in `infra/homelab/versions.tf`
(`workspaces { name = "omnivise-iot-k8s" }`); execution mode is Local. The
dependency lockfile `infra/homelab/.terraform.lock.hcl` must not be modified
during the smoke.

---

## 7. Deployment kubeconfig / context verification

Before any Terraform plan, prove the selected kubeconfig/context is the
least-privilege deployer identity. Use read-only checks only.

```bash
kubectl --kubeconfig "${DEPLOYER_KUBECONFIG}" --context "${DEPLOYER_CONTEXT}" \
  auth whoami
kubectl --kubeconfig "${DEPLOYER_KUBECONFIG}" --context "${DEPLOYER_CONTEXT}" \
  auth can-i --list -n omnivise-iot
```

Expected:

```text
identity:   system:serviceaccount:omnivise-iot:omnivise-iot-deployer
namespace:  omnivise-iot
```

Do not substitute an admin kubeconfig for Terraform plan/apply.

---

## 8. Saved Terraform plan creation

Verification category: TERRAFORM.

Create a saved plan from `infra/homelab`:

```bash
terraform plan -out tfplan
```

The plan must be produced with the exact image references and the exact
deployment kubeconfig/context. The Terraform root variables are:

```text
backend_image_ref     = ${HOMELAB_REGISTRY}/omnivise-iot/backend:${GIT_SHA}
frontend_image_ref    = ${HOMELAB_REGISTRY}/omnivise-iot/frontend:${GIT_SHA}
simulator_image_ref   = ${HOMELAB_REGISTRY}/omnivise-iot/simulator:${GIT_SHA}
kubeconfig_path       = ${DEPLOYER_KUBECONFIG}
kubernetes_context    = omnivise-iot-deployer
ingress_host          = omnivise-iot.homelab.home.arpa    # root default; supply only to override
traefik_entrypoint    = web                               # root default; supply only to override
```

The issue contract uses the shorthand names `backend_image`, `frontend_image`,
`simulator_image` and speaks of a kubeconfig path/context input; the real root
variable names are `backend_image_ref`, `frontend_image_ref`,
`simulator_image_ref`, `kubeconfig_path`, and `kubernetes_context` as defined in
`infra/homelab/variables.tf`.

Provide the values through a non-committed operator `*.auto.tfvars` file or
`-var` flags. There is no mutable image default; the three `*_image_ref`
variables are required and reject a `:latest` suffix.

The `tfplan` file:

- is local only;
- is permission-restricted where supported (`chmod 600 tfplan`);
- is never committed;
- is deleted after the deployment transaction (see Cleanup).

---

## 9. Plan inspection

Verification category: TERRAFORM.

```bash
terraform show tfplan
terraform show -json tfplan
```

The change-set must touch ONLY these resource addresses (verify the exact
addresses against `infra/homelab` and `infra/modules/application` while
reviewing):

```text
module.application.data.kubernetes_namespace_v1.application   # read (data source), not created
module.application.kubernetes_service_v1.mongodb
module.application.kubernetes_stateful_set_v1.mongodb
module.application.kubernetes_job_v1.mongodb_bootstrap
module.application.kubernetes_deployment_v1.backend
module.application.kubernetes_service_v1.backend
module.application.kubernetes_deployment_v1.frontend
module.application.kubernetes_service_v1.frontend
module.application.kubernetes_deployment_v1.sensor_simulator
kubernetes_manifest.frontend_ingressroute                     # root module (infra/homelab/ingress.tf)
```

The plan must NOT:

- create or modify Namespace `omnivise-iot` (it is a data source only);
- create or modify the namespace ResourceQuota;
- modify platform RBAC;
- modify HomeStreamLab or HomeOps;
- create Secrets;
- create MongoDB authentication;
- create NodePort or LoadBalancer Services;
- introduce TLS;
- contain any unexpected destroy or replace operation.

Every container `image` field in the plan must equal the canonical exact-SHA
reference for that component. Any unexpected delete, replace, cross-project
change, or privilege-scope expansion is a STOP condition.

---

## 10. Human Gate - plan approval

The maintainer explicitly reviews the saved plan and approves applying that
exact plan with the `omnivise-iot-deployer` identity. No apply happens before
this approval is recorded (see the Human Gate sequence, gate 3).

---

## 11. Saved-plan apply

Verification category: TERRAFORM.

```bash
terraform apply tfplan
```

Forbidden:

- regenerating an unreviewed plan after approval;
- running an implicit unsaved plan during apply;
- `-auto-approve`;
- switching kubeconfig/context after plan approval;
- switching image references after plan approval.

---

## 12. Deployment identity verification

A successful `terraform apply tfplan` through the `omnivise-iot-deployer`
identity is the evidence that the `homelab-platform#42` RBAC is sufficient for
the approved Terraform lifecycle.

If apply fails on a genuinely missing permission:

- STOP;
- collect the exact denied API operation (group/version/kind/verb/namespace);
- reassess `AldrionDev/homelab-platform#42`;
- do not rerun using cluster-admin;
- do not grant an ad-hoc wildcard permission.

---

## 13. Kubernetes resource verification

Verification category: KUBERNETES. Use named `get` checks in namespace
`omnivise-iot`. Do not broaden the deployer identity to gain generic
Pod/list/watch access; use the operator kubeconfig where a check needs more.

```bash
kubectl -n omnivise-iot get statefulset mongodb
kubectl -n omnivise-iot get job mongodb-bootstrap
kubectl -n omnivise-iot get deployment backend frontend sensor-simulator
kubectl -n omnivise-iot get service mongodb backend frontend
kubectl -n omnivise-iot get ingressroute omnivise-iot-frontend
```

Expected:

```text
statefulset/mongodb            1/1 ready
job/mongodb-bootstrap          Complete (succeeded)
deployment/backend             available, ready replicas 1/1
deployment/frontend            available, ready replicas 1/1
deployment/sensor-simulator    1/1 (Pod Running; no readiness probe by design)

service/mongodb                headless, CLUSTER-IP None, port 27017
service/backend                ClusterIP, port 8080
service/frontend               ClusterIP, port 80
(no Service for the simulator)

ingressroute/omnivise-iot-frontend
  entryPoint  web
  single route  Host(`omnivise-iot.homelab.home.arpa`)  ->  service frontend:80
```

The IngressRoute object name comes from `local.ingress_name` in
`infra/homelab/ingress.tf` (`omnivise-iot-frontend`); confirm it against that
file at review time.

---

## 14. Exact running image verification

Verification category: IMAGES.

```bash
kubectl -n omnivise-iot get deployment backend \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="backend")].image}'
kubectl -n omnivise-iot get deployment frontend \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="frontend")].image}'
kubectl -n omnivise-iot get deployment sensor-simulator \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="sensor-simulator")].image}'
```

Each value must equal exactly:

```text
${HOMELAB_REGISTRY}/omnivise-iot/backend:${GIT_SHA}
${HOMELAB_REGISTRY}/omnivise-iot/frontend:${GIT_SHA}
${HOMELAB_REGISTRY}/omnivise-iot/simulator:${GIT_SHA}
```

A different SHA, a `latest` tag, or any unapproved reference fails the smoke.

---

## 15. MongoDB replica-set verification

Verification category: MONGODB. Use the operator/admin kubeconfig. All commands
are read-only.

```bash
kubectl --kubeconfig "${OPERATOR_KUBECONFIG}" -n omnivise-iot \
  exec sts/mongodb -c mongodb -- \
  mongosh --quiet --eval 'rs.status()'
kubectl --kubeconfig "${OPERATOR_KUBECONFIG}" -n omnivise-iot \
  exec sts/mongodb -c mongodb -- \
  mongosh --quiet --eval 'db.hello()'
```

Expected:

```text
replica set name:        rs0
configured members:      exactly one
member name:             mongodb-0.mongodb.omnivise-iot.svc.cluster.local:27017
member state:            PRIMARY
mongod process:          running
bootstrap Job:           Complete
```

The stable member FQDN is derived in `infra/modules/application/mongodb.tf`
(`local.mongodb_member_host`); confirm it against that file at review time.

Forbidden during verification: `rs.initiate()`, `rs.reconfig()`, or any other
replica-set mutation.

---

## 16. MongoDB persistence verification

Verification category: MONGODB.

1. PVC check (operator kubeconfig):

   ```bash
   kubectl -n omnivise-iot get pvc data-mongodb-0
   ```

   Expected: `Bound`, storageClass `local-path`. The PVC name comes from the
   `volume_claim_template` metadata name `data` plus the StatefulSet Pod
   `mongodb-0`; the storage class comes from `local.mongodb_storage_class` in
   `infra/homelab/locals.tf`. Confirm both against the repo at review time.

2. After the simulator has produced data, capture non-sensitive evidence that
   the `omnivise_iot.sensor_readings` collection holds sensor data (document
   count and the latest `_id` or timestamp only; no raw payload/PII):

   ```bash
   kubectl --kubeconfig "${OPERATOR_KUBECONFIG}" -n omnivise-iot \
     exec sts/mongodb -c mongodb -- mongosh --quiet --eval \
     'db.getSiblingDB("omnivise_iot").sensor_readings.countDocuments()'
   ```

3. With explicit maintainer authorization (Human Gate sequence, gate 4),
   perform exactly ONE controlled Pod recreation:

   ```bash
   kubectl --kubeconfig "${OPERATOR_KUBECONFIG}" -n omnivise-iot delete pod mongodb-0
   ```

4. Wait for the StatefulSet to recreate `mongodb-0` and return it to `Ready`.
5. Verify `rs0` returns to PRIMARY (repeat section 15 read-only checks).
6. Verify the previously observed sensor data is still present (count is greater
   than or equal to the earlier count; earlier latest `_id`/timestamp still
   present).
7. Verify the same PVC `data-mongodb-0` stays bound to the StatefulSet.

Forbidden: deleting the PVC, the StatefulSet, or the namespace; reinitializing
the replica set; changing storage configuration. Any loss of previously observed
data fails the smoke.

---

## 17. Backend verification

The backend Deployment must be ready. Through an operator-approved path (a
port-forward with the operator kubeconfig, or an in-cluster `curl`), check:

```bash
kubectl --kubeconfig "${OPERATOR_KUBECONFIG}" -n omnivise-iot \
  port-forward deployment/backend 18080:8080 &
curl -sS http://127.0.0.1:18080/health
```

Expected healthy response. The backend route is
`app.get("/health", ctx -> ctx.json(new Response("status", "healthy")))` in
`backend/src/main/java/com/omnivise/Main.java`, where `Response` is
`record Response(String message, String version)`, so the serialized body is:

```text
{"message":"status","version":"healthy"}
```

The issue contract writes this as the shorthand `{"status":"healthy"}`; treat
"200 OK plus the healthy marker" as the acceptance signal and record the exact
observed body in the evidence.

The backend runs with `MONGO_URI=mongodb://mongodb:27017/?replicaSet=rs0`
(`local.mongo_uri` in `infra/modules/application/workloads.tf`). No MongoDB
credentials exist in this milestone; none may be printed.

---

## 18. Frontend verification

The frontend Deployment must be ready.

```bash
kubectl --kubeconfig "${OPERATOR_KUBECONFIG}" -n omnivise-iot \
  port-forward deployment/frontend 18081:80 &
curl -sS -i http://127.0.0.1:18081/
```

Expected: `200 OK` serving the SPA `index.html`.

Confirm the frontend is NOT configured with a hardcoded Docker-only DNS
resolver. Per `frontend/nginx.conf`, the resolver line is
`resolver ${NGINX_LOCAL_RESOLVERS} valid=10s;`, populated at container start
from `/etc/resolv.conf` by the official Nginx entrypoint
(`NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1` in `frontend/Dockerfile`). The upstream is
`http://${BACKEND_UPSTREAM}`, and the Kubernetes frontend Deployment sets
`BACKEND_UPSTREAM` to the backend Service FQDN
(`backend.omnivise-iot.svc.cluster.local:8080`, `local.frontend_backend_upstream`
in `infra/modules/application/workloads.tf`). No CoreDNS or `127.0.0.11`
address is baked in.

---

## 19. Hostname resolution

Verification category: NETWORK.

Canonical host: `omnivise-iot.homelab.home.arpa`.

Verify the operator workstation resolves it to the homelab host LAN IP:

```bash
getent hosts omnivise-iot.homelab.home.arpa
dig +short omnivise-iot.homelab.home.arpa
```

The platform provides wildcard dnsmasq for clients using the homelab DNS
service. If the operator workstation instead needs an `/etc/hosts` entry
equivalent to `<HOST_LAN_IP> omnivise-iot.homelab.home.arpa`:

- add it only after explicit maintainer approval (Human Gate sequence, gate 1);
- do not manage it through Terraform;
- do not commit the host LAN IP anywhere in the repository;
- record only that hostname resolution was established.

---

## 20. Traefik / HTTP verification

Verification category: NETWORK.

```bash
curl -sS -i http://omnivise-iot.homelab.home.arpa/
```

Expected: `200 OK` serving the SPA. Request path:

```text
Traefik (web entrypoint)  ->  frontend Service :80
```

Confirm there is no direct public route to the backend or to MongoDB: the
namespace must contain no extra IngressRoute, no Ingress, and no NodePort or
LoadBalancer Service.

```bash
kubectl -n omnivise-iot get ingressroute
kubectl -n omnivise-iot get ingress
kubectl -n omnivise-iot get svc -o wide
```

---

## 21. WebSocket verification

Verification category: E2E.

```bash
websocat ws://omnivise-iot.homelab.home.arpa/ws/sensors
```

Expected: the connection opens and stays open. Request path:

```text
Traefik  ->  frontend Nginx  (location /ws/)  ->  backend Service :8080
```

The backend route is `app.ws("/ws/sensors", ...)` in `Main.java`; the Nginx
`location /ws/` block in `frontend/nginx.conf` sets the `Upgrade` and
`Connection` headers and proxies to `http://${BACKEND_UPSTREAM}`.

Do not introduce a temporary direct backend ingress for the smoke.

---

## 22. Full sensor data-path verification

Verification category: E2E.

Prove that newly generated sensor data becomes visible through the externally
reachable frontend path:

```text
sensor-simulator
  -> omnivise_iot.sensor_readings  (MongoDB rs0 PRIMARY)
  -> MongoDB Change Stream
  -> backend
  -> WebSocket /ws/sensors
  -> frontend Nginx / browser
```

Acceptable evidence (at least one, correlated with freshly generated data):

- live WebSocket messages on `ws://omnivise-iot.homelab.home.arpa/ws/sensors`
  that correlate with newly written `sensor_readings` documents;
- visible live updates in the frontend UI over
  `http://omnivise-iot.homelab.home.arpa`;
- read-only backend/runtime evidence that the Change Stream is propagating new
  inserts.

The mere existence of the Pods is not sufficient.

---

## 23. ResourceQuota verification

```bash
kubectl --kubeconfig "${OPERATOR_KUBECONFIG}" -n omnivise-iot \
  get resourcequota -o yaml
```

Confirm the ResourceQuota is:

- present;
- platform-owned (from `AldrionDev/homelab-platform#41`);
- unchanged by this deployment.

Confirm the deployed workload stays within the approved allocation. The
`infra/modules/application/workloads.tf` header documents the expected footprint
(requests 650m CPU / 1152Mi, limits 1300m CPU / 2304Mi) against the platform
quota (requests 1000m CPU / 2048Mi, limits 2000m CPU / 4096Mi), so headroom
stays positive.

The deployment must not modify the ResourceQuota. Record non-sensitive quota
usage numbers in the Human Gate / PR evidence.

---

## 24. Cleanup

After success OR failure of the deployment transaction:

- delete the local plan file: `rm -f infra/homelab/tfplan`;
- securely remove temporary credential files created only for this smoke
  (for example `shred -u` or `rm -P`);
- keep the operator-managed `omnivise-iot-deployer` kubeconfig only per the
  approved platform handoff policy.

Do NOT, after a successful milestone smoke:

- delete the application infrastructure;
- delete the published exact-SHA images;
- delete MongoDB data.

The successful end state is a running OmniVise deployment on the homelab
cluster, not a rolled-back empty namespace.

---

## 25. Failure / stop conditions

Stop immediately, and leave the corresponding Human Gate unresolved, on any of:

- partial image presence, or an unexpected Registry V2 response, at precheck or
  post-push (sections 3, 5);
- a saved plan containing an unexpected delete/replace, a cross-project change,
  or a privilege-scope expansion (section 9);
- `terraform apply` failing on a genuinely missing permission (section 12) with
  no cluster-admin fallback;
- `rs0` not returning to PRIMARY after the one controlled Pod recreation
  (section 16);
- any previously observed sensor data being lost after the Pod recreation
  (section 16);
- the HTTP, WebSocket, or full data-path flow failing (sections 20-22).

On any required live-verification failure, the final live-smoke acceptance Human
Gate stays unresolved. Never mark a failed smoke as passed by editing evidence
text, and never edit this reviewed runbook to record a live result.

---

## Evidence capture requirements (non-sensitive)

Record the following in the Human Gate records / PR evidence, not in this file.

```text
SOURCE
  separate clean deployment source checkout confirmed (path noted out-of-band)
  git status --porcelain empty
  git rev-parse HEAD = GIT_SHA
  H5 issue worktree explicitly NOT used as build context

REGISTRY
  backend  exact-SHA manifest present + registry-reported digest
  frontend exact-SHA manifest present + registry-reported digest
  simulator exact-SHA manifest present + registry-reported digest
  precheck outcome (all-absent build / all-present reuse)

TERRAFORM
  workspace = omnivise-iot-k8s
  execution mode = Local
  deployer identity + context confirmed (auth whoami)
  terraform fmt -check PASS
  terraform init PASS
  terraform validate PASS
  saved plan inspected; only the approved address set changes
  maintainer plan approval recorded
  terraform apply tfplan succeeded with the deployer identity

KUBERNETES
  statefulset/mongodb ready
  job/mongodb-bootstrap Complete
  deployment/backend ready
  deployment/frontend ready
  deployment/sensor-simulator running
  service/mongodb (headless, None), service/backend (:8080), service/frontend (:80)
  ingressroute/omnivise-iot-frontend -> frontend:80 on entrypoint web
  no NodePort/LoadBalancer/extra ingress in the namespace

MONGODB
  replica set name rs0
  exactly one configured member
  member name = mongodb-0.mongodb.omnivise-iot.svc.cluster.local:27017
  member state PRIMARY
  PVC data-mongodb-0 Bound, storageClass local-path
  data count / latest id before the controlled Pod recreation
  rs0 back to PRIMARY after recreation
  data count / latest id after recreation (no loss)
  same PVC still bound

IMAGES
  backend  running image = ${HOMELAB_REGISTRY}/omnivise-iot/backend:${GIT_SHA}
  frontend running image = ${HOMELAB_REGISTRY}/omnivise-iot/frontend:${GIT_SHA}
  simulator running image = ${HOMELAB_REGISTRY}/omnivise-iot/simulator:${GIT_SHA}

NETWORK
  omnivise-iot.homelab.home.arpa resolves on the operator workstation
  http://omnivise-iot.homelab.home.arpa/ returns 200 SPA
  backend not directly exposed
  MongoDB not externally exposed

E2E
  ws://omnivise-iot.homelab.home.arpa/ws/sensors connects and stays open
  newly generated sensor events observed through the frontend path
  simulator -> MongoDB -> Change Stream -> backend -> WebSocket -> frontend proven
```

---

## Secrets - never commit

The following must never appear in this document or anywhere else in the
repository:

- a real HCP Terraform token;
- kubeconfig content (any cluster, user, or token entry);
- a Kubernetes bearer token or client certificate/key;
- Terraform state (`*.tfstate`, `*.tfstate.backup`, state snapshots);
- a Terraform plan file (`tfplan` or any saved plan);
- a local registry credential;
- any machine-specific secret;
- the homelab host LAN IP used as application configuration.

This document contains only placeholder names and command templates.

---

## Human Gate sequence (in order)

These map to the issue's "Human Gates / Maintainer Decisions" list and must be
resolved in this order.

1. Prerequisites and start authorization. Maintainer confirms every prerequisite
   OmniVise issue (#33-#39) is merged, both `homelab-platform#41` and `#42` are
   merged AND applied, the HCP workspace `omnivise-iot-k8s` is ready in Local
   execution mode, the least-privilege `omnivise-iot-deployer` kubeconfig is
   available, and the deployment source is a separate clean checkout/worktree at
   the intended merged `main` SHA rather than the H5 issue worktree. Maintainer
   also explicitly authorizes any required operator-host name-resolution change
   (for example adding `<HOST_LAN_IP> omnivise-iot.homelab.home.arpa` to
   `/etc/hosts`). No machine-specific IP or credential may be committed.

2. Registry publish authorization. Maintainer reviews the Registry V2 write-once
   precheck and authorizes publishing the three exact-SHA images ONLY when all
   three are absent. If all three already exist, they are reused. Partial
   presence or an unexpected registry response fails closed and this gate stays
   unresolved.

3. Saved plan approval. Maintainer reviews the saved Terraform plan, confirms
   the exact Git-SHA image references, OmniVise-only application resource
   changes, an unchanged platform Namespace / ResourceQuota / RBAC, and no
   unexpected delete/replace action, then explicitly approves applying that
   exact saved plan with the `omnivise-iot-deployer` identity.

4. Live verification transaction authorization. Maintainer explicitly authorizes
   the bounded post-apply live verification, including operator-only deep
   MongoDB inspection and exactly one controlled MongoDB Pod recreation for the
   persistence proof. This authorization is resolved before the Pod recreation
   or any other intentional live-verification mutation begins.

5. Final acceptance. Maintainer reviews the completed live-verification evidence
   and accepts the homelab smoke only after all of the following are proven:
   `rs0` PRIMARY recovery after the controlled Pod recreation; previously
   observed persisted sensor data still present; HTTP access to the frontend;
   live WebSocket sensor events; ResourceQuota compatibility; exact running
   image references; and the full
   simulator -> MongoDB -> Change Stream -> backend -> WebSocket -> frontend
   data flow. If any required live verification fails, this gate stays
   unresolved.

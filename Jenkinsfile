// OmniVise IoT homelab delivery pipeline — exact-SHA image build, homelab
// registry publication, a gated Terraform deployment to the homelab k3s
// target, and bounded non-destructive post-deploy smoke verification
// (Homelab Delivery milestone, issues #60, #61 and #62).
//
// Flow: checkout / identify revision -> homelab preflight -> write-once
// release-set precheck -> (BUILD path only) build all three images once ->
// publish all three exact-SHA tags with post-push Registry V2 digest
// verification -> Terraform init / validate / fmt-check against infra/homelab
// -> one saved Terraform plan -> pre-approval evidence -> human approval gate
// -> apply of that exact saved plan -> post-deploy smoke (bounded, read-only:
// workload readiness, exact running-image equality, ResourceQuota
// compatibility, canonical HTTP reachability, a fresh-event WebSocket data-path
// proof, and a deployer-safe MongoDB rs0 health signal). A failed apply or an
// aborted approval interrupts the pipeline before the smoke stage starts.
//
// Explicitly NOT in this milestone (see
// docs/architecture/delivery-architecture.md): the destructive #40 MongoDB
// pod-recreation persistence proof (delivery-architecture section 18),
// rollback automation, AWS / EKS / ECR, GitHub-to-AWS OIDC, `DEPLOY_TARGET=aws`
// or `both`, any AWS Terraform apply, and any Kubernetes mutation against EKS.
// The post-deploy smoke never mutates the cluster, the application, MongoDB,
// the registry or Terraform state. There is no separate PUSH_TARGET
// parameter — DEPLOY_TARGET alone controls both publication and deployment.
//
// Issue #121 additionally publishes the same exact-SHA release set to GHCR
// (ghcr.io/aldriondev/omnivise-iot-<component>:<git-sha>), reusing the same
// write-once / build-once / fail-closed contract as the homelab registry.
// GHCR publication is gated behind a temporary, narrowly-scoped boolean
// parameter, ENABLE_GHCR_VERIFICATION (default false) — see its declaration
// below. That parameter never selects a Terraform root, never triggers an AWS
// apply, and never causes any Kubernetes mutation; it exists only to prove the
// GHCR write-once/build-once/fail-closed mechanism ahead of issue #122, which
// removes it once `DEPLOY_TARGET=aws|both` becomes authoritative and drives
// GHCR publication directly. The GHCR Registry V2 Bearer-token probe/verify
// logic lives in `.github/scripts/ghcr-manifest-probe.sh`, shared between this
// pipeline and the manual partial-state verification procedure documented in
// docs/ghcr-release-set-verification.md.
//
// This repository owns build + publication intent only. The Jenkins runtime,
// the shared `homelab-preflight` capability, and the local homelab registry
// authority (HOMELAB_REGISTRY, host:port, plain HTTP) are owned by
// local-jenkins-platform. No host IP is hard-coded here.
//
// Canonical image contract (docs/homelab-deployment-smoke.md section 2):
//   ${HOMELAB_REGISTRY}/omnivise-iot/backend:<git-sha>
//   ${HOMELAB_REGISTRY}/omnivise-iot/frontend:<git-sha>
//   ${HOMELAB_REGISTRY}/omnivise-iot/simulator:<git-sha>
// Naming asymmetry is intentional and must not be "aligned": the registry path
// segment is `simulator`, the build context directory is `simulators/`, and the
// Kubernetes workload is `sensor-simulator`.
//
// Approved GHCR image contract (issue #121):
//   ghcr.io/aldriondev/omnivise-iot-backend:<git-sha>
//   ghcr.io/aldriondev/omnivise-iot-frontend:<git-sha>
//   ghcr.io/aldriondev/omnivise-iot-simulator:<git-sha>
// Flat package names, no nested `aldriondev/omnivise-iot/<component>` path —
// this is the approved naming decision, not an oversight.

pipeline {
    agent any

    parameters {
        // Only `homelab` is implemented in this milestone. `aws` and `both`
        // are deliberately absent until the future AWS EKS milestone.
        choice(
            name: 'DEPLOY_TARGET',
            choices: ['homelab'],
            description: 'Delivery target. Only "homelab" is supported in this milestone.'
        )
        // Temporary, issue-#121-scoped verification scaffolding — NOT a second
        // permanent target selector. Its only effect is enabling the GHCR
        // precheck/publish stages below. It never changes DEPLOY_TARGET, never
        // selects an AWS Terraform root, never triggers a Terraform apply, and
        // never causes any Kubernetes mutation. Issue #122 deletes this
        // parameter once DEPLOY_TARGET=aws|both becomes authoritative and
        // drives GHCR publication directly.
        booleanParam(
            name: 'ENABLE_GHCR_VERIFICATION',
            defaultValue: false,
            description: 'Temporary #121 scaffolding: also run the GHCR release-set precheck/publish. Removed by #122.'
        )
    }

    options {
        // Single-writer trust model: never overlap two runs writing the same
        // omnivise-iot/* exact-SHA tags.
        disableConcurrentBuilds()
        // No global pipeline timeout: every stage below carries its own bounded
        // timeout, so the pipeline still always fails closed instead of
        // hanging, without an outer clock that could expire mid-build,
        // mid-publish, mid-apply, or — worst — while a human is deciding at the
        // approval gate. The Terraform plan and apply steps are each bounded on
        // their own; the approval `input` deliberately carries no timeout
        // (delivery-architecture sections 13 and 20: no clock may race the
        // human-approval window, and neither the architecture nor the reference
        // pipeline mandates one here).
        // No timestamps() / cleanWs(): not part of the confirmed
        // local-jenkins-platform plugin baseline. Workspace cleanup below uses
        // Pipeline-native deleteDir().
    }

    environment {
        // host:port of the plain-HTTP local homelab registry, supplied by the
        // local-jenkins-platform container environment. Never hard-coded.
        REGISTRY   = "${env.HOMELAB_REGISTRY}"
        // Canonical registry repository prefix; the component segment
        // (backend | frontend | simulator) is appended per image.
        IMAGE_REPO = 'omnivise-iot'

        // GHCR is a fixed public registry, not a homelab runtime detail — these
        // are literals, not platform-supplied (issue #121).
        GHCR_REGISTRY  = 'ghcr.io'
        GHCR_NAMESPACE = 'aldriondev'

        // Terraform root for the homelab target. One literal HCP Terraform
        // workspace per target (delivery-architecture sections 11 and 24); the
        // workspace name "omnivise-iot-k8s" and HCP Local execution mode are
        // pinned by the cloud block in infra/homelab/versions.tf.
        // TF_CLOUD_ORGANIZATION is supplied by the local-jenkins-platform
        // container environment and is never committed here.
        TF_ROOT = 'infra/homelab'

        // Documented least-privilege homelab deployer kubeconfig context
        // (docs/homelab-deployment-smoke.md sections 7-8; delivery-architecture
        // section 14). Not a secret. Passed to Terraform as
        // var.kubernetes_context and frozen into the saved plan, so the approved
        // plan applies against exactly this identity. The onboarded
        // k3s-omnivise-iot Secret File credential must define this context.
        TF_VAR_kubernetes_context = 'omnivise-iot-deployer'

        // Post-deploy smoke targets (issue #62). These literals mirror the
        // Terraform source of truth: KUBE_NAMESPACE is local.namespace in
        // infra/homelab/locals.tf and INGRESS_HOST is the var.ingress_host
        // default in infra/homelab/variables.tf. Jenkins cannot import Terraform
        // locals and kubectl needs a literal namespace, so they are restated
        // once here rather than scattered as inline literals in the smoke stage.
        KUBE_NAMESPACE = 'omnivise-iot'
        INGRESS_HOST   = 'omnivise-iot.homelab.home.arpa'
    }

    stages {
        stage('Checkout & identify revision') {
            options { timeout(time: 5, unit: 'MINUTES') }
            steps {
                script {
                    // Only the homelab target is wired in this milestone. The
                    // choice list already constrains the value; this guard
                    // fails closed if a future edit adds a choice without
                    // wiring its publication branch.
                    if (params.DEPLOY_TARGET != 'homelab') {
                        error "Unsupported DEPLOY_TARGET '${params.DEPLOY_TARGET}': only 'homelab' is implemented in this milestone."
                    }

                    // Fail closed before constructing any image reference:
                    // REGISTRY comes from the platform-supplied HOMELAB_REGISTRY
                    // container env var. Validate that original source directly
                    // — an unset value stringifies to the literal "null" in the
                    // declarative `REGISTRY = "${env.HOMELAB_REGISTRY}"`
                    // assignment above, so checking env.REGISTRY alone would not
                    // catch it. An unset or empty value must stop the build
                    // rather than yield a malformed "/omnivise-iot/backend:<sha>"
                    // reference downstream. REGISTRY stays the frozen value used
                    // by every later stage.
                    if (!env.HOMELAB_REGISTRY?.trim()) {
                        error 'HOMELAB_REGISTRY is unset or empty — cannot construct image references.'
                    }

                    // Exact checked-out revision. The multibranch job has
                    // already performed the SCM checkout before this stage;
                    // this only records the revision and freezes release
                    // identity.
                    env.GIT_SHA = sh(returnStdout: true, script: 'git rev-parse HEAD').trim()
                    if (!(env.GIT_SHA ==~ /^[0-9a-f]{40}$/)) {
                        error "Unexpected git revision format: '${env.GIT_SHA}' (expected exactly 40 lowercase hex characters)."
                    }

                    // Release identity frozen once. Every later stage reads
                    // these back as plain shell-expanded env vars inside
                    // single-quoted sh blocks — never recomputed, never
                    // re-derived from a mutable ref.
                    env.BACKEND_IMAGE   = "${env.REGISTRY}/${env.IMAGE_REPO}/backend:${env.GIT_SHA}"
                    env.FRONTEND_IMAGE  = "${env.REGISTRY}/${env.IMAGE_REPO}/frontend:${env.GIT_SHA}"
                    env.SIMULATOR_IMAGE = "${env.REGISTRY}/${env.IMAGE_REPO}/simulator:${env.GIT_SHA}"

                    // GHCR refs (issue #121). Computed unconditionally — cheap
                    // string construction, no side effect — but only consumed
                    // downstream when ENABLE_GHCR_VERIFICATION is true.
                    env.GHCR_BACKEND_IMAGE   = "${env.GHCR_REGISTRY}/${env.GHCR_NAMESPACE}/omnivise-iot-backend:${env.GIT_SHA}"
                    env.GHCR_FRONTEND_IMAGE  = "${env.GHCR_REGISTRY}/${env.GHCR_NAMESPACE}/omnivise-iot-frontend:${env.GIT_SHA}"
                    env.GHCR_SIMULATOR_IMAGE = "${env.GHCR_REGISTRY}/${env.GHCR_NAMESPACE}/omnivise-iot-simulator:${env.GIT_SHA}"

                    // Default when the GHCR precheck stage does not run at all
                    // (ENABLE_GHCR_VERIFICATION=false) — SKIPPED is treated
                    // identically to REUSE by the artifact-source decision
                    // below: it never forces a build or pull on its own.
                    env.GHCR_RELEASE_ACTION = 'SKIPPED'

                    echo "Deploy target:   ${params.DEPLOY_TARGET}"
                    echo "Revision:        ${env.GIT_SHA}"
                    echo "Backend image:   ${env.BACKEND_IMAGE}"
                    echo "Frontend image:  ${env.FRONTEND_IMAGE}"
                    echo "Simulator image: ${env.SIMULATOR_IMAGE}"
                    if (params.ENABLE_GHCR_VERIFICATION) {
                        echo "GHCR backend:    ${env.GHCR_BACKEND_IMAGE}"
                        echo "GHCR frontend:   ${env.GHCR_FRONTEND_IMAGE}"
                        echo "GHCR simulator:  ${env.GHCR_SIMULATOR_IMAGE}"
                    }
                }
            }
        }

        stage('Homelab preflight') {
            options { timeout(time: 15, unit: 'MINUTES') }
            steps {
                // Shared local-jenkins-platform capability. Non-mutating,
                // bounded, fails closed (non-zero) before any registry work if
                // the registry, the host Docker registry-trust, or the homelab
                // substrate are not ready. Do not reimplement its connectivity
                // or retry logic here.
                sh 'homelab-preflight'
            }
        }

        stage('Release-set write-once precheck (homelab)') {
            options { timeout(time: 5, unit: 'MINUTES') }
            steps {
                // The three OmniVise images are one release set for the exact
                // Git SHA. The local registry does not enforce tag
                // immutability — a plain `docker push` to an existing tag would
                // overwrite it — so write-once is pipeline-enforced under the
                // trusted single-writer model (`main` only, this controller the
                // sole writer to omnivise-iot/*).
                //
                // Existence is probed directly against the Docker Registry HTTP
                // API V2 over plain HTTP, not via `docker manifest inspect`
                // (which does not inherit the daemon insecure-registry config).
                //
                // OCI-aware Accept: OmniVise #40 proved that a Docker-v2-only
                // manifest Accept header can return a false 404 for an existing
                // OCI manifest. The probe therefore advertises the OCI index /
                // OCI manifest and the Docker manifest-list / Docker v2 media
                // types together, matching the proven runbook behavior.
                script {
                    env.HOMELAB_RELEASE_ACTION = sh(
                        returnStdout: true,
                        script: '''
                            set -eu
                            set +x

                            probe() {
                                curl -sS --max-time 15 -o /dev/null -w '%{http_code}' \
                                    -H 'Accept: application/vnd.oci.image.index.v1+json' \
                                    -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
                                    -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
                                    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
                                    "http://$REGISTRY/v2/$IMAGE_REPO/$1/manifests/$GIT_SHA"
                            }

                            backend_code=$(probe backend)
                            frontend_code=$(probe frontend)
                            simulator_code=$(probe simulator)

                            if [ "$backend_code" = "200" ] && [ "$frontend_code" = "200" ] && [ "$simulator_code" = "200" ]; then
                                echo "REUSE"
                            elif [ "$backend_code" = "404" ] && [ "$frontend_code" = "404" ] && [ "$simulator_code" = "404" ]; then
                                echo "BUILD"
                            else
                                # Partial / mixed presence, or any non-200/404
                                # response (including a transport failure caught
                                # by `set -e` above): fail closed rather than
                                # guess, overwrite, or repair.
                                echo "release-set precheck failed closed: backend=$backend_code frontend=$frontend_code simulator=$simulator_code" >&2
                                exit 1
                            fi
                        '''
                    ).trim()
                    echo "Homelab release-set precheck: ${env.HOMELAB_RELEASE_ACTION}"
                }
            }
        }

        stage('Release-set write-once precheck (GHCR)') {
            // Temporary #121 scaffolding gate — see the ENABLE_GHCR_VERIFICATION
            // parameter declaration above. Independent of the homelab precheck:
            // homelab and GHCR can each independently be BUILD or REUSE.
            when { expression { return params.ENABLE_GHCR_VERIFICATION } }
            options { timeout(time: 5, unit: 'MINUTES') }
            steps {
                withCredentials([
                    usernamePassword(
                        credentialsId: 'ghcr-omnivise-iot-publisher',
                        usernameVariable: 'GHCR_USERNAME',
                        passwordVariable: 'GHCR_TOKEN'
                    )
                ]) {
                    script {
                        // Delegates to the shared, spike-validated Registry V2
                        // Bearer-token probe script (.github/scripts/
                        // ghcr-manifest-probe.sh) — the single source of truth
                        // also used for post-push verification below and for
                        // the manual partial-state verification procedure in
                        // docs/ghcr-release-set-verification.md. A per-component
                        // probe failure (auth/transport/unexpected response)
                        // exits non-zero under `set -eu` immediately, with its
                        // own diagnostic already printed by the script.
                        env.GHCR_RELEASE_ACTION = sh(
                            returnStdout: true,
                            script: '''
                                set -eu
                                set +x

                                probe() {
                                    sh .github/scripts/ghcr-manifest-probe.sh precheck "$1" "$GIT_SHA" \
                                        | sed -n 's/^STATUS=//p'
                                }

                                backend_status=$(probe omnivise-iot-backend)
                                frontend_status=$(probe omnivise-iot-frontend)
                                simulator_status=$(probe omnivise-iot-simulator)

                                if [ "$backend_status" = "PRESENT" ] && [ "$frontend_status" = "PRESENT" ] && [ "$simulator_status" = "PRESENT" ]; then
                                    echo "REUSE"
                                elif [ "$backend_status" = "ABSENT" ] && [ "$frontend_status" = "ABSENT" ] && [ "$simulator_status" = "ABSENT" ]; then
                                    echo "BUILD"
                                else
                                    echo "GHCR release-set precheck failed closed: backend=$backend_status frontend=$frontend_status simulator=$simulator_status" >&2
                                    exit 1
                                fi
                            '''
                        ).trim()
                        echo "GHCR release-set precheck: ${env.GHCR_RELEASE_ACTION}"
                    }
                }
            }
        }

        stage('Determine artifact source') {
            // Separates "does a local image artifact need to be produced, and
            // how" from "does this registry need publishing" (issue #121).
            // Artifact identity must be symmetric: neither registry ever
            // rebuilds the exact Git SHA merely because it personally lacks
            // the tag while the OTHER registry already has a proven artifact
            // for that same SHA — the existing artifact is pulled and
            // retagged instead, in whichever direction is needed.
            //
            // Required matrix:
            //   homelab BUILD + GHCR BUILD  -> BUILD          (build once, both consume it)
            //   homelab REUSE + GHCR BUILD  -> HOMELAB_REUSE  (pull homelab -> retag for GHCR)
            //   homelab BUILD + GHCR REUSE  -> GHCR_REUSE     (pull GHCR -> retag for homelab)
            //   homelab REUSE + GHCR REUSE  -> NONE           (nothing to do)
            //
            // GHCR_RELEASE_ACTION == 'SKIPPED' (ENABLE_GHCR_VERIFICATION=false)
            // is deliberately NOT treated as GHCR needing REUSE-sourcing —
            // GHCR is not participating in the run at all, so a homelab BUILD
            // with GHCR skipped falls through to the plain BUILD branch,
            // identical to pre-#121 behavior.
            options { timeout(time: 1, unit: 'MINUTES') }
            steps {
                script {
                    if (env.HOMELAB_RELEASE_ACTION == 'BUILD' && env.GHCR_RELEASE_ACTION == 'BUILD') {
                        env.ARTIFACT_SOURCE = 'BUILD'
                    } else if (env.HOMELAB_RELEASE_ACTION == 'REUSE' && env.GHCR_RELEASE_ACTION == 'BUILD') {
                        env.ARTIFACT_SOURCE = 'HOMELAB_REUSE'
                    } else if (env.HOMELAB_RELEASE_ACTION == 'BUILD' && env.GHCR_RELEASE_ACTION == 'REUSE') {
                        env.ARTIFACT_SOURCE = 'GHCR_REUSE'
                    } else if (env.HOMELAB_RELEASE_ACTION == 'BUILD') {
                        // GHCR_RELEASE_ACTION == 'SKIPPED': plain homelab-only
                        // build, exactly today's behavior.
                        env.ARTIFACT_SOURCE = 'BUILD'
                    } else {
                        // HOMELAB_RELEASE_ACTION == 'REUSE' and
                        // GHCR_RELEASE_ACTION in {REUSE, SKIPPED}: nothing to
                        // build, pull, or publish anywhere.
                        env.ARTIFACT_SOURCE = 'NONE'
                    }
                    echo "Artifact source: ${env.ARTIFACT_SOURCE}"
                }
            }
        }

        stage('Build images') {
            // ARTIFACT_SOURCE == 'BUILD' only when both registries need the
            // same fresh build (or GHCR verification is off and homelab needs
            // one). Whenever only one registry needs BUILD and the other
            // already has a proven exact-SHA artifact, that artifact is
            // pulled and retagged instead — see 'Acquire GHCR source
            // artifact' and 'Acquire homelab source artifact from GHCR'
            // below (issue #121: build-once, symmetric across both
            // registries).
            when { environment name: 'ARTIFACT_SOURCE', value: 'BUILD' }
            options { timeout(time: 20, unit: 'MINUTES') }
            steps {
                // Each image is built exactly once from the checked-out
                // workspace using the repository Dockerfiles and their
                // existing build contract. Not rebuilt later, and never
                // rebuilt merely to publish to a second registry — GHCR
                // publication (when needed) retags this same local artifact.
                //
                // frontend takes NO --build-arg: frontend/Dockerfile declares
                // no ARG, and Vite reads frontend/.env.production
                // (VITE_API_URL=/api) from the build context at `npm run
                // build`. The HomeStreamLab SPA build-arg pattern deliberately
                // does not apply to OmniVise.
                sh '''
                    set -eu
                    docker build -f backend/Dockerfile    -t "$BACKEND_IMAGE"   backend
                    docker build -f frontend/Dockerfile   -t "$FRONTEND_IMAGE"  frontend
                    docker build -f simulators/Dockerfile -t "$SIMULATOR_IMAGE" simulators
                '''
            }
        }

        stage('Acquire GHCR source artifact') {
            // Homelab REUSE + GHCR BUILD only (issue #121). Never rebuilds the
            // exact Git SHA — a rebuild can legitimately produce a different
            // manifest digest for the same commit (base image updates,
            // timestamps, package-repository drift). Instead, pull the
            // already-published, already-proven homelab exact-SHA images and
            // publish that same pulled local image artifact to GHCR in
            // 'Publish images (GHCR)', without rebuilding. Cross-registry
            // manifest digests are traceability evidence only — they may
            // legitimately differ and are never asserted equal.
            when { environment name: 'ARTIFACT_SOURCE', value: 'HOMELAB_REUSE' }
            options { timeout(time: 10, unit: 'MINUTES') }
            steps {
                sh '''
                    set -eu
                    docker pull "$BACKEND_IMAGE"
                    docker pull "$FRONTEND_IMAGE"
                    docker pull "$SIMULATOR_IMAGE"
                '''
                script {
                    // Traceability evidence only (issue #121 review finding):
                    // logged for the digest comparison in 'Publish images
                    // (GHCR)', never used to fail the build on its own —
                    // cross-registry manifest digest equality is evidence, not
                    // a hard invariant.
                    env.SOURCE_BACKEND_DIGEST   = sh(returnStdout: true, script: 'docker inspect --format="{{index .RepoDigests 0}}" "$BACKEND_IMAGE"').trim()
                    env.SOURCE_FRONTEND_DIGEST  = sh(returnStdout: true, script: 'docker inspect --format="{{index .RepoDigests 0}}" "$FRONTEND_IMAGE"').trim()
                    env.SOURCE_SIMULATOR_DIGEST = sh(returnStdout: true, script: 'docker inspect --format="{{index .RepoDigests 0}}" "$SIMULATOR_IMAGE"').trim()
                    echo "Pulled homelab exact-SHA artifacts as the GHCR publish source (no rebuild):"
                    echo "  backend:   ${env.SOURCE_BACKEND_DIGEST}"
                    echo "  frontend:  ${env.SOURCE_FRONTEND_DIGEST}"
                    echo "  simulator: ${env.SOURCE_SIMULATOR_DIGEST}"
                }
            }
        }

        stage('Acquire homelab source artifact from GHCR') {
            // Homelab BUILD + GHCR REUSE only (issue #121 review finding:
            // artifact identity must be symmetric with 'Acquire GHCR source
            // artifact' above). GHCR already has the exact-SHA release set;
            // do not rebuild it for homelab. Pull the existing GHCR images
            // and retag them to the canonical homelab refs — 'Publish images
            // (homelab)' then pushes that same pulled local image artifact,
            // without rebuilding, completely unchanged from its existing
            // behavior otherwise. No Kubernetes/Terraform/AWS behavior is
            // introduced here. Cross-registry manifest digests are
            // traceability evidence only — they may legitimately differ.
            when { environment name: 'ARTIFACT_SOURCE', value: 'GHCR_REUSE' }
            options { timeout(time: 10, unit: 'MINUTES') }
            steps {
                withCredentials([
                    usernamePassword(
                        credentialsId: 'ghcr-omnivise-iot-publisher',
                        usernameVariable: 'GHCR_USERNAME',
                        passwordVariable: 'GHCR_TOKEN'
                    )
                ]) {
                    sh '''
                        set -eu
                        set +x

                        DOCKER_CONFIG="$(mktemp -d)"
                        export DOCKER_CONFIG
                        trap 'rm -rf "$DOCKER_CONFIG"' EXIT

                        printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin

                        docker pull "$GHCR_BACKEND_IMAGE"
                        docker pull "$GHCR_FRONTEND_IMAGE"
                        docker pull "$GHCR_SIMULATOR_IMAGE"

                        docker tag "$GHCR_BACKEND_IMAGE"   "$BACKEND_IMAGE"
                        docker tag "$GHCR_FRONTEND_IMAGE"  "$FRONTEND_IMAGE"
                        docker tag "$GHCR_SIMULATOR_IMAGE" "$SIMULATOR_IMAGE"

                        docker logout ghcr.io
                    '''
                }
                script {
                    // Traceability evidence only, same discipline as the
                    // opposite direction above — not a hard cross-registry
                    // digest-equality invariant.
                    env.SOURCE_BACKEND_DIGEST   = sh(returnStdout: true, script: 'docker inspect --format="{{index .RepoDigests 0}}" "$GHCR_BACKEND_IMAGE"').trim()
                    env.SOURCE_FRONTEND_DIGEST  = sh(returnStdout: true, script: 'docker inspect --format="{{index .RepoDigests 0}}" "$GHCR_FRONTEND_IMAGE"').trim()
                    env.SOURCE_SIMULATOR_DIGEST = sh(returnStdout: true, script: 'docker inspect --format="{{index .RepoDigests 0}}" "$GHCR_SIMULATOR_IMAGE"').trim()
                    echo "Pulled GHCR exact-SHA artifacts as the homelab publish source (no rebuild):"
                    echo "  backend:   ${env.SOURCE_BACKEND_DIGEST}"
                    echo "  frontend:  ${env.SOURCE_FRONTEND_DIGEST}"
                    echo "  simulator: ${env.SOURCE_SIMULATOR_DIGEST}"
                }
            }
        }

        stage('Publish images (homelab)') {
            when { environment name: 'HOMELAB_RELEASE_ACTION', value: 'BUILD' }
            options { timeout(time: 10, unit: 'MINUTES') }
            steps {
                // BUILD path only. Under the write-once precheck this only ever
                // creates the three <git-sha> tags — it never re-pushes an
                // existing one.
                //
                // Partial-publication semantics: the pushes run in order and
                // `set -e` aborts the build on the first failure. Tags already
                // pushed are left in place — not deleted, not overwritten, not
                // repaired. A later run then sees a mixed release set and fails
                // closed at the precheck above.
                //
                // Post-push verification re-probes Registry V2 with the same
                // OCI-aware Accept and asserts, per component: the exact tag
                // exists, the response is HTTP 200, and a Docker-Content-Digest
                // header is present. The digest is logged for traceability
                // only; the deployment identity stays the Git-SHA tag, never
                // the digest.
                sh '''
                    set -eu
                    set +x

                    docker push "$BACKEND_IMAGE"
                    docker push "$FRONTEND_IMAGE"
                    docker push "$SIMULATOR_IMAGE"

                    verify_pushed() {
                        component="$1"
                        headers="$(mktemp)"
                        # Guarantee cleanup even when curl exits non-zero on a
                        # transport failure and `set -e` aborts before the
                        # explicit rm below. The script exits immediately after
                        # the verify_pushed calls, so an EXIT trap suffices; the
                        # success and HTTP != 200 paths still rm explicitly.
                        trap 'rm -f "$headers"' EXIT
                        http_code=$(curl -sS --max-time 15 -D "$headers" -o /dev/null -w '%{http_code}' \
                            -H 'Accept: application/vnd.oci.image.index.v1+json' \
                            -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
                            -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
                            -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
                            "http://$REGISTRY/v2/$IMAGE_REPO/$component/manifests/$GIT_SHA")
                        if [ "$http_code" != "200" ]; then
                            echo "post-push manifest check failed for $component: HTTP $http_code" >&2
                            rm -f "$headers"
                            exit 1
                        fi
                        digest=$(tr -d '\\r' < "$headers" | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}')
                        rm -f "$headers"
                        if [ -z "$digest" ]; then
                            echo "post-push manifest for $component has no Docker-Content-Digest header" >&2
                            exit 1
                        fi
                        echo "$component published: $IMAGE_REPO/$component:$GIT_SHA digest=$digest"
                    }

                    verify_pushed backend
                    verify_pushed frontend
                    verify_pushed simulator
                '''
            }
        }

        stage('Publish images (GHCR)') {
            // Temporary #121 scaffolding gate, plus GHCR's own BUILD state.
            // Runs whether the local artifact came from 'Build images' or
            // 'Acquire GHCR source artifact' (ARTIFACT_SOURCE == BUILD or
            // HOMELAB_REUSE) — by this point $BACKEND_IMAGE etc. exist locally
            // either way, so the tag/push steps below are identical.
            when {
                allOf {
                    expression { return params.ENABLE_GHCR_VERIFICATION }
                    environment name: 'GHCR_RELEASE_ACTION', value: 'BUILD'
                }
            }
            options { timeout(time: 10, unit: 'MINUTES') }
            steps {
                withCredentials([
                    usernamePassword(
                        credentialsId: 'ghcr-omnivise-iot-publisher',
                        usernameVariable: 'GHCR_USERNAME',
                        passwordVariable: 'GHCR_TOKEN'
                    )
                ]) {
                    // Only the exact-SHA tags — never a mutable alias.
                    // Partial-publication semantics mirror the homelab stage
                    // exactly: pushes run under `set -eu` in sequence; a
                    // mid-sequence failure leaves already-pushed tags in
                    // place — never deleted, never overwritten, never
                    // repaired. A later run's GHCR precheck then sees the
                    // mixed release set and fails closed. No `delete:packages`
                    // is ever required or used.
                    sh '''
                        set -eu
                        set +x

                        DOCKER_CONFIG="$(mktemp -d)"
                        export DOCKER_CONFIG
                        trap 'rm -rf "$DOCKER_CONFIG"' EXIT

                        printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin

                        docker tag "$BACKEND_IMAGE"   "$GHCR_BACKEND_IMAGE"
                        docker tag "$FRONTEND_IMAGE"  "$GHCR_FRONTEND_IMAGE"
                        docker tag "$SIMULATOR_IMAGE" "$GHCR_SIMULATOR_IMAGE"

                        docker push "$GHCR_BACKEND_IMAGE"
                        docker push "$GHCR_FRONTEND_IMAGE"
                        docker push "$GHCR_SIMULATOR_IMAGE"

                        verify_pushed() {
                            package="$1"
                            output=$(sh .github/scripts/ghcr-manifest-probe.sh verify "$package" "$GIT_SHA")
                            digest=$(printf '%s\\n' "$output" | sed -n 's/^DIGEST=//p')
                            echo "$package published: $GHCR_REGISTRY/$GHCR_NAMESPACE/$package:$GIT_SHA digest=$digest"
                        }

                        verify_pushed omnivise-iot-backend
                        verify_pushed omnivise-iot-frontend
                        verify_pushed omnivise-iot-simulator

                        docker logout ghcr.io
                    '''
                }
                script {
                    // Traceability evidence only (issue #121 review finding):
                    // cross-registry manifest digest equality is not asserted
                    // here — the invariant is "same local artifact, retagged,
                    // no rebuild," which is guaranteed by ARTIFACT_SOURCE
                    // above, not by comparing registry-reported digests.
                    if (env.ARTIFACT_SOURCE == 'HOMELAB_REUSE') {
                        echo 'GHCR publish source (pulled from homelab, no rebuild):'
                        echo "  backend:   ${env.SOURCE_BACKEND_DIGEST}"
                        echo "  frontend:  ${env.SOURCE_FRONTEND_DIGEST}"
                        echo "  simulator: ${env.SOURCE_SIMULATOR_DIGEST}"
                    }
                }
            }
        }

        stage('Release set ready') {
            options { timeout(time: 1, unit: 'MINUTES') }
            steps {
                // The exact-SHA release set is now available (built and
                // published, or reused) for every registry this run
                // considered. The gated Terraform deployment below consumes
                // exactly the homelab image references, and the post-deploy
                // smoke stage afterwards verifies that exactly those refs are
                // the ones running. GHCR status is independent and does not
                // affect Terraform/Kubernetes in any way.
                script {
                    if (env.HOMELAB_RELEASE_ACTION == 'REUSE') {
                        echo "Homelab REUSE: all three omnivise-iot exact-SHA images already present for ${env.GIT_SHA}; build and push skipped."
                    } else {
                        echo "Homelab BUILD: three omnivise-iot exact-SHA images published and verified for ${env.GIT_SHA}."
                    }
                    if (params.ENABLE_GHCR_VERIFICATION) {
                        if (env.GHCR_RELEASE_ACTION == 'REUSE') {
                            echo "GHCR REUSE: all three exact-SHA images already present in GHCR for ${env.GIT_SHA}; publish skipped."
                        } else {
                            echo "GHCR BUILD: three exact-SHA images published and verified to GHCR for ${env.GIT_SHA}."
                        }
                    } else {
                        echo 'GHCR verification disabled (ENABLE_GHCR_VERIFICATION=false); GHCR publication skipped.'
                    }
                }
            }
        }

        stage('Terraform init & validate') {
            options { timeout(time: 10, unit: 'MINUTES') }
            steps {
                dir(env.TF_ROOT) {
                    // terraform init needs the HCP token to configure the cloud
                    // backend (workspace omnivise-iot-k8s, HCP Local execution).
                    // TF_CLOUD_ORGANIZATION comes from the container
                    // environment. No kubeconfig is bound here — init, validate
                    // and fmt-check do not contact the cluster.
                    withCredentials([
                        string(credentialsId: 'hcp-terraform-cli', variable: 'TF_TOKEN_app_terraform_io')
                    ]) {
                        // Order per delivery-architecture section 10. init is
                        // non-interactive and treats the committed
                        // .terraform.lock.hcl as read-only, so lock drift fails
                        // the build instead of being silently rewritten
                        // (docs/homelab-deployment-smoke.md section 6). fmt uses
                        // the repository-supported recursive form from that same
                        // section.
                        sh '''
                            set -eu
                            set +x
                            terraform init -input=false -lockfile=readonly
                            terraform validate
                            terraform fmt -check -recursive ..
                        '''
                    }
                }
            }
        }

        stage('Homelab deploy (plan, approve, apply)') {
            steps {
                dir(env.TF_ROOT) {
                    // ONE k3s-omnivise-iot Secret File binding spans plan ->
                    // pre-approval evidence -> human approval -> saved-plan
                    // apply. The kubernetes provider resolves its kubeconfig
                    // from var.kubeconfig_path, whose concrete temporary path is
                    // frozen into the saved plan; re-binding the file for apply
                    // would place the kubeconfig at a different temp path and
                    // break `terraform apply tfplan`. Least-privilege deployer
                    // identity only — never an admin kubeconfig, never a
                    // cluster-admin fallback, never exposed outside this stage
                    // (delivery-architecture section 14).
                    withCredentials([
                        file(credentialsId: 'k3s-omnivise-iot', variable: 'KUBECONFIG')
                    ]) {
                        // Plan. The HCP token is bound only around plan creation
                        // and released before the human wait — applying a saved
                        // plan ignores TF_VAR_* for already-planned values and
                        // only needs the token again to write state and hold the
                        // state lock.
                        withCredentials([
                            string(credentialsId: 'hcp-terraform-cli', variable: 'TF_TOKEN_app_terraform_io')
                        ]) {
                            timeout(time: 10, unit: 'MINUTES') {
                                sh '''
                                    set -eu
                                    set +x
                                    # The three exact-SHA refs frozen in
                                    # 'Checkout & identify revision' — passed
                                    # verbatim, never recomputed, never
                                    # re-queried. var.kubernetes_context comes
                                    # from the declarative environment block.
                                    export TF_VAR_kubeconfig_path="$KUBECONFIG"
                                    export TF_VAR_backend_image_ref="$BACKEND_IMAGE"
                                    export TF_VAR_frontend_image_ref="$FRONTEND_IMAGE"
                                    export TF_VAR_simulator_image_ref="$SIMULATOR_IMAGE"
                                    # tfplan can embed the temporary kubeconfig
                                    # path and other sensitive values — restrict
                                    # its mode from creation (umask) and again
                                    # explicitly (chmod).
                                    umask 077
                                    terraform plan -input=false -lock-timeout=120s -out=tfplan
                                    chmod 600 tfplan
                                '''
                            }

                            // Pre-approval evidence: the release identity the
                            // operator is approving plus a read-only render of
                            // the exact saved plan. No second plan is created.
                            //
                            // DEPLOY_TARGET is a pipeline parameter, not part of
                            // the declarative environment block, so — unlike
                            // GIT_SHA and the *_IMAGE refs — it is not exported
                            // into sh steps automatically. Scope it explicitly to
                            // just this evidence shell from params.DEPLOY_TARGET;
                            // set -eu still fails closed on any other unset var.
                            timeout(time: 5, unit: 'MINUTES') {
                                withEnv(["DEPLOY_TARGET=${params.DEPLOY_TARGET}"]) {
                                    sh '''
                                        set -eu
                                        set +x
                                        echo "OmniVise homelab delivery — pre-approval evidence"
                                        echo "  Git SHA:         $GIT_SHA"
                                        echo "  DEPLOY_TARGET:   $DEPLOY_TARGET"
                                        echo "  Backend image:   $BACKEND_IMAGE"
                                        echo "  Frontend image:  $FRONTEND_IMAGE"
                                        echo "  Simulator image: $SIMULATOR_IMAGE"
                                        echo "  Terraform root:  infra/homelab"
                                        echo "  HCP workspace:   omnivise-iot-k8s"
                                        echo "  Saved plan:      infra/homelab/tfplan"
                                        echo
                                        echo "Saved Terraform plan (read-only; this exact plan is what apply consumes):"
                                        terraform show -no-color tfplan
                                    '''
                                }
                            }
                        }

                        // Human approval gate — after the saved plan and its
                        // evidence, before any apply. Approving authorises
                        // applying THIS saved plan for THIS Git SHA and THESE
                        // image refs. No automatic approval; no timeout (see the
                        // options block).
                        input(
                            message: "Apply the exact saved Terraform plan infra/homelab/tfplan to the OmniVise homelab k3s target?\n" +
                                     "DEPLOY_TARGET: homelab   HCP workspace: omnivise-iot-k8s\n" +
                                     "Git SHA:   ${env.GIT_SHA}\n" +
                                     "backend:   ${env.BACKEND_IMAGE}\n" +
                                     "frontend:  ${env.FRONTEND_IMAGE}\n" +
                                     "simulator: ${env.SIMULATOR_IMAGE}",
                            ok: 'Apply saved plan'
                        )

                        // Apply the SAVED plan only — no re-plan, no TF_VAR_*
                        // re-supplied for planned values. Only the HCP token is
                        // re-bound, to write state and hold the state lock.
                        withCredentials([
                            string(credentialsId: 'hcp-terraform-cli', variable: 'TF_TOKEN_app_terraform_io')
                        ]) {
                            timeout(time: 15, unit: 'MINUTES') {
                                sh '''
                                    set -eu
                                    set +x
                                    terraform apply -input=false -lock-timeout=120s tfplan
                                '''
                            }
                        }
                        // Stage boundary: a successful apply hands off to the
                        // 'Post-deploy smoke (non-destructive)' stage below.
                        // A failed apply fails the pipeline here and an aborted
                        // approval interrupts it above, so in both cases the
                        // smoke stage never starts.
                    }
                }
            }
        }

        stage('Post-deploy smoke (non-destructive)') {
            // Declarative pipeline only runs this stage when every earlier stage
            // succeeded, so it is reached exclusively after a successful
            // `terraform apply` (a failed apply fails the run; an aborted
            // approval interrupts it). Every check here is read-only against
            // both the cluster and the application: bounded `kubectl get` on
            // named resources, HTTP GET, and a WebSocket subscribe/listen.
            // There is no kubectl apply/patch/delete/create, no rollout
            // restart, no scale, no pod deletion, no database write, and no
            // Terraform or registry mutation. This closes the non-destructive
            // part of the #40 manual evidence loop (delivery-architecture
            // section 17); the destructive #40 MongoDB pod-recreation
            // persistence proof is deliberately NOT reproduced (section 18).
            options { timeout(time: 25, unit: 'MINUTES') }
            steps {
                // Cluster-facing checks reuse the SAME least-privilege
                // k3s-omnivise-iot Secret File credential as plan/apply, bound
                // only for this block and pinned to the omnivise-iot-deployer
                // context. Never an admin kubeconfig, never a cluster-admin
                // fallback, never exposed outside this stage. The deployer RBAC
                // has no pod list/watch and no exec/port-forward, so every read
                // below targets a single named resource — never `kubectl get
                // pods`, never a namespace- or cluster-wide list.
                withCredentials([
                    file(credentialsId: 'k3s-omnivise-iot', variable: 'KUBECONFIG')
                ]) {
                    timeout(time: 12, unit: 'MINUTES') {
                        sh '''
                            set -eu
                            set +x

                            kc() {
                                kubectl --kubeconfig "$KUBECONFIG" \
                                    --context "$TF_VAR_kubernetes_context" \
                                    --request-timeout=15s -n "$KUBE_NAMESPACE" "$@"
                            }

                            # --- Bounded workload readiness ------------------
                            # Single-resource reads only. Ready = all desired
                            # replicas Ready AND the controller has observed the
                            # current spec generation. A redeploy of an
                            # already-live commit is a valid Terraform no-op and
                            # still passes immediately.
                            deadline=$(( $(date +%s) + 600 ))

                            wait_ready() {
                                kind="$1"; name="$2"
                                while :; do
                                    out=$(kc get "$kind/$name" \
                                        -o jsonpath='{.spec.replicas}/{.status.readyReplicas}/{.status.observedGeneration}/{.metadata.generation}' \
                                        2>/dev/null || echo "")
                                    desired=$(echo "$out" | cut -d/ -f1)
                                    ready=$(echo "$out"   | cut -d/ -f2)
                                    seen=$(echo "$out"    | cut -d/ -f3)
                                    gen=$(echo "$out"     | cut -d/ -f4)
                                    if [ -n "$out" ] && [ -n "$ready" ] \
                                        && [ "$desired" = "$ready" ] \
                                        && [ "$seen" = "$gen" ]; then
                                        echo "$kind/$name: Ready ($ready/$desired)"
                                        return 0
                                    fi
                                    if [ "$(date +%s)" -ge "$deadline" ]; then
                                        echo "$kind/$name: not Ready within the bounded wait (last: '${out:-<none>}')" >&2
                                        return 1
                                    fi
                                    sleep 5
                                done
                            }

                            # MongoDB rs0 health without exec/port-forward: the
                            # StatefulSet readiness probe is
                            # `db.hello().isWritablePrimary`, so a Ready
                            # mongodb-0 means the sole rs0 member currently
                            # reports a writable PRIMARY. Issue #62 / runbook
                            # section 15 reserve a direct `rs.status()` for the
                            # separate operator identity; this pipeline must not
                            # add exec/port-forward to the deployer, and the
                            # fresh-event WebSocket check below is the
                            # end-to-end confirmation that rs0 is actually
                            # serving Change Stream traffic.
                            wait_ready statefulset mongodb
                            wait_ready deployment  backend
                            wait_ready deployment  frontend
                            wait_ready deployment  sensor-simulator

                            # --- Exact running-image verification -----------
                            # The live workload templates must run exactly the
                            # frozen release refs from 'Checkout & identify
                            # revision'. Deployed state is the proof, never
                            # registry state; the container-name jsonpath filter
                            # skips the mongodb-wait init container.
                            assert_image() {
                                dep="$1"; container="$2"; expected="$3"
                                live=$(kc get "deployment/$dep" \
                                    -o jsonpath="{.spec.template.spec.containers[?(@.name==\\"$container\\")].image}" \
                                    2>/dev/null || echo "")
                                if [ -z "$live" ]; then
                                    echo "$dep: could not read the running image for container '$container'" >&2
                                    exit 1
                                fi
                                case "$live" in
                                    *:latest)
                                        echo "$dep: running image uses a :latest tag ($live)" >&2
                                        exit 1 ;;
                                esac
                                if [ "$live" != "$expected" ]; then
                                    echo "$dep: image mismatch: live=$live expected=$expected" >&2
                                    exit 1
                                fi
                                echo "$dep: running image verified ($live)"
                            }

                            assert_image backend          backend          "$BACKEND_IMAGE"
                            assert_image frontend         frontend         "$FRONTEND_IMAGE"
                            assert_image sensor-simulator sensor-simulator "$SIMULATOR_IMAGE"

                            # --- ResourceQuota compatibility (read-only) ----
                            # The omnivise-iot ResourceQuota object is owned by
                            # homelab-platform#41 and, per runbook section 23, is
                            # readable only with the separate operator identity;
                            # the least-privilege deployer cannot read it and
                            # this issue does not widen that RBAC. The strongest
                            # least-privilege-safe evidence is that every
                            # workload above was admitted and reached its desired
                            # Ready replica count within the bounded wait: a pod
                            # rejected by the namespace ResourceQuota never
                            # becomes Ready, and `terraform apply` itself already
                            # succeeded. Re-assert that end state explicitly.
                            for target in statefulset/mongodb deployment/backend deployment/frontend deployment/sensor-simulator; do
                                qout=$(kc get "$target" -o jsonpath='{.spec.replicas}/{.status.readyReplicas}' 2>/dev/null || echo "")
                                if [ -z "$qout" ] || [ "$(echo "$qout" | cut -d/ -f1)" != "$(echo "$qout" | cut -d/ -f2)" ]; then
                                    echo "$target: not at desired Ready replicas ($qout) — cannot confirm ResourceQuota compatibility" >&2
                                    exit 1
                                fi
                            done
                            echo "ResourceQuota compatibility: PASS (indirect — all workloads admitted and Ready, no quota rejection; a direct ResourceQuota object read is not available to the least-privilege omnivise-iot-deployer identity and RBAC is not widened here)."
                        '''
                    }
                }

                // --- Canonical HTTP smoke --------------------------------
                // No kubeconfig needed. Bounded. Proves the public Traefik
                // route reaches the deployed application, not merely that
                // Traefik accepts TCP: `/` must return the frontend SPA shell
                // and `/api/sensors/latest` must return a JSON array proxied
                // frontend -> backend. Both are harmless reads defined in
                // frontend/nginx.conf and
                // backend/src/main/java/com/omnivise/Main.java.
                timeout(time: 3, unit: 'MINUTES') {
                    sh '''
                        set -eu
                        set +x

                        base="http://$INGRESS_HOST"
                        deadline=$(( $(date +%s) + 120 ))

                        # One response-body scratch file for the whole HTTP
                        # smoke. The EXIT trap removes it on every exit path —
                        # success, curl failure, the Jenkins timeout
                        # interrupting the shell, and any set -e failure — the
                        # same pattern the 'Publish images' stage uses. curl -o
                        # overwrites it each iteration, so one file suffices.
                        tmp=$(mktemp)
                        trap 'rm -f "$tmp"' EXIT

                        get_ok() {
                            path="$1"; needle="$2"
                            while :; do
                                code=$(curl -sS -m 10 -o "$tmp" -w '%{http_code}' "$base$path" 2>/dev/null || echo "000")
                                if [ "$code" = "200" ] && grep -q "$needle" "$tmp"; then
                                    echo "GET $path -> 200 (matched /$needle/)"
                                    return 0
                                fi
                                if [ "$(date +%s)" -ge "$deadline" ]; then
                                    echo "GET $path: no matching 200 within the bounded wait (last code: $code)" >&2
                                    return 1
                                fi
                                sleep 5
                            done
                        }

                        get_ok "/" 'id="root"'
                        get_ok "/api/sensors/latest?limit=1" '^\\['
                    '''
                }

                // --- WebSocket fresh-event data-path smoke ---------------
                // Proves the full simulator -> MongoDB rs0 -> Change Stream ->
                // backend -> /ws/sensors -> Traefik path, not just a WebSocket
                // handshake: it subscribes to the real public route and
                // requires a sensor event delivered DURING the connection
                // window (the backend broadcasts only to already-connected
                // clients), validated as a structurally valid OmniVise sensor
                // reading. Read-only — it never writes to the cluster, the API
                // or MongoDB, and never restarts the simulator or backend. The
                // client is a pinned throwaway Node image (Node 22 ships a
                // global WebSocket); Docker is a confirmed platform capability
                // and a host `websocat` is not. `timeout` bounds the pull and
                // the run; the script carries its own hard deadline.
                timeout(time: 5, unit: 'MINUTES') {
                    sh '''
                        set -eu
                        set +x

                        timeout 120 docker pull node:22-alpine >/dev/null

                        timeout 150 docker run --rm --network host \
                            -e INGRESS_HOST="$INGRESS_HOST" \
                            node:22-alpine node -e '
const target = "ws://" + process.env.INGRESS_HOST + "/ws/sensors";
const DEADLINE_MS = 90000;
const windowStart = Date.now();
let done = false;

const fail = (m) => { console.error("WebSocket smoke FAIL: " + m); process.exit(1); };

if (typeof WebSocket === "undefined") {
  fail("this Node runtime exposes no global WebSocket");
}

const timer = setTimeout(
  () => fail("no fresh sensor event within " + DEADLINE_MS + " ms"),
  DEADLINE_MS
);

const ws = new WebSocket(target);

ws.addEventListener("open", () => console.log("connected: " + target));
ws.addEventListener("error", (e) =>
  fail("socket error: " + (e && e.message ? e.message : "unknown"))
);
ws.addEventListener("close", () => {
  if (!done) fail("socket closed before a fresh sensor event arrived");
});
ws.addEventListener("message", (ev) => {
  let r;
  try {
    r = JSON.parse(typeof ev.data === "string" ? ev.data : String(ev.data));
  } catch (_) {
    return;
  }

  if (!r || r.kind !== "reading") return;

  const p = r.payload;
  if (!p || typeof p.deviceId !== "string" || p.deviceId === "") return;
  if (typeof p.channel !== "string" || p.channel === "") return;
  if (!Object.prototype.hasOwnProperty.call(p, "value")) return;
  if (typeof p.unit !== "string") return;

  const t = Date.parse(p.timestamp);
  if (Number.isNaN(t)) return;

  // Tolerate benign agent/container clock skew: ignore an implausibly old
  // frame and keep listening. If no acceptable event arrives, the DEADLINE_MS
  // timer above still fails the smoke closed.
  if (t < windowStart - 60000) return;

  done = true;
  clearTimeout(timer);
  console.log(
    "fresh OmniVise sensor event: deviceId=" + p.deviceId +
    " channel=" + p.channel + " value=" + p.value + " unit=" + p.unit +
    " timestamp=" + p.timestamp
  );
  try { ws.close(); } catch (_) {}
  process.exit(0);
});
'
                    '''
                }
            }
        }
    }

    post {
        always {
            // The saved Terraform plan can embed the temporary kubeconfig path
            // and other sensitive values — remove it explicitly before the
            // workspace is wiped; it is never stashed or archived.
            sh 'rm -f "$TF_ROOT/tfplan" || true'
            // Pipeline-native workspace cleanup only. This never touches the
            // registry: published exact-SHA tags are write-once and are not
            // deleted here or anywhere in this pipeline.
            deleteDir()
        }
    }
}

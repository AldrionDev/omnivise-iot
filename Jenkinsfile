// OmniVise IoT homelab delivery pipeline — exact-SHA image build and homelab
// registry publication boundary only (Homelab Delivery milestone, issue #60).
//
// Flow: checkout / identify revision -> homelab preflight -> write-once
// release-set precheck -> (BUILD path only) build all three images once ->
// publish all three exact-SHA tags with post-push Registry V2 digest
// verification. The pipeline ends after publication / reuse verification.
//
// Explicitly NOT in this milestone (see
// docs/architecture/delivery-architecture.md): Terraform init/plan/apply, the
// human approval gate, any Kubernetes read or write, post-deploy smoke, HCP
// credentials, kubeconfig binding, GHCR, AWS / EKS / ECR, GitHub-to-AWS OIDC,
// and image signing / SBOM / policy tooling. A future AWS target adds `aws` /
// `both` to DEPLOY_TARGET and a parallel GHCR publication branch alongside the
// homelab one; it must extend this file, not rewrite the homelab path. There is
// no separate PUSH_TARGET parameter — DEPLOY_TARGET alone will control both
// publication and deployment once more targets exist.
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
    }

    options {
        // Single-writer trust model: never overlap two runs writing the same
        // omnivise-iot/* exact-SHA tags.
        disableConcurrentBuilds()
        // No global pipeline timeout: every stage below carries its own bounded
        // timeout, so the pipeline still always fails closed instead of
        // hanging, without an outer clock that could expire mid-build or
        // mid-publish. (No human-approval window exists in this milestone; the
        // per-stage model is kept for forward consistency with the reference
        // pipeline.)
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

                    echo "Deploy target:   ${params.DEPLOY_TARGET}"
                    echo "Revision:        ${env.GIT_SHA}"
                    echo "Backend image:   ${env.BACKEND_IMAGE}"
                    echo "Frontend image:  ${env.FRONTEND_IMAGE}"
                    echo "Simulator image: ${env.SIMULATOR_IMAGE}"
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

        stage('Release-set write-once precheck') {
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
                    env.RELEASE_ACTION = sh(
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
                    echo "Release-set precheck: ${env.RELEASE_ACTION}"
                }
            }
        }

        stage('Build images') {
            when { environment name: 'RELEASE_ACTION', value: 'BUILD' }
            options { timeout(time: 20, unit: 'MINUTES') }
            steps {
                // BUILD path only. Each image is built exactly once from the
                // checked-out workspace using the repository Dockerfiles and
                // their existing build contract. Not rebuilt later.
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

        stage('Publish images') {
            when { environment name: 'RELEASE_ACTION', value: 'BUILD' }
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

        stage('Release set ready') {
            options { timeout(time: 1, unit: 'MINUTES') }
            steps {
                // Scope boundary: this milestone ends here. No Terraform, no
                // approval, no Kubernetes, no post-deploy smoke.
                script {
                    if (env.RELEASE_ACTION == 'REUSE') {
                        echo "REUSE: all three omnivise-iot exact-SHA images already present for ${env.GIT_SHA}; build and push skipped."
                    } else {
                        echo "BUILD: three omnivise-iot exact-SHA images published and verified for ${env.GIT_SHA}."
                    }
                }
            }
        }
    }

    post {
        always {
            // Pipeline-native workspace cleanup only. This never touches the
            // registry: published exact-SHA tags are write-once and are not
            // deleted here or anywhere in this pipeline.
            deleteDir()
        }
    }
}

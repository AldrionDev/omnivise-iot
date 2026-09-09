// OmniVise IoT homelab delivery pipeline — exact-SHA image build, homelab
// registry publication, and a gated Terraform deployment to the homelab k3s
// target (Homelab Delivery milestone, issues #60 and #61).
//
// Flow: checkout / identify revision -> homelab preflight -> write-once
// release-set precheck -> (BUILD path only) build all three images once ->
// publish all three exact-SHA tags with post-push Registry V2 digest
// verification -> Terraform init / validate / fmt-check against infra/homelab
// -> one saved Terraform plan -> pre-approval evidence -> human approval gate
// -> apply of that exact saved plan. The pipeline ends immediately after a
// successful terraform apply.
//
// Explicitly NOT in this milestone (see
// docs/architecture/delivery-architecture.md): any post-deploy smoke, kubectl
// readiness / workload-image / HTTP / WebSocket / MongoDB replica-health
// verification, rollback automation, GHCR, AWS / EKS / ECR, GitHub-to-AWS OIDC,
// and image signing / SBOM / policy tooling. A future AWS target adds `aws` /
// `both` to DEPLOY_TARGET and a parallel GHCR publication branch plus a second
// Terraform root / HCP workspace alongside the homelab one; it must extend this
// file, not rewrite the homelab path. There is no separate PUSH_TARGET
// parameter — DEPLOY_TARGET alone controls both publication and deployment.
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
                // The exact-SHA release set is now available (built and
                // published, or reused). The gated Terraform deployment below
                // consumes exactly these three image references. No post-deploy
                // smoke runs in this milestone — the pipeline stops right after
                // terraform apply.
                script {
                    if (env.RELEASE_ACTION == 'REUSE') {
                        echo "REUSE: all three omnivise-iot exact-SHA images already present for ${env.GIT_SHA}; build and push skipped."
                    } else {
                        echo "BUILD: three omnivise-iot exact-SHA images published and verified for ${env.GIT_SHA}."
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
                            timeout(time: 5, unit: 'MINUTES') {
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
                        // Stage boundary: the pipeline ends here on a successful
                        // apply. No kubectl, no readiness / image / HTTP /
                        // WebSocket / MongoDB verification — that is the next
                        // issue.
                    }
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

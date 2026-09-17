// OmniVise IoT delivery pipeline — exact-SHA image build, write-once
// publication to the homelab registry and/or GHCR, and a Terraform-gated
// deployment to the homelab k3s target and/or the AWS EKS target, each
// followed by bounded non-destructive post-deploy smoke verification
// (Homelab Delivery milestone issues #60-#62; AWS EKS Deployment milestone
// issue #122).
//
// DEPLOY_TARGET is authoritative for both publication and deployment:
//   homelab -> local homelab registry + infra/homelab (HCP workspace
//              omnivise-iot-k8s)
//   aws     -> GHCR + infra/aws (HCP workspace omnivise-iot-aws-app)
//   both    -> both registries + both deployment targets, independently
// There is no separate PUSH_TARGET parameter.
//
// Flow: checkout / identify revision, derive NEEDS_HOMELAB / NEEDS_AWS /
// NEEDS_GHCR -> (NEEDS_HOMELAB) homelab preflight -> write-once release-set
// prechecks for each registry this run needs -> (BUILD path only) build all
// three images once, reused/retagged symmetrically across registries so
// neither registry ever rebuilds an exact Git SHA the other already proved
// -> publish to whichever registries this run needs, each with post-push
// Registry V2 digest verification -> (NEEDS_HOMELAB) Terraform init/validate
// against infra/homelab, saved plan, pre-approval evidence, human approval,
// exact saved-plan apply, homelab post-deploy smoke -> (NEEDS_AWS) Terraform
// init/validate against infra/aws, AWS delivery-role assumption, saved plan,
// pre-approval evidence, human approval, exact saved-plan apply, AWS
// post-deploy smoke. Each target's plan/approval/apply/smoke is independent:
// for DEPLOY_TARGET=both, a failure in one target never triggers automatic
// rollback of the other (delivery-architecture section 22).
//
// Explicitly not part of this pipeline (see
// docs/architecture/delivery-architecture.md): the destructive #40 MongoDB
// pod-recreation persistence proof (section 18), any automatic rollback,
// Amazon ECR, GitHub-to-AWS OIDC, and any manual kubectl mutation — kubectl
// is verification-only for both targets. The deeper end-to-end AWS
// verification is intentionally deferred to issue #123; the AWS post-deploy
// smoke here stays bounded and conservative.
//
// This repository owns build + publication intent only. The Jenkins runtime,
// the shared `homelab-preflight` capability, and the local homelab registry
// authority (HOMELAB_REGISTRY, host:port, plain HTTP) are owned by
// local-jenkins-platform. No host IP is hard-coded here. The AWS delivery
// path requires the `aws` CLI on the Jenkins runtime — used both directly to
// assume the delivery role and by the Terraform `kubernetes` provider's
// `aws eks get-token` exec plugin for infra/aws plan and apply. That is a
// local-jenkins-platform toolchain prerequisite; this repository has no way
// to provision or verify it.
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
        choice(
            name: 'DEPLOY_TARGET',
            choices: ['homelab','aws','both'],
            description: 'Delivery target: homelab, aws, or both.'
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

        // Neutral local build-artifact repo prefix — deliberately not
        // homelab- or GHCR-named, and never pushed to any registry. The build
        // stage always tags into this local-only namespace so the local
        // artifact's identity never depends on which registries this run
        // happens to publish to (issue #122 fix: DEPLOY_TARGET=aws must not
        // require homelab image refs, which only exist when NEEDS_HOMELAB).
        LOCAL_IMAGE_REPO = 'omnivise-iot-local'

        // GHCR is a fixed public registry, not a homelab runtime detail — these
        // are literals, not platform-supplied (issue #121).
        GHCR_REGISTRY  = 'ghcr.io'
        GHCR_NAMESPACE = 'aldriondev'

        // Fixed AWS account/region/role literals for the AWS delivery path
        // (issue #122, docs/aws-delivery-identity.md). Not platform-supplied
        // and not secret: the role ARN and region are account/account-role
        // identifiers, not credentials.
        AWS_REGION            = 'eu-north-1'
        AWS_DEFAULT_REGION    = 'eu-north-1'
        AWS_DELIVERY_ROLE_ARN = 'arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery'

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
                    def supportedTargets = ['homelab', 'aws', 'both']
                    if (!supportedTargets.contains(params.DEPLOY_TARGET)) {
                        error "Unsupported DEPLOY_TARGET '${params.DEPLOY_TARGET}': Expected one of:${supportedTargets.join(', ')}."
                    }
                    env.NEEDS_HOMELAB = (params.DEPLOY_TARGET == 'homelab' || params.DEPLOY_TARGET == 'both') ? 'true' : 'false'
                    env.NEEDS_AWS = (params.DEPLOY_TARGET == 'aws' || params.DEPLOY_TARGET == 'both') ? 'true' : 'false'
                    env.NEEDS_GHCR    = env.NEEDS_AWS

                    if (env.NEEDS_HOMELAB == 'true' && !env.HOMELAB_REGISTRY?.trim()) {
                        error 'HOMELAB_REGISTRY is unset or empty — cannot construct homelab image references.'
                    }

                    // Exact checked-out revision. The multibranch job has
                    // already performed the SCM checkout before this stage;
                    // this only records the revision and freezes release
                    // identity.
                    env.GIT_SHA = sh(returnStdout: true, script: 'git rev-parse HEAD').trim()
                    if (!(env.GIT_SHA ==~ /^[0-9a-f]{40}$/)) {
                        error "Unexpected git revision format: '${env.GIT_SHA}' (expected exactly 40 lowercase hex characters)."
                    }

                    // Neutral local-only build-artifact refs. Always set,
                    // regardless of DEPLOY_TARGET: the build stage needs
                    // somewhere to tag a freshly built image before this run
                    // even knows whether it will publish to homelab, GHCR, or
                    // both, and a DEPLOY_TARGET=aws run must never depend on
                    // homelab refs (which only exist when NEEDS_HOMELAB).
                    env.LOCAL_BACKEND_IMAGE   = "${env.LOCAL_IMAGE_REPO}/backend:${env.GIT_SHA}"
                    env.LOCAL_FRONTEND_IMAGE  = "${env.LOCAL_IMAGE_REPO}/frontend:${env.GIT_SHA}"
                    env.LOCAL_SIMULATOR_IMAGE = "${env.LOCAL_IMAGE_REPO}/simulator:${env.GIT_SHA}"

                    if (env.NEEDS_HOMELAB == 'true') {
                        env.BACKEND_IMAGE   = "${env.HOMELAB_REGISTRY}/${env.IMAGE_REPO}/backend:${env.GIT_SHA}"
                        env.FRONTEND_IMAGE  = "${env.HOMELAB_REGISTRY}/${env.IMAGE_REPO}/frontend:${env.GIT_SHA}"
                        env.SIMULATOR_IMAGE = "${env.HOMELAB_REGISTRY}/${env.IMAGE_REPO}/simulator:${env.GIT_SHA}"
                    }

                    if (env.NEEDS_GHCR == 'true') {
                        env.GHCR_BACKEND_IMAGE   = "${env.GHCR_REGISTRY}/${env.GHCR_NAMESPACE}/omnivise-iot-backend:${env.GIT_SHA}"
                        env.GHCR_FRONTEND_IMAGE  = "${env.GHCR_REGISTRY}/${env.GHCR_NAMESPACE}/omnivise-iot-frontend:${env.GIT_SHA}"
                        env.GHCR_SIMULATOR_IMAGE = "${env.GHCR_REGISTRY}/${env.GHCR_NAMESPACE}/omnivise-iot-simulator:${env.GIT_SHA}"
                    }

                    // A registry not required by DEPLOY_TARGET is skipped entirely.
                    env.GHCR_RELEASE_ACTION = 'SKIPPED'

                    echo "Deploy target:   ${params.DEPLOY_TARGET}"
                    echo "Revision:        ${env.GIT_SHA}"
                    if (env.NEEDS_HOMELAB == 'true') {
                        echo "Homelab backend:   ${env.BACKEND_IMAGE}"
                        echo "Homelab frontend:  ${env.FRONTEND_IMAGE}"
                        echo "Homelab simulator: ${env.SIMULATOR_IMAGE}"
                    }
                    if (env.NEEDS_GHCR == 'true') {
                        echo "GHCR backend:    ${env.GHCR_BACKEND_IMAGE}"
                        echo "GHCR frontend:   ${env.GHCR_FRONTEND_IMAGE}"
                        echo "GHCR simulator:  ${env.GHCR_SIMULATOR_IMAGE}"
                    }
                }
            }
        }

        stage('Homelab preflight') {
            when {
                expression { return env.NEEDS_HOMELAB == 'true' }
            }
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
            when {
                expression { return env.NEEDS_HOMELAB == 'true' }
            }
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
            when { expression { return env.NEEDS_GHCR == 'true' } }
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
            // how" from "does this registry need publishing" (issue #121;
            // made target-aware in issue #122). Artifact identity must be
            // symmetric: when both registries are needed, neither one ever
            // rebuilds the exact Git SHA merely because it personally lacks
            // the tag while the OTHER registry already has a proven artifact
            // for that same SHA — the existing artifact is pulled and
            // retagged instead, in whichever direction is needed. When only
            // one registry is needed (DEPLOY_TARGET=homelab or aws), the
            // decision depends on that registry alone; the OTHER registry's
            // release-set action is never even computed (its precheck stage
            // did not run), so it must not be read here.
            //
            // Required matrix:
            //   NEEDS_HOMELAB && NEEDS_GHCR (DEPLOY_TARGET=both):
            //     homelab BUILD + GHCR BUILD  -> BUILD          (build once, both consume it)
            //     homelab REUSE + GHCR BUILD  -> HOMELAB_REUSE  (pull homelab -> retag for GHCR)
            //     homelab BUILD + GHCR REUSE  -> GHCR_REUSE     (pull GHCR -> retag for homelab)
            //     homelab REUSE + GHCR REUSE  -> NONE           (nothing to do)
            //   NEEDS_HOMELAB only (DEPLOY_TARGET=homelab):
            //     homelab BUILD -> BUILD
            //     homelab REUSE -> NONE
            //   NEEDS_GHCR only (DEPLOY_TARGET=aws):
            //     GHCR BUILD -> BUILD
            //     GHCR REUSE -> NONE
            //   Anything else (an unexpected/inconsistent precheck result, or
            //   neither registry needed) fails closed rather than guessing.
            //
            options { timeout(time: 1, unit: 'MINUTES') }
            steps {
                script {
                    if (env.NEEDS_HOMELAB == 'true' && env.NEEDS_GHCR == 'true') {
                        if (env.HOMELAB_RELEASE_ACTION == 'BUILD' && env.GHCR_RELEASE_ACTION == 'BUILD') {
                            env.ARTIFACT_SOURCE = 'BUILD'
                        } else if (env.HOMELAB_RELEASE_ACTION == 'REUSE' && env.GHCR_RELEASE_ACTION == 'BUILD') {
                            env.ARTIFACT_SOURCE = 'HOMELAB_REUSE'
                        } else if (env.HOMELAB_RELEASE_ACTION == 'BUILD' && env.GHCR_RELEASE_ACTION == 'REUSE') {
                            env.ARTIFACT_SOURCE = 'GHCR_REUSE'
                        } else if (env.HOMELAB_RELEASE_ACTION == 'REUSE' && env.GHCR_RELEASE_ACTION == 'REUSE') {
                            env.ARTIFACT_SOURCE = 'NONE'
                        } else {
                            error "Inconsistent release-set state for DEPLOY_TARGET=both: HOMELAB_RELEASE_ACTION='${env.HOMELAB_RELEASE_ACTION}' GHCR_RELEASE_ACTION='${env.GHCR_RELEASE_ACTION}' (each must be BUILD or REUSE)."
                        }
                    } else if (env.NEEDS_HOMELAB == 'true') {
                        if (env.HOMELAB_RELEASE_ACTION == 'BUILD') {
                            env.ARTIFACT_SOURCE = 'BUILD'
                        } else if (env.HOMELAB_RELEASE_ACTION == 'REUSE') {
                            env.ARTIFACT_SOURCE = 'NONE'
                        } else {
                            error "Inconsistent release-set state for DEPLOY_TARGET=homelab: HOMELAB_RELEASE_ACTION='${env.HOMELAB_RELEASE_ACTION}' (must be BUILD or REUSE)."
                        }
                    } else if (env.NEEDS_GHCR == 'true') {
                        if (env.GHCR_RELEASE_ACTION == 'BUILD') {
                            env.ARTIFACT_SOURCE = 'BUILD'
                        } else if (env.GHCR_RELEASE_ACTION == 'REUSE') {
                            env.ARTIFACT_SOURCE = 'NONE'
                        } else {
                            error "Inconsistent release-set state for DEPLOY_TARGET=aws: GHCR_RELEASE_ACTION='${env.GHCR_RELEASE_ACTION}' (must be BUILD or REUSE)."
                        }
                    } else {
                        error 'Inconsistent DEPLOY_TARGET state: neither NEEDS_HOMELAB nor NEEDS_GHCR is true.'
                    }
                    echo "Artifact source: ${env.ARTIFACT_SOURCE}"
                }
            }
        }

        stage('Build images') {
            // ARTIFACT_SOURCE == 'BUILD' whenever every registry this run
            // needs lacks the exact-SHA release set — one registry for
            // DEPLOY_TARGET=homelab/aws, both for DEPLOY_TARGET=both. Whenever
            // only one of two needed registries needs BUILD and the other
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
                // existing build contract, into the neutral LOCAL_*_IMAGE
                // refs — never a homelab- or GHCR-tagged ref directly, since
                // this stage runs regardless of which registries this run
                // will actually publish to (issue #122: DEPLOY_TARGET=aws has
                // no homelab refs at all). Not rebuilt later, and never
                // rebuilt merely to publish to a second registry — homelab
                // and/or GHCR publication (whichever this run needs) retags
                // this same local artifact.
                //
                // frontend takes NO --build-arg: frontend/Dockerfile declares
                // no ARG, and Vite reads frontend/.env.production
                // (VITE_API_URL=/api) from the build context at `npm run
                // build`. The HomeStreamLab SPA build-arg pattern deliberately
                // does not apply to OmniVise.
                sh '''
                    set -eu
                    docker build -f backend/Dockerfile    -t "$LOCAL_BACKEND_IMAGE"   backend
                    docker build -f frontend/Dockerfile   -t "$LOCAL_FRONTEND_IMAGE"  frontend
                    docker build -f simulators/Dockerfile -t "$LOCAL_SIMULATOR_IMAGE" simulators
                '''
            }
        }

        stage('Acquire GHCR source artifact') {
            // Homelab REUSE + GHCR BUILD only (issue #121; only reachable for
            // DEPLOY_TARGET=both, since it requires a homelab release-set
            // action to exist at all). Never rebuilds the exact Git SHA — a
            // rebuild can legitimately produce a different manifest digest
            // for the same commit (base image updates, timestamps,
            // package-repository drift). Instead, pull the already-published,
            // already-proven homelab exact-SHA images and retag them into the
            // neutral LOCAL_*_IMAGE refs, so 'Publish images (GHCR)' below
            // retags/publishes that same pulled artifact to GHCR exactly like
            // any other BUILD-path artifact, without rebuilding. Cross-registry
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

                    docker tag "$BACKEND_IMAGE"   "$LOCAL_BACKEND_IMAGE"
                    docker tag "$FRONTEND_IMAGE"  "$LOCAL_FRONTEND_IMAGE"
                    docker tag "$SIMULATOR_IMAGE" "$LOCAL_SIMULATOR_IMAGE"
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
            // artifact' above; only reachable for DEPLOY_TARGET=both, since it
            // requires a GHCR release-set action to exist at all). GHCR
            // already has the exact-SHA release set; do not rebuild it for
            // homelab. Pull the existing GHCR images and retag them into the
            // neutral LOCAL_*_IMAGE refs — 'Publish images (homelab)' then
            // retags/pushes that same pulled local image artifact exactly
            // like any other BUILD-path artifact, without rebuilding. No
            // Kubernetes/Terraform/AWS behavior is introduced here.
            // Cross-registry manifest digests are traceability evidence
            // only — they may legitimately differ.
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

                        docker tag "$GHCR_BACKEND_IMAGE"   "$LOCAL_BACKEND_IMAGE"
                        docker tag "$GHCR_FRONTEND_IMAGE"  "$LOCAL_FRONTEND_IMAGE"
                        docker tag "$GHCR_SIMULATOR_IMAGE" "$LOCAL_SIMULATOR_IMAGE"

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
                // existing one. Only reachable when NEEDS_HOMELAB (this
                // precheck's action can only be BUILD if the precheck ran),
                // so BACKEND_IMAGE et al. are guaranteed to exist here.
                //
                // The local artifact is always the neutral LOCAL_*_IMAGE ref
                // (built directly, or retagged from a pulled GHCR artifact by
                // 'Acquire homelab source artifact from GHCR') — tag it to
                // the canonical homelab refs here, at the publish boundary,
                // rather than baking the homelab name into the build/acquire
                // stages (issue #122: those stages must not assume a homelab
                // target).
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

                    docker tag "$LOCAL_BACKEND_IMAGE"   "$BACKEND_IMAGE"
                    docker tag "$LOCAL_FRONTEND_IMAGE"  "$FRONTEND_IMAGE"
                    docker tag "$LOCAL_SIMULATOR_IMAGE" "$SIMULATOR_IMAGE"

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
            // NEEDS_GHCR is authoritative and DEPLOY_TARGET-derived (aws or
            // both), plus GHCR's own BUILD state. Runs whether the local
            // artifact came from 'Build images' or 'Acquire GHCR source
            // artifact' (ARTIFACT_SOURCE == BUILD or HOMELAB_REUSE) — by this
            // point the neutral $LOCAL_BACKEND_IMAGE etc. exist locally either
            // way (built directly, or retagged from a pulled homelab
            // artifact), so the tag/push steps below are identical and never
            // depend on $BACKEND_IMAGE, which does not exist at all for
            // DEPLOY_TARGET=aws (issue #122 fix).
            when {
                allOf {
                    expression { return env.NEEDS_GHCR == 'true' }
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

                        docker tag "$LOCAL_BACKEND_IMAGE"   "$GHCR_BACKEND_IMAGE"
                        docker tag "$LOCAL_FRONTEND_IMAGE"  "$GHCR_FRONTEND_IMAGE"
                        docker tag "$LOCAL_SIMULATOR_IMAGE" "$GHCR_SIMULATOR_IMAGE"

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
                // considered. The gated homelab Terraform deployment below
                // consumes exactly the homelab image references; the gated
                // AWS Terraform deployment consumes exactly the GHCR image
                // references. Each target's post-deploy smoke stage
                // afterwards verifies that exactly those refs are the ones
                // running for that target.
                script {
                    if (env.NEEDS_HOMELAB == 'true') {
                        if (env.HOMELAB_RELEASE_ACTION == 'REUSE') {
                            echo "Homelab REUSE: all three omnivise-iot exact-SHA images already present for ${env.GIT_SHA}; build and push skipped."
                        } else {
                            echo "Homelab BUILD: three omnivise-iot exact-SHA images published and verified for ${env.GIT_SHA}."
                        }
                    }
                    if (env.NEEDS_GHCR == 'true') {
                        if (env.GHCR_RELEASE_ACTION == 'REUSE') {
                            echo "GHCR REUSE: all three exact-SHA images already present in GHCR for ${env.GIT_SHA}; publish skipped."
                        } else {
                            echo "GHCR BUILD: three exact-SHA images published and verified to GHCR for ${env.GIT_SHA}."
                        }
                    }
                    echo "Release set ready for DEPLOY_TARGET=${params.DEPLOY_TARGET} at exact SHA ${env.GIT_SHA}."
                }
            }
        }

        stage('Homelab Terraform init & validate') {
            when { expression { return env.NEEDS_HOMELAB == 'true' } }
            options { timeout(time: 10, unit: 'MINUTES') }
            steps {
                dir('infra/homelab') {
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
                        // section, which intentionally covers the whole infra/
                        // tree from infra/homelab, not just this root.
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

        stage('AWS Terraform init & validate') {
            when { expression { return env.NEEDS_AWS == 'true' } }
            options { timeout(time: 10, unit: 'MINUTES') }
            steps {
                dir('infra/aws') {
                    // Same HCP-only contract as the homelab root: init/validate
                    // never contact AWS or the EKS cluster, so no AWS
                    // credentials are bound here (issue #122 constraint: do not
                    // add AWS credentials to init/validate unless actually
                    // required). fmt-check is scoped to this root only
                    // (docs/aws-eks-application.md verification procedure),
                    // not the whole infra/ tree — the homelab stage above
                    // already covers that.
                    withCredentials([
                        string(credentialsId: 'hcp-terraform-cli', variable: 'TF_TOKEN_app_terraform_io')
                    ]) {
                        sh '''
                            set -eu
                            set +x
                            terraform init -input=false -lockfile=readonly
                            terraform validate
                            terraform fmt -check -recursive .
                        '''
                    }
                }
            }
        }

        stage('Homelab deploy (plan, approve, apply)') {
            when { expression { return env.NEEDS_HOMELAB == 'true' } }
            steps {
                dir('infra/homelab') {
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
                                     "DEPLOY_TARGET: ${params.DEPLOY_TARGET}   HCP workspace: omnivise-iot-k8s\n" +
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
                        // 'Post-deploy smoke (homelab)' stage below. A failed
                        // apply fails the pipeline here and an aborted
                        // approval interrupts it above, so in both cases the
                        // smoke stage never starts.
                    }
                }
            }
        }

        stage('Post-deploy smoke (homelab)') {
            // Declarative pipeline only runs this stage when every earlier stage
            // succeeded, so it is reached exclusively after a successful
            // homelab `terraform apply` (a failed apply fails the run; an
            // aborted approval interrupts it). Gated by NEEDS_HOMELAB so an
            // aws-only run neither needs nor exercises the homelab kubeconfig.
            // Every check here is read-only against both the cluster and the
            // application: bounded `kubectl get` on named resources, HTTP GET,
            // and a WebSocket subscribe/listen. There is no kubectl
            // apply/patch/delete/create, no rollout restart, no scale, no pod
            // deletion, no database write, and no Terraform or registry
            // mutation. This closes the non-destructive part of the #40 manual
            // evidence loop (delivery-architecture section 17); the
            // destructive #40 MongoDB pod-recreation persistence proof is
            // deliberately NOT reproduced (section 18).
            when { expression { return env.NEEDS_HOMELAB == 'true' } }
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

        stage('AWS deploy (plan, approve, apply)') {
            // Independent of the homelab deploy stage above: separate
            // Terraform root/workspace, separate saved plan, separate
            // approval, separate apply (issue #122, delivery-architecture
            // sections 11 and 22). For DEPLOY_TARGET=both this stage runs
            // after the homelab deploy stage completes; a homelab failure
            // above already fails the pipeline before this stage is reached,
            // and (per section 22) an AWS failure here never rolls back an
            // already-applied homelab deploy.
            when { expression { return env.NEEDS_AWS == 'true' } }
            steps {
                dir('infra/aws') {
                    // Plan. Bootstrap identity is assume-role-only (issue #118
                    // / docs/aws-delivery-identity.md): it is never used
                    // directly as delivery authority, and it is bound here
                    // only long enough for one sts:AssumeRole call inside this
                    // single shell script — the assumed-role session lives
                    // only as shell-local exported variables for the
                    // remainder of this same script (never Jenkins env.*,
                    // never a workspace file) and is gone the moment this step
                    // exits. Apply below performs its OWN fresh assume-role
                    // after approval, so no AWS session has to survive the
                    // human wait (see the approval comment below). HCP token
                    // and the read-only GHCR pull credential are also bound
                    // only around plan creation and released before the human
                    // wait — applying a saved plan ignores TF_VAR_* for
                    // already-planned values. ghcr-omnivise-iot-pull only
                    // (read:packages) is used for TF_VAR_ghcr_username /
                    // TF_VAR_ghcr_token, which end up in the EKS ghcr-pull
                    // Secret — never the write-capable
                    // ghcr-omnivise-iot-publisher credential.
                    withCredentials([
                        usernamePassword(
                            credentialsId: 'aws-omnivise-iot-bootstrap',
                            usernameVariable: 'AWS_BOOTSTRAP_ACCESS_KEY_ID',
                            passwordVariable: 'AWS_BOOTSTRAP_SECRET_ACCESS_KEY'
                        ),
                        string(credentialsId: 'hcp-terraform-cli', variable: 'TF_TOKEN_app_terraform_io'),
                        usernamePassword(
                            credentialsId: 'ghcr-omnivise-iot-pull',
                            usernameVariable: 'TF_VAR_ghcr_username',
                            passwordVariable: 'TF_VAR_ghcr_token'
                        )
                    ]) {
                        timeout(time: 10, unit: 'MINUTES') {
                            // The bootstrap access key/secret are scoped with
                            // an inline env-var prefix to the single
                            // `aws sts assume-role` call only, never exported
                            // into the rest of this script. The assumed-role
                            // response is parsed with awk only (no jq/python)
                            // and never echoed; an incomplete response (any
                            // field empty) fails closed before terraform runs.
                            // The kubernetes provider's `aws eks get-token`
                            // exec plugin needs the assumed-role session
                            // in-scope to diff current EKS state during plan.
                            sh '''
                                set -eu
                                set +x

                                creds=$(
                                    AWS_ACCESS_KEY_ID="$AWS_BOOTSTRAP_ACCESS_KEY_ID" \
                                    AWS_SECRET_ACCESS_KEY="$AWS_BOOTSTRAP_SECRET_ACCESS_KEY" \
                                    aws sts assume-role \
                                        --role-arn "$AWS_DELIVERY_ROLE_ARN" \
                                        --role-session-name "omnivise-iot-jenkins-aws-plan-${BUILD_NUMBER}" \
                                        --duration-seconds 3600 \
                                        --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
                                        --output text
                                )

                                access_key=$(printf '%s' "$creds" | awk '{print $1}')
                                secret_key=$(printf '%s' "$creds" | awk '{print $2}')
                                session_token=$(printf '%s' "$creds" | awk '{print $3}')

                                if [ -z "$access_key" ] || [ -z "$secret_key" ] || [ -z "$session_token" ]; then
                                    echo "assume-role for plan returned incomplete credentials" >&2
                                    exit 1
                                fi

                                export AWS_ACCESS_KEY_ID="$access_key"
                                export AWS_SECRET_ACCESS_KEY="$secret_key"
                                export AWS_SESSION_TOKEN="$session_token"
                                unset access_key secret_key session_token creds

                                # The three exact-SHA GHCR refs frozen in
                                # 'Checkout & identify revision' — passed
                                # verbatim, never recomputed, never re-queried.
                                export TF_VAR_backend_image_ref="$GHCR_BACKEND_IMAGE"
                                export TF_VAR_frontend_image_ref="$GHCR_FRONTEND_IMAGE"
                                export TF_VAR_simulator_image_ref="$GHCR_SIMULATOR_IMAGE"
                                # tfplan embeds TF_VAR_ghcr_token and other
                                # sensitive values — restrict its mode from
                                # creation (umask) and again explicitly (chmod).
                                umask 077
                                terraform plan -input=false -lock-timeout=120s -out=tfplan
                                chmod 600 tfplan
                            '''
                        }

                        // Pre-approval evidence: the release identity the
                        // operator is approving plus a read-only render of the
                        // exact saved plan. No second plan is created. Reading
                        // a saved plan file is a local, non-provider operation,
                        // so no AWS session is sourced here.
                        timeout(time: 5, unit: 'MINUTES') {
                            withEnv(["DEPLOY_TARGET=${params.DEPLOY_TARGET}"]) {
                                sh '''
                                    set -eu
                                    set +x
                                    echo "OmniVise AWS delivery — pre-approval evidence"
                                    echo "  Git SHA:          $GIT_SHA"
                                    echo "  DEPLOY_TARGET:    $DEPLOY_TARGET"
                                    echo "  GHCR backend:     $GHCR_BACKEND_IMAGE"
                                    echo "  GHCR frontend:    $GHCR_FRONTEND_IMAGE"
                                    echo "  GHCR simulator:   $GHCR_SIMULATOR_IMAGE"
                                    echo "  Terraform root:   infra/aws"
                                    echo "  HCP workspace:    omnivise-iot-aws-app"
                                    echo "  Saved plan:       infra/aws/tfplan"
                                    echo
                                    echo "Saved Terraform plan (read-only; this exact plan is what apply consumes):"
                                    terraform show -no-color tfplan
                                '''
                            }
                        }
                    }

                    // Human approval gate — after the saved plan and its
                    // evidence, before any apply. Approving authorises
                    // applying THIS saved plan for THIS Git SHA and THESE GHCR
                    // image refs against the AWS EKS target. No automatic
                    // approval; no timeout. No AWS credential is bound, active,
                    // or persisted anywhere during this wait: the plan step's
                    // assumed-role session above existed only as shell-local
                    // variables inside that one already-finished `sh` step and
                    // is gone; apply below performs its own fresh assume-role
                    // afterwards, so an arbitrarily long approval wait can
                    // never race an AWS STS session's expiry.
                    input(
                        message: "Apply the exact saved Terraform plan infra/aws/tfplan to the OmniVise AWS EKS target?\n" +
                                 "DEPLOY_TARGET: ${params.DEPLOY_TARGET}   HCP workspace: omnivise-iot-aws-app\n" +
                                 "Git SHA:   ${env.GIT_SHA}\n" +
                                 "backend:   ${env.GHCR_BACKEND_IMAGE}\n" +
                                 "frontend:  ${env.GHCR_FRONTEND_IMAGE}\n" +
                                 "simulator: ${env.GHCR_SIMULATOR_IMAGE}",
                        ok: 'Apply saved plan'
                    )

                    // Apply the SAVED plan only — no re-plan, no TF_VAR_*
                    // re-supplied for planned values (applying a saved plan
                    // ignores them for already-planned values, and the
                    // kubernetes/aws providers need no new TF_VAR_ghcr_* to
                    // authenticate). The HCP token is re-bound to write state
                    // and hold the state lock. The bootstrap identity is
                    // re-bound to perform a brand-new sts:AssumeRole here,
                    // after approval — never the plan step's session, which
                    // no longer exists — so apply always runs against a fresh
                    // AWS session regardless of how long the approval wait
                    // took. Same discipline as the plan step: the bootstrap
                    // credential is scoped to the single assume-role call,
                    // the response is parsed with awk only and never echoed,
                    // an incomplete response fails closed, and the assumed
                    // session lives only as shell-local exported variables
                    // inside this one script — never Jenkins env.*, never a
                    // workspace file.
                    withCredentials([
                        usernamePassword(
                            credentialsId: 'aws-omnivise-iot-bootstrap',
                            usernameVariable: 'AWS_BOOTSTRAP_ACCESS_KEY_ID',
                            passwordVariable: 'AWS_BOOTSTRAP_SECRET_ACCESS_KEY'
                        ),
                        string(credentialsId: 'hcp-terraform-cli', variable: 'TF_TOKEN_app_terraform_io')
                    ]) {
                        timeout(time: 15, unit: 'MINUTES') {
                            sh '''
                                set -eu
                                set +x

                                creds=$(
                                    AWS_ACCESS_KEY_ID="$AWS_BOOTSTRAP_ACCESS_KEY_ID" \
                                    AWS_SECRET_ACCESS_KEY="$AWS_BOOTSTRAP_SECRET_ACCESS_KEY" \
                                    aws sts assume-role \
                                        --role-arn "$AWS_DELIVERY_ROLE_ARN" \
                                        --role-session-name "omnivise-iot-jenkins-aws-apply-${BUILD_NUMBER}" \
                                        --duration-seconds 3600 \
                                        --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
                                        --output text
                                )

                                access_key=$(printf '%s' "$creds" | awk '{print $1}')
                                secret_key=$(printf '%s' "$creds" | awk '{print $2}')
                                session_token=$(printf '%s' "$creds" | awk '{print $3}')

                                if [ -z "$access_key" ] || [ -z "$secret_key" ] || [ -z "$session_token" ]; then
                                    echo "assume-role for apply returned incomplete credentials" >&2
                                    exit 1
                                fi

                                export AWS_ACCESS_KEY_ID="$access_key"
                                export AWS_SECRET_ACCESS_KEY="$secret_key"
                                export AWS_SESSION_TOKEN="$session_token"
                                unset access_key secret_key session_token creds

                                terraform apply -input=false -lock-timeout=120s tfplan
                            '''
                        }
                    }
                    // Stage boundary: a successful apply hands off to the
                    // 'Post-deploy smoke (AWS)' stage below. A failed apply
                    // fails the pipeline here and an aborted approval
                    // interrupts it above, so in both cases the smoke stage
                    // never starts.
                }
            }
        }

        stage('Post-deploy smoke (AWS)') {
            // Bounded and deliberately conservative (issue #122): Terraform
            // outputs plus read-only HTTP verification of the public ALB
            // route, no kubectl at all. The deeper end-to-end AWS
            // verification (workload readiness, exact running-image
            // equality, MongoDB/Change-Stream data-path proof analogous to
            // the homelab smoke above) is scoped to issue #123, not here.
            when { expression { return env.NEEDS_AWS == 'true' } }
            options { timeout(time: 10, unit: 'MINUTES') }
            steps {
                dir('infra/aws') {
                    // Reading Terraform outputs only needs the HCP token, not
                    // an AWS session — it is a remote-state read, not a live
                    // AWS/EKS API call.
                    withCredentials([
                        string(credentialsId: 'hcp-terraform-cli', variable: 'TF_TOKEN_app_terraform_io')
                    ]) {
                        script {
                            env.AWS_FRONTEND_INGRESS_HOSTNAME = sh(
                                returnStdout: true,
                                script: '''
                                    set -eu
                                    set +x
                                    terraform output -raw frontend_ingress_hostname
                                '''
                            ).trim()
                        }
                    }
                }

                script {
                    if (!env.AWS_FRONTEND_INGRESS_HOSTNAME?.trim()) {
                        error 'AWS post-deploy smoke: frontend_ingress_hostname Terraform output is empty.'
                    }
                    echo "AWS frontend ingress hostname: ${env.AWS_FRONTEND_INGRESS_HOSTNAME}"
                }

                // Canonical HTTP smoke against the AWS ALB — the same shape as
                // the homelab HTTP smoke above: `/` must return the frontend
                // SPA shell and `/api/sensors/latest` must return a JSON array
                // proxied frontend -> backend. No kubeconfig, no kubectl.
                timeout(time: 8, unit: 'MINUTES') {
                    sh '''
                        set -eu
                        set +x

                        base="http://$AWS_FRONTEND_INGRESS_HOSTNAME"
                        deadline=$(( $(date +%s) + 300 ))

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
                                sleep 10
                            done
                        }

                        get_ok "/" 'id="root"'
                        get_ok "/api/sensors/latest?limit=1" '^\\['
                    '''
                }
            }
        }
    }

    post {
        always {
            // The saved Terraform plans can embed the temporary kubeconfig
            // path and other sensitive values — remove them explicitly before
            // the workspace is wiped; neither is ever stashed or archived.
            // The AWS assumed-role session is never written to the workspace
            // in the first place (it lives only as shell-local exported
            // variables inside the plan/apply steps' own `sh` scripts), so
            // there is no corresponding file to clean up here. `rm -f`
            // already tolerates a missing path (a target never planned this
            // run, or a run that never reached the AWS deploy stage), so
            // cleanup does not fail when only one target — or neither — got
            // this far.
            sh 'rm -f infra/homelab/tfplan infra/aws/tfplan || true'
            // Pipeline-native workspace cleanup only. This never touches the
            // registry: published exact-SHA tags are write-once and are not
            // deleted here or anywhere in this pipeline.
            deleteDir()
        }
    }
}

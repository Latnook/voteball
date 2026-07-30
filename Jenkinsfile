// Voteball CI. Builds, scans and pushes the four images, then commits the new image tag to master.
// ArgoCD observes that commit and rolls the Deployments -- Jenkins never touches the cluster and
// holds no cluster credentials.
//
// Design: docs/design/2026-07-20-jenkins-migration-design.md  (G1-G7 referenced below)

pipeline {
  // The pod that provides these containers is declared in ci/jenkins/jenkins.yaml, under the
  // kubernetes cloud's `templates:` block -- NOT here. The CI environment is configuration and
  // belongs in JCasC; the Jenkinsfile owns build steps. Changing which containers exist, or their
  // versions, means editing that file and re-applying Terraform.
  agent { label 'voteball-build' }

  options {
    // Two builds racing to rewrite values.yaml and push to master would conflict. Also bounds the
    // damage if the G2 guard ever fails.
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '20'))   // G5
    timestamps()
  }

  parameters {
    // G3 -- a manually triggered build has an empty changeset and would otherwise skip everything.
    // G6 -- this checkbox does not appear until the job has run once; that first run is expected
    // to do nothing. See the runbook in docs/cicd.md.
    booleanParam(name: 'FORCE_BUILD', defaultValue: false,
                 description: 'Build even if this commit touches no files under services/')
  }

  triggers { githubPush() }

  // NO `environment` BLOCK. Declarative Groovy rejects an empty one outright -- "No variables
  // specified for environment" -- and that is a PARSE error, so it fails the build before any stage
  // runs and cannot be caught by anything short of actually building.
  //
  // Nothing belongs in it any more:
  //   AWS_REGION / CLUSTER_NAME  come from Jenkins global environment variables (see JCasC).
  //   ECR_REGISTRY               is derived at runtime in 'Resolve tag and account'.
  //   TRIVY_IMAGE                is gone -- the trivy container's image is fixed by the pod template.
  //   TRIVY_CACHE                is gone, and must NOT come back as an emptyDir: that turns a
  //                              cross-build cache into a per-build one and re-downloads the ~100MB
  //                              database on each of four scans, every build. The DB is mirrored into
  //                              ECR instead; see scripts/mirror-trivy-db.sh.

  stages {

    // G2 -- Jenkins has no native [skip ci]. Without this, the pipeline's own tag-bump commit
    // retriggers it forever.
    stage('Guard: is this our own commit?') {
      steps {
        script {
          // This guard runs unconditionally and first: a commit whose message contains [skip ci]
          // can never be built here, even manually with FORCE_BUILD.
          def msg = sh(script: 'git log -1 --pretty=%B', returnStdout: true).trim()
          def verdict
          withEnv(["COMMIT_MSG=${msg}"]) {
            verdict = sh(script: 'scripts/ci/should-skip-build.sh "$COMMIT_MSG"',
                         returnStdout: true).trim()
          }
          if (verdict == 'skip') {
            // currentBuild.result is set before the error() below because Jenkins only ever
            // worsens a build result, never improves it -- so NOT_BUILT survives even though the
            // exception raised next is uncaught. That uncaught exception is what actually skips
            // every later stage; nothing here catches it.
            currentBuild.result = 'NOT_BUILT'
            currentBuild.description = 'Skipped: tag-bump commit ([skip ci])'
            error('SKIP_CI')
          }
        }
      }
    }

    stage('Resolve tag and account') {
      steps {
        script {
          // Fail loudly and early if the global properties are missing, rather than producing
          // image references like "null.dkr.ecr.null.amazonaws.com" that fail confusingly later.
          if (!env.AWS_REGION || !env.CLUSTER_NAME) {
            error('AWS_REGION and CLUSTER_NAME must be set as Jenkins global environment variables ' +
                  '(Manage Jenkins > System > Global properties). See docs/cicd.md.')
          }
          env.TAG = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
          // container('awscli') is REQUIRED, not decoration. Steps outside a container() block run
          // in the `jnlp` container, which has git but no AWS CLI -- on the retired EC2 host `aws`
          // was simply on PATH, so this line needed no wrapper there. Without it the build dies with
          // "aws: not found" and exit code 127, which reads like a broken image rather than a step
          // running in the wrong container. Same reason for 'Already built?' below.
          container('awscli') {
            env.AWS_ACCOUNT_ID = sh(script: 'aws sts get-caller-identity --query Account --output text',
                                    returnStdout: true).trim()
          }
          env.ECR_REGISTRY = "${env.AWS_ACCOUNT_ID}.dkr.ecr.${env.AWS_REGION}.amazonaws.com"
          env.ECR_REPOS = "${env.CLUSTER_NAME}-backend ${env.CLUSTER_NAME}-worker " +
                          "${env.CLUSTER_NAME}-nginx ${env.CLUSTER_NAME}-backup"
          echo "Building ${env.TAG} into ${env.ECR_REGISTRY}"
        }
      }
    }

    // G1 -- ECR tags are immutable, so re-pushing an existing SHA is rejected. If everything is
    // already there, skip straight to the tag bump instead of failing.
    stage('Already built?') {
      steps {
        script {
          // container('awscli'): images-exist.sh shells out to `aws ecr describe-images`. The script
          // itself is untouched -- only where it runs had to change. See 'Resolve tag and account'.
          container('awscli') {
            env.ALREADY_BUILT = sh(script: 'scripts/ci/images-exist.sh', returnStdout: true).trim()
          }
          if (env.ALREADY_BUILT == 'present') {
            echo "All images for ${env.TAG} are already in ECR -- skipping build, scan and push."
          }
        }
      }
    }

    stage('Build images') {
      when { allOf {
        expression { env.ALREADY_BUILT != 'present' }
        anyOf { changeset 'services/**'; expression { params.FORCE_BUILD } }   // G3
      } }
      steps {
        // BuildKit needs ECR credentials of its own: --import-cache/--export-cache talk to the
        // registry directly, and buildctl reads $DOCKER_CONFIG/config.json rather than inheriting
        // anything from the agent. Without this the build runs, resolves the Dockerfile, and only
        // fails when it reaches the registry -- "401 Unauthorized" against the buildcache repo,
        // minutes in, looking like an IAM problem rather than a missing file.
        //
        // The AWS CLI lives in its own container, so the token is written to the shared /images
        // volume for the buildkit container to pick up. Removed in the post block.
        container('awscli') {
          sh '''
            set -eu
            umask 077
            mkdir -p /images/dockercfg
            printf '{"auths":{"%s":{"auth":"%s"}}}' \
              "$ECR_REGISTRY" \
              "$(printf 'AWS:%s' "$(aws ecr get-login-password --region "$AWS_REGION")" | base64 -w0)" \
              > /images/dockercfg/config.json
          '''
        }
        container('buildkit') {
          // NOTE: --export-cache pushes unscanned layer-cache blobs to the *-buildcache repo below,
          // ahead of the Trivy scan. That is fine -- buildcache is not a repo the app ever deploys
          // from -- but it means "nothing reaches ECR before the scan passes" is not literally true
          // of bytes. What IS still true: no deployable, tagged image reaches ECR pre-scan; see
          // the 'Push to ECR' stage and design doc section 5.
          sh '''
            set -eu
            # BUILDKIT_HOST, not buildctl-daemonless.sh. daemonless.sh ignores any existing daemon
            # and spawns its OWN buildkitd under a fresh temp root, taking flags only from
            # $BUILDKITD_FLAGS -- which is unset here. That silently drops
            # --oci-worker-no-process-sandbox, the flag the buildkit sidecar in
            # ci/jenkins/jenkins.yaml was started with to run rootless. Pointing plain `buildctl` at
            # the sidecar's socket instead means the daemon that actually builds is the one that was
            # configured for it.
            export BUILDKIT_HOST=unix:///run/user/1000/buildkit/buildkitd.sock
            # Written by the awscli container above; buildctl reads config.json from here.
            export DOCKER_CONFIG=/images/dockercfg
            CACHE="$ECR_REGISTRY/$CLUSTER_NAME-buildcache"
            for svc in backend worker nginx backup; do
              case "$svc" in
                nginx) ctx=services/frontend ;;
                *)     ctx=services/$svc ;;
              esac
              buildctl build \
                --frontend dockerfile.v0 \
                --local context="$ctx" --local dockerfile="$ctx" \
                --output type=oci,dest=/images/$svc.tar,name="$ECR_REGISTRY/$CLUSTER_NAME-$svc:$TAG" \
                --import-cache type=registry,ref="$CACHE:$svc" \
                --export-cache type=registry,ref="$CACHE:$svc",mode=max
            done
          '''
        }
      }
    }

    stage('Trivy scan') {
      when { allOf {
        expression { env.ALREADY_BUILT != 'present' }
        anyOf { changeset 'services/**'; expression { params.FORCE_BUILD } }
      } }
      steps {
        container('trivy') {
          sh '''
            set -eu
            DB="$ECR_REGISTRY/$CLUSTER_NAME-trivy-db"
            for svc in backend worker nginx; do
              echo "--- trivy $CLUSTER_NAME-$svc (blocking) ---"
              trivy image --db-repository "$DB" --input /images/$svc.tar \
                --severity CRITICAL,HIGH --exit-code 1 --ignore-unfixed
            done

            # The backup image is a third-party base (postgres:17-alpine + aws-cli) whose CVEs are
            # upstream Go-tooling issues outside this project's control: surface, do not block.
            echo "--- trivy $CLUSTER_NAME-backup (report only) ---"
            trivy image --db-repository "$DB" --input /images/backup.tar \
              --severity CRITICAL,HIGH --exit-code 0 --ignore-unfixed
          '''
        }
      }
    }

    stage('Push to ECR') {
      when { allOf {
        expression { env.ALREADY_BUILT != 'present' }
        anyOf { changeset 'services/**'; expression { params.FORCE_BUILD } }
      } }
      steps {
        // Two containers: quay.io/skopeo/stable carries no AWS CLI, so the ECR login password is
        // obtained in `awscli` and handed over through the shared /images volume.
        container('awscli') {
          sh '''
            set -eu
            # umask BEFORE the redirect -- the file must never exist world-readable, even briefly.
            umask 077
            aws ecr get-login-password --region "$AWS_REGION" > /images/ecr-password
          '''
        }
        container('skopeo') {
          // skopeo copies the EXACT file Trivy scanned. Nothing is rebuilt between scan and push,
          // so the scanned artifact and the pushed artifact are provably the same bytes -- a
          // stronger guarantee than the docker build/scan/push flow this replaces.
          sh '''
            set -eu
            # A trap, NOT a cleanup line at the bottom of the block. Under `set -eu` a failed copy
            # exits immediately and never reaches a trailing rm, leaving a live 12-hour registry
            # credential in a volume four containers share -- on exactly the failure path where it
            # matters most.
            trap 'rm -f /images/ecr-password /images/auth.json' EXIT

            # --authfile rather than --dest-creds: the latter puts the password in skopeo's argv,
            # readable via ps inside this container. Same pattern as scripts/mirror-trivy-db.sh.
            skopeo login --username AWS --password-stdin \
              --authfile /images/auth.json "$ECR_REGISTRY" < /images/ecr-password

            for svc in backend worker nginx backup; do
              skopeo copy --dest-authfile /images/auth.json \
                oci-archive:/images/$svc.tar \
                docker://"$ECR_REGISTRY/$CLUSTER_NAME-$svc:$TAG"
            done
          '''
        }
      }
    }

    // ArgoCD watches charts/voteball on master. This commit IS the deploy.
    stage('Bump image tag') {
      when { anyOf { changeset 'services/**'; expression { params.FORCE_BUILD } } }
      steps {
        // JOB CONFIGURATION REQUIREMENT: sshagent() below only takes effect if this workspace's
        // `origin` remote is an SSH URL. This repo's own GitHub remote is HTTPS
        // (https://github.com/Latnook/voteball.git); if the Jenkins job's SCM URL is left as
        // HTTPS, this credential is silently ignored and the push at the bottom of this stage
        // will fail (or hang on a credential prompt). The job MUST be configured with SCM URL
        // git@github.com:Latnook/voteball.git, and github.com must already be in the Jenkins
        // agent's known_hosts.
        sshagent(credentials: ['voteball-deploy-key']) {     // G4
          sh '''
            set -eu
            sed -i -E "s/^  tag: \\".*\\"/  tag: \\"$TAG\\"/" charts/voteball/values.yaml

            git config user.name  "jenkins"
            git config user.email "jenkins@voteball.local"
            git add charts/voteball/values.yaml

            if git diff --cached --quiet; then
              echo "values.yaml already names $TAG -- nothing to commit"
              exit 0
            fi

            # [skip ci] is written for continuity and documentation; the Guard stage is what
            # actually enforces it in Jenkins. Do not remove either.
            git commit -m "ci: image tag $TAG [skip ci]"

            # Same race scripts/deploy.sh hit (commits ed39db2, 1269ba8): origin/master may have
            # moved while this build ran. On a conflict, abort the rebase explicitly instead of
            # leaving the workspace mid-rebase, which would wedge the next build's checkout.
            git pull --rebase --autostash origin master || {
              echo "Rebase onto origin/master failed; aborting cleanly so the next build is not wedged."
              git rebase --abort || true
              exit 1
            }
            git push origin HEAD:master
          '''
        }
      }
    }
  }

  post {
    always {
      // The ECR token written to the shared volume in 'Build images' is a live registry credential.
      // The emptyDir dies with the pod, but a build that fails between writing it and finishing
      // should not leave it sitting there for the rest of the pod's life.
      container('awscli') {
        sh 'rm -rf /images/dockercfg || true'
      }
    }
    // G5's `docker image prune` is DELETED, not ported: it existed because the EC2 host was
    // persistent. A pod agent is destroyed after every build, so the disk cleans itself.
    failure {
      // G7 -- there is no email. This line is the record; check the UI.
      echo 'BUILD FAILED. No notification is sent (see docs/cicd.md, G7).'
    }
  }
}

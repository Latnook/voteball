// Voteball CI. Builds, scans and pushes the four images, then commits the new image tag to master.
// ArgoCD observes that commit and rolls the Deployments -- Jenkins never touches the cluster and
// holds no cluster credentials.
//
// Design: docs/design/2026-07-20-jenkins-migration-design.md  (G1-G7 referenced below)

pipeline {
  agent any

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

  environment {
    // AWS_REGION and CLUSTER_NAME are NOT set here. They are Jenkins global environment variables
    // (Manage Jenkins > System > Global properties), which is the direct equivalent of the GitHub
    // repo variables the retired pipeline used: identity stays out of the repository, so a fork
    // supplies its own. See CLAUDE.md -- a hardcoded region or prefix here would be a bug.
    // ECR_REGISTRY is derived at runtime in 'Resolve tag and account'; it cannot be built here
    // because the account ID is not known until then.
    TRIVY_IMAGE = 'aquasec/trivy:0.58.1'
    TRIVY_CACHE = '/var/lib/trivy-cache'
  }

  stages {

    // G2 -- Jenkins has no native [skip ci]. Without this, the pipeline's own tag-bump commit
    // retriggers it forever.
    stage('Guard: is this our own commit?') {
      steps {
        script {
          def msg = sh(script: 'git log -1 --pretty=%B', returnStdout: true).trim()
          def verdict = sh(script: "scripts/ci/should-skip-build.sh '${msg.replace("'", "'\\''")}'",
                           returnStdout: true).trim()
          if (verdict == 'skip') {
            currentBuild.result = 'NOT_BUILT'
            currentBuild.description = 'Skipped: tag-bump commit ([skip ci])'
            error('SKIP_CI')   // caught below; aborts without running anything else
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
          env.AWS_ACCOUNT_ID = sh(script: 'aws sts get-caller-identity --query Account --output text',
                                  returnStdout: true).trim()
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
          env.ALREADY_BUILT = sh(script: 'scripts/ci/images-exist.sh', returnStdout: true).trim()
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
        sh '''
          set -eu
          aws ecr get-login-password --region "$AWS_REGION" \
            | docker login --username AWS --password-stdin "$ECR_REGISTRY"
          docker build -t "$ECR_REGISTRY/$CLUSTER_NAME-backend:$TAG" services/backend
          docker build -t "$ECR_REGISTRY/$CLUSTER_NAME-worker:$TAG"  services/worker
          docker build -t "$ECR_REGISTRY/$CLUSTER_NAME-nginx:$TAG"   services/frontend
          docker build -t "$ECR_REGISTRY/$CLUSTER_NAME-backup:$TAG"  services/backup
        '''
      }
    }

    stage('Trivy scan') {
      when { allOf {
        expression { env.ALREADY_BUILT != 'present' }
        anyOf { changeset 'services/**'; expression { params.FORCE_BUILD } }
      } }
      steps {
        // The cache mount is load-bearing: without it the ~50MB vulnerability database is
        // re-downloaded on each of the four scans, every build, risking ghcr.io rate limits.
        sh '''
          set -eu
          for repo in backend worker nginx; do
            echo "--- trivy $CLUSTER_NAME-$repo (blocking) ---"
            docker run --rm \
              -v /var/run/docker.sock:/var/run/docker.sock \
              -v "$TRIVY_CACHE":/root/.cache/trivy \
              "$TRIVY_IMAGE" image --severity CRITICAL,HIGH --exit-code 1 --ignore-unfixed \
              "$ECR_REGISTRY/$CLUSTER_NAME-$repo:$TAG"
          done

          # The backup image is a third-party base (postgres:17-alpine + aws-cli) whose CVEs are
          # upstream Go-tooling issues outside this project's control: surface, do not block.
          echo "--- trivy $CLUSTER_NAME-backup (report only) ---"
          docker run --rm \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -v "$TRIVY_CACHE":/root/.cache/trivy \
            "$TRIVY_IMAGE" image --severity CRITICAL,HIGH --exit-code 0 --ignore-unfixed \
            "$ECR_REGISTRY/$CLUSTER_NAME-backup:$TAG"
        '''
      }
    }

    stage('Push to ECR') {
      when { allOf {
        expression { env.ALREADY_BUILT != 'present' }
        anyOf { changeset 'services/**'; expression { params.FORCE_BUILD } }
      } }
      steps {
        sh '''
          set -eu
          for repo in backend worker nginx backup; do
            docker push "$ECR_REGISTRY/$CLUSTER_NAME-$repo:$TAG"
          done
        '''
      }
    }

    // ArgoCD watches charts/voteball on master. This commit IS the deploy.
    stage('Bump image tag') {
      when { anyOf { changeset 'services/**'; expression { params.FORCE_BUILD } } }
      steps {
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
            # moved while this build ran.
            git pull --rebase --autostash origin master
            git push origin HEAD:master
          '''
        }
      }
    }
  }

  post {
    always {
      // G5 -- this host is persistent, unlike GitHub's runners.
      sh 'docker image prune -f || true'
    }
    failure {
      // G7 -- there is no email. This line is the record; check the UI.
      echo 'BUILD FAILED. No notification is sent (see docs/cicd.md, G7).'
    }
  }
}

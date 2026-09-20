#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Builds the app image and pushes it to ECR, creating the repository if needed.
#
#   ./scripts/build-push.sh --tag v1        # first image, before any stack exists
#   ./scripts/build-push.sh --tag v2        # the version you will canary
#
# Runs happily before the infrastructure exists: a service cannot start without
# an image, so the registry comes first. The repository name defaults to
# <project>-app, exactly what the Terraform, CloudFormation and CDK flavours
# expect.
#
# Images are built for linux/amd64 by default, so an image built on Apple silicon
# still runs on Fargate. Override with --platform if your tasks use ARM64.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

TAG=""
PROJECT="${PROJECT_NAME:-canary-lab}"
REPO=""
PLATFORM="linux/amd64"
APP_DIR="${REPO_ROOT}/app"
NO_CACHE=false
PUSH_LATEST=false
DRY_RUN=false
KEEP_LIFECYCLE=true

usage() {
  print_header_help "${BASH_SOURCE[0]}"
  cat <<'EOF'
Options
  --tag TAG         Image tag to build and push (required)
  --project NAME    Project prefix, used for the default repo name (default: canary-lab)
  --repo NAME       ECR repository name (default: <project>-app)
  --platform PLAT   Build platform (default: linux/amd64)
  --region REGION   AWS region
  --latest          Also push the tag as :latest
  --no-cache        Build without the layer cache
  --no-lifecycle    Skip applying the "keep 20 images" lifecycle policy
  --dry-run         Print what would happen and stop
  -h, --help        This help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    --region) export AWS_REGION="$2"; shift 2 ;;
    --latest) PUSH_LATEST=true; shift ;;
    --no-cache) NO_CACHE=true; shift ;;
    --no-lifecycle) KEEP_LIFECYCLE=false; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

[ -n "$TAG" ] || {
  err "--tag is required (for example: --tag v1)"
  usage >&2
  exit 2
}

require_tools aws docker jq

# Pick up the repository from a deployed stack when one exists, so the tag lands
# where the services actually look for it.
load_canary_env || true
if [ -z "$REPO" ]; then
  REPO="${CANARY_ECR_REPO:-${PROJECT}-app}"
fi

REGION="$(canary_region)"
ACCOUNT_ID="$(awsx sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
IMAGE_URI="${REGISTRY}/${REPO}:${TAG}"

GIT_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
BUILD_TIME="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

step "build plan"
info "repository   ${REPO}"
info "image        ${IMAGE_URI}"
info "platform     ${PLATFORM}"
info "context      ${APP_DIR}"
info "git sha      ${GIT_SHA}"

if [ "$DRY_RUN" = true ]; then
  warn "dry run, stopping here"
  exit 0
fi

[ -d "$APP_DIR" ] || die "app directory not found: ${APP_DIR}"

if ! docker info >/dev/null 2>&1; then
  die "the docker daemon is not reachable. Start Docker Desktop (or colima) and try again."
fi

# ------------------------------------------------------------- repository ----

step "making sure the ECR repository exists"
if awsx ecr describe-repositories --repository-names "$REPO" >/dev/null 2>&1; then
  ok "repository ${REPO} already exists"
else
  awsx ecr create-repository \
    --repository-name "$REPO" \
    --image-scanning-configuration scanOnPush=true \
    --image-tag-mutability MUTABLE \
    --tags "Key=Project,Value=${PROJECT}" "Key=Component,Value=ecs-canary-lab" >/dev/null
  ok "created repository ${REPO}"
fi

if [ "$KEEP_LIFECYCLE" = true ]; then
  LIFECYCLE_POLICY='{"rules":[{"rulePriority":1,"description":"Keep the 20 most recent images","selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":20},"action":{"type":"expire"}}]}'
  if awsx ecr put-lifecycle-policy \
    --repository-name "$REPO" \
    --lifecycle-policy-text "$LIFECYCLE_POLICY" >/dev/null 2>&1; then
    info "lifecycle policy applied (keep the 20 most recent images)"
  else
    warn "could not apply the lifecycle policy, continuing"
  fi
fi

# ------------------------------------------------------------------ build ----

step "building ${IMAGE_URI}"
BUILD_ARGS="--platform ${PLATFORM}"
[ "$NO_CACHE" = true ] && BUILD_ARGS="${BUILD_ARGS} --no-cache"

# shellcheck disable=SC2086  # BUILD_ARGS is a deliberate list of flags
docker build $BUILD_ARGS \
  --build-arg "APP_VERSION=${TAG}" \
  --build-arg "GIT_SHA=${GIT_SHA}" \
  --build-arg "BUILD_TIME=${BUILD_TIME}" \
  --tag "$IMAGE_URI" \
  "$APP_DIR"

if [ "$PUSH_LATEST" = true ]; then
  docker tag "$IMAGE_URI" "${REGISTRY}/${REPO}:latest"
fi

# ------------------------------------------------------------------- push ----

step "logging in to ${REGISTRY}"
awsx ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null
ok "authenticated"

step "pushing ${TAG}"
docker push "$IMAGE_URI"
if [ "$PUSH_LATEST" = true ]; then
  docker push "${REGISTRY}/${REPO}:latest"
fi

DIGEST="$(awsx ecr describe-images \
  --repository-name "$REPO" \
  --image-ids "imageTag=${TAG}" \
  --query 'imageDetails[0].imageDigest' \
  --output text 2>/dev/null || printf 'unknown')"

hr
ok "pushed ${IMAGE_URI}"
info "digest ${DIGEST}"
hr
info "next:"
info "  first deploy     ->  cd infra/terraform && terraform apply"
info "  canary rollout   ->  ./scripts/canary-deploy.sh --tag ${TAG}"

# Handy for CI: a machine readable line on stdout.
printf '%s\n' "$IMAGE_URI"

#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Builds the app image and pushes it to ECR, creating the repository if needed.
#
#   ./scripts/build-push.sh --tag v1        # first image, before any stack exists
#   ./scripts/build-push.sh --tag v2        # the version you will canary
#
# Runs happily before the infrastructure exists: a service cannot start without
# an image, so the registry comes first. The repository name defaults to
# <project>-app, which is what the Terraform stack expects.
#
# Built with `docker buildx` for linux/amd64,linux/arm64 by default and pushed
# as a single multi-arch manifest, so the same tag runs on Fargate regardless
# of var.cpu_architecture (X86_64 or ARM64) and regardless of whether the image
# was built on an Intel machine, Apple silicon or an ARM CI runner. Override
# with --platform for a single-arch build (faster, but must then match
# var.cpu_architecture or the task will fail to start).
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

TAG=""
PROJECT="${PROJECT_NAME:-canary-lab}"
REPO=""
PLATFORM="linux/amd64,linux/arm64"
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
  --platform PLAT   Comma separated platforms to build (default: linux/amd64,linux/arm64)
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

# --------------------------------------------------------------- buildx ----

# A multi-platform build must push straight to the registry: it produces one
# manifest per platform plus the manifest list joining them, and that list
# cannot be materialised as a single local image with `--load`. So login has
# to happen before the build, not after.
step "logging in to ${REGISTRY}"
awsx ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null
ok "authenticated"

step "checking the buildx builder"
if ! docker buildx inspect canary-lab-builder >/dev/null 2>&1; then
  docker buildx create --name canary-lab-builder --driver docker-container >/dev/null
  info "created buildx builder: canary-lab-builder"
fi
docker buildx use canary-lab-builder

# ------------------------------------------------------------------ build ----

step "building and pushing ${IMAGE_URI} (${PLATFORM})"
BUILD_ARGS=(--platform "$PLATFORM" --push --tag "$IMAGE_URI")
[ "$NO_CACHE" = true ] && BUILD_ARGS+=(--no-cache)
if [ "$PUSH_LATEST" = true ]; then
  BUILD_ARGS+=(--tag "${REGISTRY}/${REPO}:latest")
fi

docker buildx build "${BUILD_ARGS[@]}" \
  --build-arg "APP_VERSION=${TAG}" \
  --build-arg "GIT_SHA=${GIT_SHA}" \
  --build-arg "BUILD_TIME=${BUILD_TIME}" \
  "$APP_DIR"

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

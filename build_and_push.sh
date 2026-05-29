#!/bin/bash
# Build and push the archipelago-environment image using Kaniko.
# Runs a Kaniko Job in Kubernetes — no Docker daemon required.
#
# Usage:
#   export ENVIRONMENT_IMAGE=myregistry.io/archipelago-environment:latest
#   ./build_and_push.sh
#
#   # With explicit flags:
#   ./build_and_push.sh --image myregistry.io/archipelago-environment:latest
#   ./build_and_push.sh --image myregistry.io/archipelago-environment:latest --secret my-reg-secret
#
# Registry credentials (required for private registries):
#   Create a secret containing a Docker config JSON:
#
#   kubectl create secret generic kaniko-secret \
#     --from-file=config.json=$HOME/.docker/config.json \
#     --namespace=<your-namespace>
#
#   If your registry needs no auth, the secret is optional.
#
# How it works:
#   1. Tars the build context (environment/ + mcp_servers/) into /shared/...
#   2. Submits a Kaniko Job that mounts the same 'shared-data' PVC (ReadWriteMany)
#      so it can read the tar without any hostPath or node-pinning required
#   3. Kaniko builds the image from the tar and pushes it to the registry
#   4. Cleans up the Job and the temp build dir on exit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || echo "${K8S_NAMESPACE:-default}")"
IMAGE="${ENVIRONMENT_IMAGE:-}"
REGISTRY_SECRET="${REGISTRY_SECRET:-kaniko-secret}"
INSECURE="${INSECURE:-false}"   # set to true for registries without TLS
SHARED_PVC="${SHARED_PVC:-shared-data}"   # ReadWriteMany PVC that mounts /shared
BUILD_BASE="/shared/qywu/archipelago-builds"

# ── argument parsing ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)    IMAGE="$2";            shift 2 ;;
        --secret)   REGISTRY_SECRET="$2"; shift 2 ;;
        --insecure) INSECURE="true";       shift 1 ;;
        *)          echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$IMAGE" ]]; then
    echo "ERROR: Target image not set."
    echo "  export ENVIRONMENT_IMAGE=myregistry.io/archipelago-environment:latest"
    echo "  ./build_and_push.sh"
    exit 1
fi

# ── setup ───────────────────────────────────────────────────────────────────
BUILD_ID=$(python3 -c "import uuid; print(uuid.uuid4().hex[:8])")
BUILD_DIR="${BUILD_BASE}/${BUILD_ID}"
CONTEXT_TAR="${BUILD_DIR}/context.tar.gz"
JOB_NAME="kaniko-build-${BUILD_ID}"

mkdir -p "${BUILD_DIR}"

cleanup() {
    echo ""
    echo "Cleaning up..."
    kubectl delete job "${JOB_NAME}" \
        --namespace="${NAMESPACE}" --ignore-not-found --wait=false 2>/dev/null || true
    rm -rf "${BUILD_DIR}"
}
trap cleanup EXIT

echo "============================================================"
echo "ARCHIPELAGO ENVIRONMENT BUILD"
echo "============================================================"
echo "Image:      ${IMAGE}"
echo "Namespace:  ${NAMESPACE}"
echo "Build ID:   ${BUILD_ID}"
echo "Secret:     ${REGISTRY_SECRET} (optional)"
echo "Shared PVC: ${SHARED_PVC}"
echo "============================================================"

# ── build context ───────────────────────────────────────────────────────────
echo "[1/3] Creating build context..."

# Kaniko doesn't support --mount=type=secret, so generate Dockerfile.kaniko that
# replaces those mounts with ARG GITHUB_TOKEN and passes the token via --build-arg.
GITHUB_TOKEN="${GITHUB_TOKEN:-$(grep -A2 'qywu:' ~/.config/gh/hosts.yml 2>/dev/null | grep oauth_token | awk '{print $2}')}"
if [[ -n "${GITHUB_TOKEN}" ]]; then
    echo "      GitHub token: found"
else
    echo "      GitHub token: not found (private packages may fail)"
fi

python3 - "${SCRIPT_DIR}/environment/Dockerfile" <<'PYEOF'
import sys, re

src = open(sys.argv[1]).read()

# Insert ARG GITHUB_TOKEN="" right after the first FROM line
src = re.sub(
    r'(^FROM [^\n]+)',
    r'\1\nARG GITHUB_TOKEN=""',
    src, count=1, flags=re.MULTILINE
)

# Replace every RUN --mount=type=secret,id=github_token,required=false
# ... export UV_GITHUB_TOKEN=$(cat /run/secrets/github_token 2>/dev/null)
# with just: RUN export UV_GITHUB_TOKEN="${GITHUB_TOKEN}"
src = re.sub(
    r'RUN --mount=type=secret,id=github_token,required=false '
    r'export UV_GITHUB_TOKEN=\$\(cat /run/secrets/github_token 2>/dev/null\)',
    'RUN export UV_GITHUB_TOKEN="${GITHUB_TOKEN}"',
    src
)

open('environment/Dockerfile.kaniko', 'w').write(src)
print("      Dockerfile.kaniko generated")
PYEOF

tar -czf "${CONTEXT_TAR}" \
    -C "${SCRIPT_DIR}" \
    --exclude='.git' \
    --exclude='*/.venv' \
    --exclude='*/node_modules' \
    --exclude='examples/hugging_face_task/output' \
    environment/ mcp_servers/

echo "      Context size: $(du -sh "${CONTEXT_TAR}" | cut -f1)"

# ── Kaniko Job ──────────────────────────────────────────────────────────────
echo "[2/3] Submitting Kaniko build job: ${JOB_NAME}"

# Build the extra --insecure arg list
INSECURE_ARGS="[]"
if [[ "${INSECURE}" == "true" ]]; then
    INSECURE_ARGS='["--insecure", "--insecure-pull"]'
fi

JOB_JSON=$(python3 -c "
import json

extra_args = ${INSECURE_ARGS}
# Context tar lives at /shared/qywu/archipelago-builds/{build_id}/context.tar.gz
# The shared PVC mounts /shared, so inside Kaniko it's at /shared/...
args = [
    '--dockerfile=environment/Dockerfile.kaniko',
    '--context=tar:///shared/qywu/archipelago-builds/${BUILD_ID}/context.tar.gz',
    '--destination=${IMAGE}',
    '--snapshot-mode=redo',
    '--log-format=text',
    '--verbosity=info',
    '--build-arg=GITHUB_TOKEN=${GITHUB_TOKEN}',
] + extra_args

job = {
    'apiVersion': 'batch/v1',
    'kind': 'Job',
    'metadata': {'name': '${JOB_NAME}', 'namespace': '${NAMESPACE}'},
    'spec': {
        'ttlSecondsAfterFinished': 300,
        'backoffLimit': 0,
        'template': {
            'spec': {
                'restartPolicy': 'Never',
                'containers': [{
                    'name': 'kaniko',
                    'image': 'gcr.io/kaniko-project/executor:latest',
                    'args': args,
                    'volumeMounts': [
                        {'name': 'shared',        'mountPath': '/shared'},
                        {'name': 'docker-config', 'mountPath': '/kaniko/.docker'},
                    ],
                }],
                'volumes': [
                    {
                        'name': 'shared',
                        'persistentVolumeClaim': {'claimName': '${SHARED_PVC}'},
                    },
                    {
                        'name': 'docker-config',
                        'secret': {'secretName': '${REGISTRY_SECRET}', 'optional': True},
                    },
                ],
            }
        },
    },
}
print(json.dumps(job))
")

echo "${JOB_JSON}" | kubectl apply -f - --namespace="${NAMESPACE}"

# ── wait and stream logs ────────────────────────────────────────────────────
echo "[3/3] Waiting for build to complete..."
echo "      (first build may take 15-30 min due to image size)"
echo ""

# Stream logs as they arrive
POD=""
for i in $(seq 1 60); do
    POD=$(kubectl get pods -l "job-name=${JOB_NAME}" \
        --namespace="${NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [[ -n "$POD" ]] && break
    sleep 2
done

if [[ -n "$POD" ]]; then
    kubectl logs "${POD}" --namespace="${NAMESPACE}" -f 2>/dev/null || true
fi

# Wait for the Job to reach a terminal state
if ! kubectl wait "job/${JOB_NAME}" \
    --for=condition=Complete \
    --namespace="${NAMESPACE}" \
    --timeout=60m 2>/dev/null; then
    echo ""
    echo "ERROR: Build job failed or timed out."
    echo "Last 50 log lines:"
    kubectl logs -l "job-name=${JOB_NAME}" --namespace="${NAMESPACE}" --tail=50 || true
    exit 1
fi

echo ""
echo "============================================================"
echo "DONE"
echo "Image pushed: ${IMAGE}"
echo ""
echo "To run an eval:"
echo "  export ENVIRONMENT_IMAGE=${IMAGE}"
echo "  export OPENAI_API_KEY=..."
echo "  cd examples/hugging_face_task && ./run.sh"
echo "============================================================"

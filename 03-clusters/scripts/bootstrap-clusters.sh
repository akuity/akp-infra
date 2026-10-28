#!/usr/bin/env bash
set -euo pipefail

# Bootstraps one or more local Kubernetes clusters (k3d, kind, or minikube)
# and writes a standalone kubeconfig for each to .kubeconfigs/<name>.yaml,
# ready for the `clusters` map in terraform.tfvars.
#
# None of the three providers touch your real default kubeconfig
# (~/.kube/config) or its current-context: each cluster is created/queried
# through a provider-specific mechanism that writes to a throwaway location,
# and only the extracted, minified result lands in .kubeconfigs/.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIGS_DIR="$SCRIPT_DIR/../.kubeconfigs"

PROVIDERS=(k3d kind minikube)
DELETE=false
PROVIDER=""
CLUSTERS=()

# Scratch files (some hold live cluster credentials) get tracked here and
# cleaned up on any exit, including a failure partway through a create.
TMP_FILES=()
cleanup() {
  local f
  for f in "${TMP_FILES[@]:-}"; do
    [[ -n "$f" ]] && rm -f "$f"
  done
  return 0 # a trap's exit status overrides the script's real one -- never let this fail it
}
trap cleanup EXIT

new_tmp() {
  local f
  f="$(mktemp)"
  TMP_FILES+=("$f")
  echo "$f"
}

usage() {
  cat <<'EOF'
Usage: bootstrap-clusters.sh [--provider k3d|kind|minikube] [--delete] [NAME...]

Creates local Kubernetes clusters and writes a standalone kubeconfig for each
to .kubeconfigs/<NAME>.yaml, matching what terraform.tfvars expects.

  NAME...            Cluster names to create (default: demo1)
  --provider VALUE   k3d, kind, or minikube (default: auto-detect, in that order)
  --delete           Tear down the named cluster(s) and remove their kubeconfigs
  -h, --help         Show this help

Examples:
  ./bootstrap-clusters.sh                       # demo1 via auto-detected provider
  ./bootstrap-clusters.sh demo1 demo2           # both, opt-in
  ./bootstrap-clusters.sh --provider minikube demo1
  ./bootstrap-clusters.sh --delete demo1 demo2

Already have Kubernetes enabled in OrbStack? Skip this script -- OrbStack is a
single shared cluster, not something this script creates per-name. Extract it
directly for use as demo1:

  kubectl config view --raw --minify --context=orbstack > .kubeconfigs/demo1.yaml
EOF
}

log() { echo ">> $*" >&2; }
die() { echo "error: $*" >&2; exit 1; }

detect_provider() {
  local p
  for p in "${PROVIDERS[@]}"; do
    if command -v "$p" >/dev/null 2>&1; then
      echo "$p"
      return
    fi
  done
  die "none of ${PROVIDERS[*]} found in PATH. Install one, e.g.: brew install k3d"
}

cluster_exists() {
  local provider=$1 name=$2
  case "$provider" in
    k3d)
      k3d cluster list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$name"
      ;;
    kind)
      kind get clusters 2>/dev/null | grep -qx "$name"
      ;;
    minikube)
      # minikube start is idempotent, so existence here is informational only.
      minikube status -p "$name" >/dev/null 2>&1
      ;;
  esac
}

create_cluster() {
  local provider=$1 name=$2
  if cluster_exists "$provider" "$name"; then
    # Existing but possibly stopped (e.g. after a reboot) -- k3d tracks
    # clusters independently of their running state, so "exists" doesn't
    # mean "reachable". `k3d cluster start` is a safe no-op if it's already
    # running.
    if [[ "$provider" == "k3d" ]]; then
      log "$provider cluster '$name' already exists, ensuring it's started"
      k3d cluster start "$name" --wait
    elif [[ "$provider" == "kind" ]]; then
      # kind has no start/stop concept of its own, so a container stopped
      # outside kind's control (e.g. a Docker Desktop restart) can't be
      # revived here. If extraction below fails or produces an unreachable
      # kubeconfig, recreate it: kind delete cluster --name <name>
      log "$provider cluster '$name' already exists, skipping create"
    else
      log "$provider cluster '$name' already exists, skipping create"
    fi
    return
  fi
  log "creating $provider cluster '$name'"
  case "$provider" in
    k3d)
      k3d cluster create "$name" --wait \
        --kubeconfig-update-default=false --kubeconfig-switch-context=false
      ;;
    kind)
      local scratch
      scratch="$(new_tmp)"
      kind create cluster --name "$name" --kubeconfig "$scratch" --wait 60s
      rm -f "$scratch"
      ;;
    minikube)
      : # created lazily in extract_kubeconfig via `minikube start`
      ;;
  esac
}

extract_kubeconfig() {
  local provider=$1 name=$2 out=$3
  case "$provider" in
    k3d)
      k3d kubeconfig get "$name" > "$out"
      ;;
    kind)
      kind get kubeconfig --name "$name" > "$out"
      ;;
    minikube)
      local scratch
      scratch="$(new_tmp)"
      KUBECONFIG="$scratch" minikube start -p "$name" >&2
      KUBECONFIG="$scratch" kubectl config view --raw --minify --context="$name" > "$out"
      rm -f "$scratch"
      ;;
  esac
}

delete_cluster() {
  local provider=$1 name=$2
  log "deleting $provider cluster '$name'"
  case "$provider" in
    k3d) k3d cluster delete "$name" ;;
    kind) kind delete cluster --name "$name" ;;
    minikube) minikube delete -p "$name" ;;
  esac
  rm -f "$KUBECONFIGS_DIR/$name.yaml"
}

bootstrap_one() {
  local provider=$1 name=$2
  create_cluster "$provider" "$name"

  local tmp_out
  tmp_out="$(new_tmp)"
  extract_kubeconfig "$provider" "$name" "$tmp_out"
  chmod 600 "$tmp_out"
  mv "$tmp_out" "$KUBECONFIGS_DIR/$name.yaml"
  log "wrote $KUBECONFIGS_DIR/$name.yaml"
}

# ── arg parsing ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider)
      PROVIDER="${2:?--provider requires a value}"
      shift 2
      ;;
    --delete)
      DELETE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      die "unknown flag: $1 (see --help)"
      ;;
    *)
      CLUSTERS+=("$1")
      shift
      ;;
  esac
done

if [[ -n "$PROVIDER" ]]; then
  case " ${PROVIDERS[*]} " in
    *" $PROVIDER "*) ;;
    *) die "--provider must be one of: ${PROVIDERS[*]}" ;;
  esac
else
  PROVIDER="$(detect_provider)"
  log "auto-detected provider: $PROVIDER"
fi

command -v "$PROVIDER" >/dev/null 2>&1 \
  || die "'$PROVIDER' not found in PATH. Install it, e.g.: brew install $PROVIDER"

if [[ "$PROVIDER" == "minikube" ]]; then
  command -v kubectl >/dev/null 2>&1 || die "kubectl is required for the minikube provider"
fi

if [[ ${#CLUSTERS[@]} -eq 0 ]]; then
  CLUSTERS=(demo1)
fi

mkdir -p "$KUBECONFIGS_DIR"

for name in "${CLUSTERS[@]}"; do
  if $DELETE; then
    delete_cluster "$PROVIDER" "$name"
  else
    bootstrap_one "$PROVIDER" "$name"
  fi
done

if ! $DELETE; then
  log "done. Point terraform.tfvars's clusters map at .kubeconfigs/<name>.yaml -- see terraform.tfvars.example"
fi

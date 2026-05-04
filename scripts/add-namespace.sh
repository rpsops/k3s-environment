#!/usr/bin/env bash
# Add a new gitops namespace entry to gitops-config.yaml and write the
# matching PAT credentials Secret manifest to .local/.
#
# Required environment:
#   NAME          DNS-1123 label, used as namespace name and entry name
#   URL           HTTPS clone URL of the gitops repo
#   GITOPS_USER   git-host username (or PAT owner)
#   GITOPS_TOKEN  Personal Access Token (repo read+write)
#
# Optional environment:
#   BRANCH            defaults to "main"
#   INTERVAL          defaults to "1m"
#   PATH_IN_REPO      defaults to "./"
#   IMAGE_AUTOMATION  "true" enables Flux ImageUpdateAutomation for this entry
#                     (defaults to "false")
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

REQUIRED=(NAME URL GITOPS_USER GITOPS_TOKEN)
MISSING=()
for v in "${REQUIRED[@]}"; do
  if [ -z "${!v:-}" ]; then MISSING+=("$v"); fi
done
if [ ${#MISSING[@]} -gt 0 ]; then
  cat >&2 <<EOF
Usage:
  make namespace NAME=<ns> URL=<https-clone-url> \\
                 GITOPS_USER=<user> GITOPS_TOKEN=<pat> \\
                 [BRANCH=main] [INTERVAL=1m] [PATH_IN_REPO=./] \\
                 [IMAGE_AUTOMATION=true]

Missing: ${MISSING[*]}
EOF
  exit 1
fi

BRANCH="${BRANCH:-main}"
INTERVAL="${INTERVAL:-1m}"
PATH_IN_REPO="${PATH_IN_REPO:-./}"
IMAGE_AUTOMATION="${IMAGE_AUTOMATION:-false}"

case "$IMAGE_AUTOMATION" in
  true|false) ;;
  *) die "IMAGE_AUTOMATION must be 'true' or 'false' (got '$IMAGE_AUTOMATION')." ;;
esac

# DNS-1123 label
if ! [[ "$NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  die "NAME='$NAME' is not a valid DNS-1123 label (lowercase alphanumerics and '-')."
fi

command -v yq >/dev/null   || die "yq not installed (run 'make setup')."
command -v kubectl >/dev/null || die "kubectl not installed (run 'make setup')."

CFG="gitops-config.yaml"
[ -f "$CFG" ] || die "$CFG not found (run from the repo root)."

# Ensure namespaces is a list (may be null/empty)
if ! yq -e '.namespaces // [] | tag == "!!seq"' "$CFG" >/dev/null 2>&1; then
  die "$CFG: 'namespaces' must be a list (got: $(yq '.namespaces | tag' "$CFG"))."
fi

# Reject duplicates
if [ "$(NAME="$NAME" yq '[.namespaces[]? | select(.name == strenv(NAME))] | length' "$CFG")" != "0" ]; then
  die "An entry with name='$NAME' already exists in $CFG."
fi

# Append the new entry
NAME="$NAME" URL="$URL" BRANCH="$BRANCH" INTERVAL="$INTERVAL" P="$PATH_IN_REPO" \
IA="$IMAGE_AUTOMATION" \
  yq -i '
    .namespaces = (.namespaces // []) + [{
      "name":            strenv(NAME),
      "url":             strenv(URL),
      "branch":          strenv(BRANCH),
      "interval":        strenv(INTERVAL),
      "path":            strenv(P),
      "imageAutomation": (strenv(IA) == "true")
    }]
  ' "$CFG"

echo "Added entry '$NAME' to $CFG."

# Write credentials manifest
mkdir -p .local
OUT=".local/gitops-credentials-${NAME}.yaml"
kubectl create secret generic "gitops-credentials-${NAME}" \
  -n flux-system \
  --from-literal=username="$GITOPS_USER" \
  --from-literal=password="$GITOPS_TOKEN" \
  --dry-run=client -o yaml > "$OUT"
chmod 600 "$OUT"
echo "Wrote $OUT (mode 600)."

cat <<EOF

Next steps:
  make up            # apply Namespace + GitRepository + Kustomization for '$NAME'
  make sync-apps     # force-reconcile after the cluster is running
EOF

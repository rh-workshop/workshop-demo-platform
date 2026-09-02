#!/usr/bin/env bash
# Valida que TODOS los overlays del repo renderizan.
#
# Los overlays de acm/ usan el plugin PolicyGenerator, que no viene con kustomize:
# sin el, `kustomize build` falla con "external plugins disabled" y nadie puede
# revisar un PR de politicas antes de mergearlo. El binario se extrae de la imagen
# de ACM que ya corre en el hub (misma version que reconcilia en produccion, asi
# que lo que se valida aqui es lo que se aplicara).
#
# Uso:
#   ./scripts/validate-kustomize.sh            # valida todo
#   SKIP_POLICY_GENERATOR=1 ./scripts/...      # omite acm/ (sin acceso al hub)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_HOME="${KUSTOMIZE_PLUGIN_HOME:-${TMPDIR:-/tmp}/kustomize-plugins}"
PLUGIN_PATH="${PLUGIN_HOME}/policy.open-cluster-management.io/v1/policygenerator/PolicyGenerator"

# Descarga el PolicyGenerator desde el pod de subscription del hub (requiere `oc login`).
fetch_policy_generator() {
  local pod
  pod="$(oc get pods -n open-cluster-management -o name 2>/dev/null \
        | grep -i 'hub-subscription' | head -1 | sed 's|pod/||')"
  [ -n "$pod" ] || { echo "  no hay pod de subscription en el hub (¿oc login?)"; return 1; }
  mkdir -p "$(dirname "$PLUGIN_PATH")"
  # base64 y no `oc cp`: la imagen de ACM no trae `tar`, que es lo que oc cp necesita.
  oc exec -n open-cluster-management "$pod" -- \
     base64 /etc/kustomize/plugin/policy.open-cluster-management.io/v1/policygenerator/PolicyGenerator \
     2>/dev/null | base64 -d > "$PLUGIN_PATH"
  chmod +x "$PLUGIN_PATH"
}

if [ "${SKIP_POLICY_GENERATOR:-0}" != "1" ] && [ ! -x "$PLUGIN_PATH" ]; then
  echo "Obteniendo PolicyGenerator del hub..."
  fetch_policy_generator || { echo "  -> se omite acm/"; SKIP_POLICY_GENERATOR=1; }
fi

# El binario es Linux/amd64: en macOS o ARM hay que renderizar dentro de un contenedor.
KUSTOMIZE_RUNNER=(kustomize build --enable-alpha-plugins)
if [ "${SKIP_POLICY_GENERATOR:-0}" != "1" ] && [ "$(uname -s)/$(uname -m)" != "Linux/x86_64" ]; then
  echo "Plataforma $(uname -s)/$(uname -m): el plugin es Linux/amd64, se usa contenedor para acm/"
  USE_CONTAINER=1
fi

fail=0 total=0
while IFS= read -r dir; do
  total=$((total + 1))
  printf '%-64s ' "${dir#"$REPO_ROOT"/}"

  if [[ "$dir" == *"/acm/"* ]]; then
    if [ "${SKIP_POLICY_GENERATOR:-0}" = "1" ]; then echo "OMITIDO (sin plugin)"; continue; fi
    if [ "${USE_CONTAINER:-0}" = "1" ]; then
      if docker run --rm --platform linux/amd64 \
           -v "$REPO_ROOT":/repo:ro -v "$PLUGIN_HOME":/plugin:ro \
           -e KUSTOMIZE_PLUGIN_HOME=/plugin \
           registry.access.redhat.com/ubi9/ubi-minimal:latest sh -c '
             microdnf install -y tar gzip >/dev/null 2>&1
             curl -sL https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv5.8.1/kustomize_v5.8.1_linux_amd64.tar.gz \
               | tar xz -C /usr/local/bin 2>/dev/null
             kustomize build --enable-alpha-plugins "/repo/'"${dir#"$REPO_ROOT"/}"'"' >/dev/null 2>&1
      then echo OK; else echo FAIL; fail=$((fail + 1)); fi
      continue
    fi
  fi

  if KUSTOMIZE_PLUGIN_HOME="$PLUGIN_HOME" "${KUSTOMIZE_RUNNER[@]}" "$dir" >/dev/null 2>/tmp/kustomize-err.txt; then
    echo OK
  else
    echo FAIL; sed 's/^/    /' /tmp/kustomize-err.txt | head -3; fail=$((fail + 1))
  fi
done < <(find "$REPO_ROOT" -name kustomization.yaml -not -path '*/.git/*' -exec dirname {} \; | sort)

echo
echo "Total: $total | fallos: $fail"
exit $(( fail > 0 ? 1 : 0 ))

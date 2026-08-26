# Pipelines del workshop (CI/CD de imágenes)

Dos pipelines de Tekton en el namespace `workshop-demo-dev`:

- `ci-build-image` — clona el monorepo de aplicación, construye la imagen con
  buildah, la publica con su tag inmutable `git-<sha-corto>`, la **firma** con
  cosign, la **escanea** con ACS (puerta de calidad), avanza el tag **móvil**
  (`dev`) y promociona el digest al repo de configuración (git push).
- `cd-deploy-application` — clona el repo de configuración, valida que el
  overlay renderiza (`oc kustomize`) y pide a Argo CD la sincronización de la
  Application (`app-demo-service-dev`).

La definición declarativa vive en `gitops/` (base + overlay `dev`); las
ejecuciones (`PipelineRun`) viven en `runs/` y se lanzan con `oc create`.

```bash
# Instalar o actualizar los pipelines y las tasks
oc apply -k workshop-pipelines/gitops/overlays/dev

# Lanzar el CI del demo-service (editar antes los CHANGE_ME del fichero)
oc create -f workshop-pipelines/runs/pipelinerun-ci-build-image.yaml -n workshop-demo-dev

# Lanzar el CD a mano (normalmente lo dispara el push del CI)
oc create -f workshop-pipelines/runs/pipelinerun-cd-deploy-application.yaml -n workshop-demo-dev
```

## Secretos y config requeridos (NUNCA en Git)

El CI monta cuatro workspaces de tipo Secret y el CD necesita la pareja
ConfigMap/Secret que exige la ClusterTask `argocd-task-sync-and-wait`. Todos se
crean a mano en el cluster; en Git solo queda su NOMBRE.

### 1. `quay-push-credentials` — robot/usuario del registro (push, firma y tag móvil)

```bash
# Docker config con la credencial del registro; lo usan buildah, cosign y skopeo
podman login <QUAY_HOST> --username <usuario> --password '<password>' --authfile /tmp/quay-auth.json
oc create secret generic quay-push-credentials -n workshop-demo-dev \
  --from-file=config.json=/tmp/quay-auth.json
rm /tmp/quay-auth.json
```

### 2. `cosign-signing-key` — llavero de firma

```bash
# Genera el par de llaves DIRECTAMENTE como Secret de Kubernetes (nunca toca el disco ni Git)
# Claves resultantes: cosign.key, cosign.pub y cosign.password
COSIGN_PASSWORD='<frase-secreta>' cosign generate-key-pair k8s://workshop-demo-dev/cosign-signing-key
```

La clave PÚBLICA (`cosign.pub`) se registra además en la SignatureIntegration
de ACS para que la política BUILD "firma exigida" pueda verificarla.

### 3. `acs-pipeline-credentials` — token de ACS Central para roxctl

```bash
# El token se crea en Central: Platform Configuration > Integrations > API Token, rol "Continuous Integration"
# La CA de Central sale del propio Secret del namespace stackrox
oc get secret central-tls -n stackrox -o jsonpath='{.data.ca\.pem}' | base64 -d > /tmp/central-ca.pem
oc create secret generic acs-pipeline-credentials -n workshop-demo-dev \
  --from-literal=rox-api-token='<token>' --from-file=ca.pem=/tmp/central-ca.pem
rm /tmp/central-ca.pem
```

### 4. `git-credentials` — push del CI al repo de configuración

```bash
# Formato "basic-auth" que entiende la ClusterTask git-cli (.gitconfig + .git-credentials)
cat > /tmp/gitconfig <<'EOF'
[credential "https://github.com"]
  helper = store
EOF
printf 'https://<usuario>:<token-PAT>@github.com\n' > /tmp/git-credentials
oc create secret generic git-credentials -n workshop-demo-dev \
  --from-file=.gitconfig=/tmp/gitconfig --from-file=.git-credentials=/tmp/git-credentials
rm /tmp/gitconfig /tmp/git-credentials
```

### 5. CD: `argocd-env-configmap` + `argocd-env-secret`

La ClusterTask `argocd-task-sync-and-wait` lee la conexión a Argo CD de esta
pareja (nombres fijos, en el namespace donde corre el run):

```bash
ARGO_HOST=$(oc get route -n openshift-gitops openshift-gitops-server -o jsonpath='{.spec.host}')
ARGO_PASS=$(oc get secret openshift-gitops-cluster -n openshift-gitops -o jsonpath='{.data.admin\.password}' | base64 -d)
oc create configmap argocd-env-configmap -n workshop-demo-dev \
  --from-literal=ARGOCD_SERVER="$ARGO_HOST" --from-literal=ARGOCD_OPTS="--grpc-web"
oc create secret generic argocd-env-secret -n workshop-demo-dev \
  --from-literal=ARGOCD_USERNAME=admin --from-literal=ARGOCD_PASSWORD="$ARGO_PASS"
```

> En un entorno real la cuenta sería un usuario técnico de Argo CD con RBAC
> mínimo (solo `sync`/`get` sobre la Application), no el admin.

## La puerta de calidad del escaneo

Dos parámetros del pipeline la gobiernan:

- `scan-severity-threshold` (LOW/MODERATE/IMPORTANT/CRITICAL): qué CVEs se
  destacan en el informe y, en modo corte, cuáles tumban el run.
- `scan-fail-on-violation` (default `"false"`): con `"false"` el escaneo
  INFORMA (tabla de CVEs + listado de los que cruzan el umbral) y el pipeline
  CONTINÚA; con `"true"` el run queda en `Failed` sin avanzar el tag móvil ni
  promocionar el digest.

El default `"false"` es una decisión consciente para el workshop: la base UBI9
arrastra CVEs IMPORTANT sin parche disponible (curl-minimal, libblkid,
openssl-libs...) y un corte en IMPORTANT dejaría el pipeline en rojo permanente.
En producción se recomienda `"true"` con umbral `CRITICAL` (o IMPORTANT con
excepciones gestionadas vía deferral en ACS).

Ambos modos están validados en vivo: con `"true"` y umbral LOW el run terminó
`Failed` en `scan-image` y NO corrieron `advance-moving-tag`, `set-image-digest`
ni `push-config`; con `"false"` y 4 IMPORTANT presentes el run terminó
`Succeeded` con el informe completo en los logs.

## Estado del CD (validado en vivo)

El pipeline `cd-deploy-application` funciona hasta la sincronización: login a
Argo CD con la pareja `argocd-env-*`, validación del overlay y `argocd app sync`
sobre `app-demo-service-dev` (con auto-sync activo hay que sincronizar a la
revisión que sigue la Application; `HEAD` lo rechaza). El paso final
`argocd app wait --health` solo converge si la imagen promocionada es
descargable por el cluster: hoy el overlay de la app reescribe la imagen al
registro interno (`app-workshop`) mientras el CI publica en Quay
(`company/demo-service`), así que el digest promocionado no existe donde el
kubelet lo busca y el rollout queda en ImagePullBackOff. Hay que alinear el
`newName` del overlay con el repositorio de Quay (y dar al namespace un pull
secret de Quay), o publicar el CI en el registro que consumen los overlays.

## Verificación tras un run del CI

```bash
# Tags y digest: el inmutable git-<sha> y el móvil dev deben apuntar al MISMO digest
skopeo inspect --format '{{.Digest}}' docker://<QUAY_HOST>/company/demo-service:git-<sha>
skopeo inspect --format '{{.Digest}}' docker://<QUAY_HOST>/company/demo-service:dev

# Firma: verificación con la clave pública del llavero
oc get secret cosign-signing-key -n workshop-demo-dev -o jsonpath='{.data.cosign\.pub}' | base64 -d > /tmp/cosign.pub
cosign verify --key /tmp/cosign.pub --insecure-ignore-tlog <QUAY_HOST>/company/demo-service@<digest>

# Escaneo y políticas: lo mismo que ejecuta la task image-scan
roxctl --token-file <token> -e central.stackrox.svc:443 image check --image <QUAY_HOST>/company/demo-service@<digest>
```

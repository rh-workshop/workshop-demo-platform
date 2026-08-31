# Pipelines del workshop (CI/CD de imágenes)

Tres pipelines de Tekton en el namespace `workshop-demo-dev`:

- `ci-build-image` — clona el monorepo de aplicación (clone COMPLETO, con
  historial) y pasa la **puerta de código** en paralelo: **tests unitarios** de
  Go con cobertura (`go-test`, tolera la ausencia de tests e informa),
  **detección de secretos** en árbol e historial (`secret-scan` con gitleaks,
  falla CERRADO por defecto) y **SAST** (`code-scan` con semgrep). Solo si las
  tres pasan construye la imagen con buildah, la publica con su tag ancla, el
  inmutable `git-<sha-corto>`, le aplica el **tag de versión GitFlow** derivado
  de la rama (ver "Versionado por rama"), la **firma** con cosign, genera y
  atesta su **SBOM** (syft + `cosign attest`, en paralelo con firma y escaneo),
  la **escanea** con ACS (puerta de calidad), evalúa el **overlay renderizado**
  contra las políticas DEPLOY de ACS (`deployment-check`, roxctl) y promociona
  el digest al repo de configuración (git push). **Idempotencia:** si el tag
  `git-<sha>` ya existe en el registro, el pipeline NO reconstruye — reconstruir
  el mismo commit daría otro digest, movería el tag y dejaría huérfano el
  anterior (Quay lo purga y el rollback por Git muere en `ImagePullBackOff`).
  En su lugar salta el build, reutiliza el digest existente y CONTINÚA con
  firma, escaneo y promoción: relanzar el pipeline sobre el mismo commit es
  seguro y sirve para re-promocionar o para completar un run que falló a medias.
  No hay tags móviles: los tags de versión son alias INMUTABLES del mismo
  digest y todo despliegue va por digest.
- `cd-deploy-application` — clona el repo de configuración, valida que el
  overlay renderiza (`oc kustomize`) y pide a Argo CD un sync explícito de la
  Application (`app-demo-service-dev`) esperando a que quede Healthy.
- `promote-image` — promociona una imagen YA validada entre organizaciones de
  Quay. Antes de copiar **verifica la firma cosign en el origen** (`verify-signature`,
  `"true"` por defecto): sin esa puerta, quien tiene la credencial de promoción
  podía subir a prod cualquier digest de la organización origen, incluido uno
  colocado a mano. Hacia prod/contingencia se suma la **puerta de procedencia**
  (`require-release-provenance`, `"true"` en esos runs): el commit que la imagen
  lleva estampado en `org.opencontainers.image.revision` (cubierto por el digest
  que cosign firma) debe existir en el repo de aplicación, ser ancestro de
  `main` y llevar un tag semver de git — a prod solo entran RELEASES, no builds
  de una rama cualquiera. La firma prueba QUIÉN construyó; la procedencia, DESDE
  DÓNDE. Copia con `skopeo copy --all` (manifiesto completo, CONSERVA el
  digest: lo validado en test es byte a byte lo que corre en prod) **y arrastra la
  firma y la atestación SBOM**, que cosign publica como tags aparte
  (`sha256-<hex>.sig` / `.att`) y por tanto no viajan con el manifiesto — sin
  copiarlas, la imagen llegaba desnuda a prod y la política de admisión que exige
  firma la habría rechazado. Verifica el
  digest en destino y fija ese MISMO digest en el overlay del entorno destino
  (`kustomize edit set image` + push). Un solo pipeline parametrizado sirve
  para dev→test y test→prod: la barrera hacia prod la pone el **RBAC**, no el
  pipeline (ver "Modelo de promoción" más abajo).

La definición declarativa vive en `gitops/` (base + overlay `dev`); las
ejecuciones (`PipelineRun`) viven en `runs/` y se lanzan con `oc create`.

```bash
# Instalar o actualizar los pipelines y las tasks
oc apply -k workshop-pipelines/gitops/overlays/dev

# Lanzar el CI del demo-service (editar antes los CHANGE_ME del fichero)
oc create -f workshop-pipelines/runs/pipelinerun-ci-build-image.yaml -n workshop-demo-dev

# Lanzar el CD a mano (no hay Triggers: SIEMPRE se lanza a mano; ver "Rol del CD")
oc create -f workshop-pipelines/runs/pipelinerun-cd-deploy-application.yaml -n workshop-demo-dev

# Promocionar por la cadena dev -> test -> prod -> contingencia, un salto por
# ejecución (editar antes los CHANGE_ME de cada fichero). Los tres runs invocan
# el MISMO pipeline: solo cambian source-org, target-org y el overlay destino.
oc create -f workshop-pipelines/runs/pipelinerun-promote-dev-to-test.yaml -n workshop-demo-dev
oc create -f workshop-pipelines/runs/pipelinerun-promote-test-to-prod.yaml -n workshop-demo-dev
oc create -f workshop-pipelines/runs/pipelinerun-promote-prod-to-contingencia.yaml -n workshop-demo-dev
```

## Versionado por rama (GitFlow)

El despliegue va SIEMPRE por digest — eso no cambia. Lo que añade el versionado
es un **alias legible** del mismo digest, derivado de la rama que el CI clonó
(parámetro `revision`), aplicado con `skopeo copy` dentro del mismo repositorio
(no reconstruye: el digest se conserva). El ancla de idempotencia sigue siendo
`git-<sha7>`, que se publica en TODOS los casos.

| Revisión clonada | Tag de versión | Ejemplo |
|---|---|---|
| `feature/*`, PRs, `main` sin tag | ninguno (solo el ancla) | `git-3fa9c21` |
| `develop` | `<version>-SNAPSHOT-<sha7>` | `1.4.0-SNAPSHOT-3fa9c21` |
| `release/X.Y.Z` | `X.Y.Z-rc<n>` | `1.4.0-rc2` |
| tag `vX.Y.Z` (release desde `main`) | `X.Y.Z` | `1.4.0` |

- **De dónde sale `<version>`**: del fichero `VERSION` en la raíz del repo de
  aplicación si existe; si no, del parámetro `version` del pipeline (default
  `0.1.0`). En `release/X.Y.Z` manda el nombre de la rama.
- **El `<n>` del rc** lo decide el registro: el mayor `X.Y.Z-rc*` existente más
  uno. Con idempotencia: si el commit ya tiene imagen y un rc apunta a su
  digest, se REUTILIZA ese rc en vez de acuñar otro.
- **Los tags de versión son inmutables**: si `X.Y.Z` ya existe apuntando a otro
  digest, el pipeline corta — una versión publicada no se reconstruye jamás.
- El SNAPSHOT lleva el `<sha7>` a propósito: dos builds de `develop` nunca
  comparten tag, así que ningún tag se reapunta ni deja digests huérfanos.

## Modelo de promoción entre organizaciones de Quay

Las cuatro organizaciones (`company-dev`, `company-test`, `company-prod`,
`company-contingencia`) separan entornos por SEGURIDAD: los robots `pusher` de
prod y contingencia son de **solo lectura**, así que el CI no puede publicar
ahí ni aunque se comprometa. A esos entornos se llega SOLO con `promote-image`
y la credencial de promoción (`quay-promotion-credentials`), separada del CI.

La barrera hacia prod es RBAC, en dos capas complementarias:

1. **El Secret**: `quay-promotion-credentials` con escritura sobre
   `company-prod` solo se crea en el namespace desde el que se autoriza a
   promocionar; quien no puede montar ese Secret no puede promocionar, ponga lo
   que ponga en `target-org`.
2. **El PipelineRun**: crear PipelineRuns en ese namespace se limita por `Role`
   al grupo de release. Ojo con el matiz, que es una trampa clásica: **poder
   crear un `PipelineRun` o un `TaskRun` equivale a poder LEER todos los Secrets
   del namespace**, porque el run puede declarar su propio `taskSpec` y montar
   cualquier Secret como workspace. Por eso `app-developers` pasó a tener Tekton
   en SOLO LECTURA en `workshop-demo-dev` (ver
   `namespace-governance/.../workshop-demo-dev/app-developers-role.yaml`): sin
   ese cambio, retirar `secrets` del Role no protegía nada. En el workshop CI y
   promoción conviven en `workshop-demo-dev` por simplicidad; en producción la
   promoción a prod va en un namespace propio con su Role y sus credenciales, y
   la clave PRIVADA de cosign no vive ahí (basta `cosign.pub` para verificar).

## Rol del CD (léase antes de buscarle un webhook)

No hay `EventListener` ni `Trigger` configurados y las Applications tienen
auto-sync (`Automated` + `Prune` + `SelfHeal`): tras el push del CI, **Argo CD
despliega solo**, sin que nadie lance nada. El pipeline de CD **no es la puerta
del despliegue ni pretende serlo**: es una herramienta de validación bajo
demanda — renderiza el overlay antes de que Argo lo intente, fuerza un sync a
una revisión concreta y espera a que la Application quede Healthy con
diagnóstico si no converge. Úsalo antes de una demo o al depurar un overlay;
si algún día se quiere como puerta real, hay que desactivar el auto-sync y
añadir un webhook (repo de config → EventListener), no solo el webhook.

## Secretos y config requeridos (NUNCA en Git)

El CI monta cuatro workspaces de tipo Secret (el SBOM reutiliza dos de ellos:
`registry-credentials` y `signing-key`), la promoción añade uno propio y el CD
necesita la pareja ConfigMap/Secret que lee la Task `argocd-sync`. Todos se
crean a mano en el cluster; en Git solo queda su NOMBRE.

### 1. `quay-push-credentials` — robot/usuario del registro (push, firma y consulta de tags)

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

### 5. `quay-promotion-credentials` — credencial de PROMOCIÓN (separada del CI)

> El run de promoción monta además el workspace `signing-key` para **verificar**
> la firma antes de copiar. En un namespace de release, ese Secret debe contener
> ÚNICAMENTE `cosign.pub`: verificar no necesita la clave privada.

```bash
# Robot con ESCRITURA sobre la organización DESTINO (p. ej. company-test+promoter);
# nunca la misma cuenta que publica desde CI: ese es el aislamiento entre entornos.
podman login <QUAY_HOST> --username 'company-test+promoter' --password '<token-del-robot>' --authfile /tmp/promo-auth.json
oc create secret generic quay-promotion-credentials -n workshop-demo-dev \
  --from-file=config.json=/tmp/promo-auth.json
rm /tmp/promo-auth.json
```

Para promocionar a prod se crea el análogo con un robot de `company-prod`, y
solo en el namespace autorizado (ver "Modelo de promoción").

### 6. CD: `argocd-env-configmap` + `argocd-env-secret`

La Task propia `argocd-sync` (imagen Red Hat `openshift-gitops-1/argocd-rhel9`,
timeout explícito y volcado de diagnóstico si el sync/wait falla) lee la
conexión a Argo CD de esta pareja (nombres fijos, en el namespace del run):

```bash
ARGO_HOST=$(oc get route -n openshift-gitops openshift-gitops-server -o jsonpath='{.spec.host}')
oc create configmap argocd-env-configmap -n workshop-demo-dev \
  --from-literal=ARGOCD_SERVER="$ARGO_HOST" --from-literal=ARGOCD_OPTS="--grpc-web"
# Token de la CUENTA TÉCNICA local "pipeline" (rol ci-pipeline: solo get/sync
# sobre el proyecto workshop-platform), NUNCA el admin de Argo CD.
# La cuenta se declara en el ArgoCD CR (extraConfig accounts.pipeline: apiKey)
# y su RBAC en spec.rbac.policy; el token se genera vía API o CLI:
#   argocd account generate-token --account pipeline
oc create secret generic argocd-env-secret -n workshop-demo-dev \
  --from-literal=ARGOCD_AUTH_TOKEN='<token de la cuenta pipeline>'
```

> Como transición, la task también acepta `ARGOCD_USERNAME`/`ARGOCD_PASSWORD`
> si no hay token, pero avisa en el log: migra a la cuenta técnica con token.

## La puerta de calidad del escaneo

Dos parámetros del pipeline la gobiernan:

- `scan-severity-threshold` (LOW/MODERATE/IMPORTANT/CRITICAL): qué CVEs se
  destacan en el informe y, en modo corte, cuáles tumban el run.
- `scan-fail-on-violation` (default `"false"`): con `"false"` el escaneo
  INFORMA (tabla de CVEs + listado de los que cruzan el umbral) y el pipeline
  CONTINÚA; con `"true"` el run queda en `Failed` sin
  promocionar el digest.

El default `"false"` es una decisión consciente para el workshop: la base UBI9
arrastra CVEs IMPORTANT sin parche disponible (curl-minimal, libblkid,
openssl-libs...) y un corte en IMPORTANT dejaría el pipeline en rojo permanente.
En producción se recomienda `"true"` con umbral `CRITICAL` (o IMPORTANT con
excepciones gestionadas vía deferral en ACS).

Ambos modos están validados en vivo: con `"true"` y umbral LOW el run terminó
`Failed` en `scan-image` y NO corrieron `set-image-digest` ni `push-config`;
con `"false"` y 4 IMPORTANT presentes el run terminó `Succeeded` con el informe
completo en los logs. La task además distingue la VIOLACIÓN de política (avisa
y continúa en modo informe) del ERROR de infraestructura — token caducado, CA
errónea o Central caído cortan el pipeline SIEMPRE, también en modo informe.

## Verificación tras un run del CI

```bash
# El único tag es el inmutable git-<sha>; el despliegue va por digest
skopeo inspect --format '{{.Digest}}' docker://<QUAY_HOST>/company-dev/demo-service:git-<sha>

# Firma: verificación con la clave pública del llavero
oc get secret cosign-signing-key -n workshop-demo-dev -o jsonpath='{.data.cosign\.pub}' | base64 -d > /tmp/cosign.pub
cosign verify --key /tmp/cosign.pub --insecure-ignore-tlog <QUAY_HOST>/company-dev/demo-service@<digest>

# Escaneo y políticas: lo mismo que ejecuta la task image-scan
roxctl --token-file <token> -e central.stackrox.svc:443 image check --image <QUAY_HOST>/company-dev/demo-service@<digest>

# SBOM: la atestación SPDX publicada por la task sbom-generate
cosign verify-attestation --key /tmp/cosign.pub --insecure-ignore-tlog --type spdxjson <QUAY_HOST>/company-dev/demo-service@<digest>
```

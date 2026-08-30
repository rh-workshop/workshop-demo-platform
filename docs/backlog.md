# Backlog de mejoras

Mejoras acordadas pero **no implementadas todavía**: primero se valida que el
bootstrap arranca de cero de punta a punta; luego se refactoriza sobre una base
que ya sabemos que funciona.

> **Norma al aplicarlas: no eliminar operadores ni componentes.** Si uno no aplica
> a un entorno, se **comenta** con el motivo — nunca se borra. Un componente
> borrado se pierde para el resto de entornos; uno comentado se reactiva con una
> línea.

## 1. Catálogo de componentes activos (en vez de listas fijas)

**Problema.** Hoy, para no desplegar un componente hay que tocar varios sitios:
`gitops/apps/kustomization.yaml` (la Application), la `OperatorPolicy` que instala
su operador, y su overlay. Es fácil dejar uno a medias — un operador instalado sin
su configuración, o al revés.

**Propuesta.** Una única lista de datos en `clusters.yml`, sin booleanos por
componente ni condicionales en el playbook:

```yaml
components:
  - acm
  - quay
  - acs
  - keycloak
  - connectivity-link
  - cert-manager
  - pipelines
  - monitoring
  # - metallb         # solo bare-metal: en cloud el proveedor ya da LoadBalancers
  # - developer-hub   # el paquete rhdh-operator no está en el catálogo
```

Se implementa en dos capas, ambas por **iteración sobre datos**, no por
ramificación (`when`/`if`), que es lo que se quiere evitar:

1. El playbook genera las Applications recorriendo `components`, en lugar de que
   `gitops/apps/kustomization.yaml` las enumere fijas.
2. Las `OperatorPolicy` se generan filtrando esa misma lista: si un componente no
   tiene Application, su operador tampoco hace falta.

**Ventaja.** Una sola fuente de verdad: comentar una línea desactiva el componente
entero — operador y configuración — sin tocar el playbook.

## 1-bis. Promoción de imágenes entre organizaciones de Quay — HECHO

**Implementado** en `workshop-pipelines/gitops/base/pipeline-promote-image.yaml`
(con un run por salto de la cadena **dev → test → prod → contingencia**:
`pipelinerun-promote-dev-to-test.yaml`, `-test-to-prod.yaml` y
`-prod-to-contingencia.yaml`; los tres invocan el mismo pipeline y solo cambian
`source-org`, `target-org` y el overlay destino):
`skopeo copy --all` entre organizaciones (verificando que el digest en destino
coincide), `kustomize edit set image` sobre el overlay del entorno destino con el
MISMO digest, push con reintento y sync opcional de Argo. La credencial de
promoción (`quay-promotion-credentials`) es **distinta** de la del CI — ver el
README de `workshop-pipelines/` para su creación y para el modelo RBAC que hace
de barrera hacia `prod`/`contingencia`. **Sin validar en vivo** (clusters apagados).

## 1-ter. SBOM en el pipeline de CI — HECHO

**Implementado** en `workshop-pipelines/gitops/base/sbom-generate-task.yaml`,
enganchado en el CI tras `resolve-digest` (en paralelo con firma y escaneo; la
promoción del digest lo espera): `syft` genera el SPDX y `cosign attest` lo
publica como atestación con la misma llave de firma. No existe imagen Red Hat de
syft (elección documentada en la propia Task); la atestación sí va con la imagen
RHTAS de cosign. **Sin validar en vivo** (clusters apagados).

## 1-quater. Canary automático con Argo Rollouts — HECHO

**Implementado**: `rollouts/gitops/` (CR `RolloutManager` + Application
`config-rollouts` al hub) y, en `workshop-demo-app-config`, el `Rollout`
`canary-service-auto` + `AnalysisTemplate` sobre Prometheus (tasa de éxito y
p95). Convive con el canary manual por pesos de `HTTPRoute` (material del
workshop, intacto) en el path `/canary-auto`. Sin `trafficRouting`: el peso se
aproxima por réplicas — el control fino con Gateway API exige el plugin
community `rollouts-plugin-trafficrouter-gatewayapi`, fuera de la norma "solo
Red Hat".

**Autenticación al Thanos Querier: RESUELTA.** La consulta iba sin token y con
`insecure: true`; ese endpoint exige Bearer token y comprueba el permiso con
SubjectAccessReview, así que respondía 403 y —con `failureLimit: 1`— habría
abortado *todo* despliegue canary aunque la aplicación estuviera sana. Ahora
`serviceaccount-thanos-reader.yaml` (en el repo de aplicaciones) aporta las tres
piezas: ServiceAccount `thanos-reader`, ClusterRoleBinding al rol de solo lectura
`cluster-monitoring-view` y un Secret de tipo `service-account-token` que **el
cluster rellena** (su contenido nunca viaja en Git). La `AnalysisTemplate` lo
inyecta como arg `thanos-token` en la cabecera `Authorization`.

Eso obligó a ampliar el AppProject `workshop-platform`… y **fue un error, que la
auditoría revirtió**. Permitir `ClusterRoleBinding` a un proyecto que despliega
desde el repo de APLICACIONES convertía cualquier commit ahí en cluster-admin
efectivo (basta enlazar `cluster-admin` a una ServiceAccount propia); y permitir
`Secret` dejaba a ese repo SOBRESCRIBIR, con `selfHeal` incluido, los Secrets del
CI que viven en `workshop-demo-dev` — la llave de firma entre ellos. Las tres
piezas (ServiceAccount, ClusterRoleBinding y token) se movieron al repo de
plataforma, a `namespace-governance/gitops/base/namespaces/canary-demo-dev/`,
que es donde ya vive el RBAC por namespace.

**Pendiente de validar en vivo**: el ámbito cluster del `RolloutManager`, que el
token se rellene y que las métricas `http_requests_total` /
`http_request_duration_seconds_bucket` existan (requieren que la app las exponga
y haya un ServiceMonitor).

## 1-quinquies. Previews efímeros por Pull Request — HECHO

No estaba en el backlog original; se añadió al detectar que `overlays/dev` es
único y dos features en paralelo se pisan. **Implementado** en
`gitops/appsets/workshop-previews-pr-applicationset.yaml` (generador
`pullRequest` de GitHub sobre `workshop-demo-app-config`): una Application por
PR abierto en su namespace efímero `demo-service-pr-<n>` (path `/pr-<n>` del
gateway), borrada EN CASCADA al cerrar el PR. Barandilla propia:
`bootstrap/manifests/workshop-preview-appproject.yaml`. El token de GitHub va en
el Secret `github-pr-token` de `openshift-gitops`, nunca en Git.

**Filtro por etiqueta: obligatorio, no opcional (corregido en la auditoría).**
`workshop-demo-app-config` es un repositorio PÚBLICO, así que el generador
`pullRequest` sin filtro desplegaba en el cluster HUB el contenido de cualquier
PR abierto por cualquier persona de internet —incluido un PR desde un fork—, y
el manifiesto del PR decide la imagen (`newName`): ejecución de código arbitrario
en la plataforma sin revisión. Ahora solo se despliegan los PR con la etiqueta
`preview`, que únicamente puede poner quien tiene escritura en el repo.

Pendiente: cuotas/NetworkPolicy de `namespace-governance` para los namespaces
`*-pr-*` (ver 6.4), y validación en vivo (clusters apagados).

## 2. Dominio propio `labjp.xyz` (Cloudflare)

Hoy los hostnames usan el dominio del sandbox RHPDS, que cambia en cada
reaprovisionamiento. Pendiente:

- `ClusterIssuer` de Let's Encrypt con solver **DNS-01 de Cloudflare** (el
  `cert-manager` del cluster solo trae issuers para el dominio del sandbox).
- API Token de Cloudflare (`Zone:DNS:Edit` sobre `labjp.xyz`) por variable de
  entorno, nunca en Git.
- Hostnames objetivo, divididos por ambiente:
  `auth-workshop-{dev,prod}.labjp.xyz` (Keycloak) y
  `gateway-workshop-{hub,dev,prod}.labjp.xyz` (Gateway).
- CNAME en Cloudflare al ELB de cada cluster, **con el proxy desactivado** (nube
  gris): en naranja, Cloudflare termina el TLS y rompe el reto ACME y el
  passthrough al Gateway.

## 3. external-dns

Los CNAME anteriores hay que reapuntarlos a mano cada vez que se reaprovisiona un
cluster (el hostname del ELB cambia). `external-dns` con el proveedor de Cloudflare
los mantendría solos.

## 4. `developer-hub` deshabilitado

El packagemanifest `rhdh-operator` no está en el catálogo de estos clusters, así
que su Application falla al instalar el operador. Queda **comentado, no borrado**,
a la espera de localizar el nombre real del paquete o el catálogo que lo sirve.

## 5. Gateway: de wildcard a hostname fijo

Al pasar de `*.apps.<cluster>` a un hostname único por ambiente, los `HTTPRoute`
de los 5 servicios ya no pueden discriminar por subdominio y tienen que rutear
**por path**. Afecta al repo `workshop-demo-app-config`, no solo a éste.

## 6. Hallazgos de la auditoría de cadena de suministro (los no corregidos)

Auditoría de supply chain / GitOps sobre ambos repos. Los CRÍTICO y ALTO se
corrigieron en el mismo commit; aquí quedan los MEDIO/BAJO, con su motivo.

### 6.1 No hay procedencia in-toto utilizable (SLSA Build L2/L3) — MEDIO

Tekton Chains está configurado (`pipelines/gitops/base/tektonconfig.yaml`:
`artifacts.pipelinerun.format: in-toto`), pero la procedencia no cierra el ciclo:

- Chains identifica el artefacto construido por los results `IMAGE_URL` /
  `IMAGE_DIGEST` de la TaskRun. El pipeline de CI expone los suyos como
  `image-digest` e `immutable-tag`
  (`workshop-pipelines/gitops/base/pipeline-ci-build-image.yaml`), que Chains no
  reconoce: solo hay procedencia de la TaskRun de `buildah`, no del PipelineRun.
- Cuando la **idempotencia** salta el build (el tag `git-<sha>` ya existe), esa
  TaskRun no corre y **no se genera ninguna procedencia** para ese run.
- Nada la **verifica**: sin verificación en el consumidor, la procedencia no
  cuenta para SLSA.

Pendiente: renombrar los results a `IMAGE_URL`/`IMAGE_DIGEST` a nivel de
PipelineRun y añadir una puerta `cosign verify-attestation --type slsaprovenance`
antes de promocionar. No se hizo ahora porque cambia el contrato de results del
pipeline (los `PipelineRun` de `runs/` y cualquier consumidor externo) y no se
puede validar en vivo con los clusters apagados.

### 6.2 Sin VEX: no hay forma declarativa de decir "este CVE no aplica" — MEDIO

La puerta de escaneo es binaria (`scan-severity-threshold` +
`scan-fail-on-violation`) y el default `"false"` está justificado precisamente
por los CVE de la base UBI9 sin parche. La salida correcta no es bajar el umbral
sino declarar excepciones: **VEX**. Hoy la única vía es el *deferral* manual en
la consola de ACS, que no se versiona y por tanto no es auditable. Pendiente:
consumir los documentos VEX que Red Hat publica para sus imágenes base y
versionar las excepciones propias junto al servicio que las declara.

### 6.3 Egress sin restringir en los namespaces de negocio — MEDIO

`namespace-governance/gitops/base/profiles/app-namespace/` solo declara reglas
de **ingress** (`allow-same-namespace`, `allow-from-platform-gateway`,
`allow-from-monitoring`, `allow-from-openshift-ingress`). Una NetworkPolicy sin
`policyTypes: [Egress]` no restringe la salida: un pod comprometido puede abrir
conexiones a cualquier destino, dentro y fuera del cluster. Pendiente: una
`deny-all-egress` con excepciones explícitas (DNS, gateway, registro, Keycloak).
No se aplica ahora porque romper el egress sin poder probar en un cluster deja
los servicios del workshop sin arrancar.

### 6.4 Namespaces de preview sin cuota, sin LimitRange y sin NetworkPolicy — MEDIO

Las Policies de ACM `require-resourcequota` / `require-limitrange` seleccionan
por nombre (`user*` y sufijo `-demo-dev`), así que los namespaces efímeros
`demo-service-pr-<n>` quedan fuera; tampoco los cubre `namespace-governance`,
que enumera namespaces fijos. Con el filtro por etiqueta ya activo en el
ApplicationSet el riesgo baja mucho (solo despliega un PR que un mantenedor haya
etiquetado), pero un preview sigue corriendo sin techo de recursos ni
aislamiento de red. Pendiente: ampliar el patrón de las Policies a
`demo-service-pr-*`.

### 6.5 Las organizaciones de Quay no corresponden con lo desplegado — MEDIO

`quay/ansible/organizations.yml` crea cuatro organizaciones (`company-dev`,
`company-test`, `company-prod`, `company-contingencia`) con el repositorio
`app-workshop`, pero **todos** los overlays de `workshop-demo-app-config`
apuntan a `…/company/demo-service` y `…/company/api-service`: una sola
organización, que ningún playbook gobierna, con repositorios que no existen en
el modelo. La segregación por entorno está escrita pero no conectada: hoy nada
de lo desplegado pasa por la barrera de promoción. Pendiente: renombrar los
repositorios en el modelo (`demo-service`, `api-service`) y reapuntar cada
overlay a la organización de su entorno. Toca los dos repos y obliga a re-subir
las imágenes, así que va con la siguiente reconstrucción del laboratorio.

### 6.6 El ID de la SignatureIntegration de ACS es un valor de otra instalación — MEDIO

`acs/gitops/base/policies/require-image-signature*.yaml` referencian
`io.stackrox.signatureintegration.46ab1fe7-…`. Ese ID lo genera Central al crear
la integración, así que en un cluster nuevo **no existe** y la política queda
inerte: no bloquea nada y aparenta estar activa, que es el peor de los dos
mundos. Pendiente: crear la integración desde `acs/ansible/` y que el playbook
escriba el ID resultante, o usar un ID determinista. Requiere un Central vivo.

### 6.7 Llave de firma cosign estática, sin rotación ni caducidad — MEDIO

La misma llave de larga duración firma imágenes y atestaciones, vive en un
Secret del cluster y no tiene procedimiento de rotación ni fecha de caducidad
(`workshop-pipelines/README.md`, apartado 2). Sin log de transparencia
(desactivado a propósito, ver 6.8), una llave comprometida permite firmar hacia
atrás sin dejar rastro. Pendiente en producción: llave en Azure Key Vault con
rotación anual —o, mejor, firma **keyless** con identidad de workload— y Rekor
interno como evidencia temporal.

### 6.8 Rekor: desactivado hasta tener un log interno — MEDIO (mitigado)

`transparency.enabled` estaba en `"true"` **sin** `transparency.url`, lo que
publica en el log PÚBLICO `rekor.sigstore.dev` el nombre del registro interno,
el repositorio y el digest de cada artefacto corporativo. Se desactivó con el
motivo comentado en el manifiesto y la línea `transparency.url` preparada.
Pendiente: desplegar Rekor con Red Hat Trusted Artifact Signer y reactivar las
dos líneas juntas.

### 6.9 Datos de un entorno concreto en un fichero de ejemplo — BAJO

`workshop-pipelines/runs/pipelinerun-ci-build-image.yaml` lleva cableado el host
real de un sandbox (`…sandbox3572.opentlc.com`), mientras que el run de
promoción usa `CHANGE_ME_QUAY_HOST`. Debe homologarse a `CHANGE_ME_*`.

### 6.10 Separar el namespace del CI del namespace de aplicación — MEDIO

El corte correcto, y el que pediría un auditor, es que los Secrets del CI
(llave de firma, PAT de Git, robot de Quay, token de Argo) vivan en un namespace
`workshop-ci` donde **ningún grupo de desarrollo pueda ejecutar cargas**. La
mitigación aplicada (Tekton en solo lectura para `app-developers`) cierra la
exfiltración, pero sigue dependiendo de un Role bien escrito en vez de una
frontera de namespace. Pendiente: mover `workshop-pipelines/gitops/overlays/dev`
a `workshop-ci`, darle su entrada en `namespace-governance` y en las Policies de
cuota, y actualizar los `runs/`. No se hizo ahora porque toca la narrativa de
varias sesiones del workshop y no se puede validar en vivo.

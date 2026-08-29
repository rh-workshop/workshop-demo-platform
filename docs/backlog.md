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
(con su run de ejemplo en `workshop-pipelines/runs/pipelinerun-promote-image.yaml`):
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
Red Hat". **Pendiente de validar en vivo**: el ámbito cluster del
RolloutManager y la autenticación de la consulta al Thanos Querier
(token de ServiceAccount) — hoy la AnalysisTemplate va con `insecure: true`.

## 1-quinquies. Previews efímeros por Pull Request — HECHO

No estaba en el backlog original; se añadió al detectar que `overlays/dev` es
único y dos features en paralelo se pisan. **Implementado** en
`gitops/appsets/workshop-previews-pr-applicationset.yaml` (generador
`pullRequest` de GitHub sobre `workshop-demo-app-config`): una Application por
PR abierto en su namespace efímero `demo-service-pr-<n>` (path `/pr-<n>` del
gateway), borrada EN CASCADA al cerrar el PR. Barandilla propia:
`bootstrap/manifests/workshop-preview-appproject.yaml`. El token de GitHub va en
el Secret `github-pr-token` de `openshift-gitops`, nunca en Git. Pendiente:
cuotas/NetworkPolicy de `namespace-governance` para los namespaces `*-pr-*`, y
validación en vivo (clusters apagados).

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

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

## 1-bis. Promoción de imágenes entre organizaciones de Quay

Ya hay **cuatro organizaciones** (`company-dev`, `company-test`, `company-prod`,
`company-contingencia`) con los robots de `prod` y `contingencia` en solo lectura:
a esos entornos no se publica desde CI, solo se promociona. Falta la pieza que
mueve la imagen.

Pendiente: una Task de Tekton que copie el manifiesto entre organizaciones
(`skopeo copy --all docker://…/company-test/app:… docker://…/company-prod/app:…`).
Copiar el manifiesto —no reconstruir— es lo que garantiza que el digest se
conserve: lo validado en test es byte a byte lo que corre en prod.

Necesita una credencial de promoción **distinta** de la del CI y con escritura
sobre `prod`/`contingencia`; si se le diera al pusher de CI se perdería el
aislamiento que justifica separar las organizaciones.

## 1-ter. SBOM en el pipeline de CI

El CI ya firma (`image-sign-task`) y escanea (`image-scan-task`), pero no genera
inventario de dependencias. Falta una Task con `syft` (o `cosign attest`) que
publique el SBOM como atestación junto a la firma — es lo que completa SLSA.

## 1-quater. Canary automático con Argo Rollouts

Hoy el canary del workshop se hace por peso de `HTTPRoute`, avanzando a mano. Un
`Rollout` con `AnalysisTemplate` sobre métricas de Prometheus promociona o
revierte solo, según tasa de error o latencia. El operador de OpenShift GitOps ya
incluye Argo Rollouts (`RolloutManager`), así que no hace falta instalar nada.

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

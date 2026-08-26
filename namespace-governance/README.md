# namespace-governance — gobierno de namespaces de la plataforma

Antes, los Namespace se declaraban dispersos (cada producto el suyo, cada app el
suyo), no existía RBAC de personas ni equipos, y la Policy `require-resourcequota`
exigía cuotas que ningún namespace declaraba en Git. Este componente centraliza
ese gobierno en un solo lugar.

## Qué contiene

| Carpeta | Contenido |
|---|---|
| `namespaces/` | Los Namespace de plataforma **hub-only** (quay-enterprise, stackrox, developer-hub, openshift-pipelines), adoptados de sus productos |
| `quotas/` | ResourceQuota + LimitRange por namespace, dimensionadas sobre consumo real |
| `rbac/` | RoleBinding por **grupo** (nunca usuarios): tres perfiles |
| `network/` | NetworkPolicy de aislamiento de los namespaces de aplicaciones |

## Decisiones

### Qué namespaces entran y cuáles no

- **Entran**: los de productos que viven SOLO en el hub. Su Namespace deja de
  declararse en el producto y pasa aquí.
- **No entran** los de productos multi-cluster (keycloak, cert-manager,
  metallb-system, kuadrant-system, platform-gateway, istio-system): su Namespace
  debe viajar con el producto a cada cluster; sacarlo rompería un despliegue
  limpio de un spoke. Sus cuotas/RBAC del hub SÍ se gobiernan aquí.
- **No entran** open-cluster-management ni los namespaces de operadores: los
  crea el componente `acm` (dependencia del bootstrap).
- **No entran (aún)** los Namespace de las aplicaciones (`*-demo-dev`): el
  criterio correcto es que el namespace y su cuota son gobierno de plataforma,
  pero hoy los declara `workshop-demo-app-config` y ese repo está en plena
  reestructuración. Propuesta: cuando esa reestructuración termine, mover los
  cinco Namespace aquí y dejar en el repo de apps solo los workloads. Mientras
  tanto, este componente ya gobierna sus cuotas, límites, RBAC y red (recursos
  nuevos, sin conflicto de ownership).

### Dimensionado de cuotas

Medido con `oc adm top pods` y la suma de requests/limits declarados de los pods
en marcha; la cuota deja ~50-100 % de margen para rollouts (surge) y crecimiento.
Cada cuota va SIEMPRE con un LimitRange que inyecta defaults: sin él, la cuota
rechaza cualquier pod que no declare resources.

Los namespaces de aplicaciones usan el sobre estándar de la Policy de ACM
`require-resourcequota` (nombre `platform-quota`, 4 CPU / 8Gi req, 8 CPU / 16Gi
lim): la Policy ahora VERIFICA lo que Git declara en vez de crear la cuota por
enforce.

### Perfiles RBAC (grupos genéricos, mapear a Entra/LDAP en el cluster real)

| Grupo | Permiso | Dónde |
|---|---|---|
| `platform-admins` | `admin` | Todos los namespaces gobernados |
| `app-developers` | `edit` | Los 5 namespaces de aplicaciones |
| `app-developers` | `view` | platform-gateway y kuadrant-system (depurar su exposición) |
| `platform-viewers` | `view` | Todos los namespaces gobernados |

### NetworkPolicy

Se aplican SOLO a los namespaces de aplicaciones (modelo cerrado: mismo
namespace + gateway compartido + monitoring + routers). Los namespaces de
operadores quedan fuera a propósito: sus flujos internos (webhooks, conversion,
scanners) son del operador y una policy genérica los rompería sin aportar valor
didáctico.

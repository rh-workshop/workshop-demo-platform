# namespace-governance — gobierno de namespaces de la plataforma

Centraliza cuota, limites y RBAC de los namespaces de plataforma: quien puede ver
o administrar cada uno, cuanto puede consumir y que valores por defecto reciben
los pods que no declaran `resources`.

## Argo aplica, ACM verifica

El gobierno se declara UNA vez en Kustomize y lo aplica **Argo CD**, tanto en el
hub como en los clusters de carga (los AppSets `workload-*` lo incluyen). Asi un
cliente **sin ACM** conserva sus cuotas, sus limites y su RBAC: solo necesita
OpenShift GitOps.

**ACM no crea este gobierno: lo verifica.** Las Policies `require-limitrange` y
`require-resourcequota` reportan el cumplimiento por cluster, que es lo que Argo
no da. Un objeto, un dueno.

La excepcion son los namespaces que NO se pueden enumerar por adelantado: los de
negocio (`*-demo-*`) y los previews de PR, que nacen y mueren con cada rama. Ahi
la Policy va en `enforce`, porque un Kustomize no puede declarar lo que aun no
existe. No es duplicidad: es el hueco que Argo no alcanza.

| | Lo declara | ACM |
|---|---|---|
| Namespaces de plataforma (kuadrant-system, platform-gateway, quay-enterprise...) | Argo | verifica (`inform`) |
| Namespaces de negocio y previews (`*-demo-*`, `demo-service-pr-*`) | ACM (`enforce`) | aplica |
| Reparto de secretos entre clusters (init bundles, pull secrets, token del almacen) | ACM (`enforce`) | aplica |

En un cliente **sin Argo CD**, cambiar las Policies de `inform` a `enforce`
convierte a ACM en el aplicador de todo, sin tocar nada mas.

## Estructura: perfil compartido + un directorio por namespace + overlay por cluster

```
gitops/
├── base/
│   ├── profiles/                  # El QUÉ: plantillas compartidas, sin namespace
│   │   └── platform-namespace/    #   cuota + límites + RBAC (2 grupos), sin NetworkPolicy
│   │                              #   (el perfil app-namespace vive en namespace-governance-workload/)
│   ├── namespaces/                # El DÓNDE: un directorio por namespace gobernado
│   │   └── <ns>/kustomization.yaml  #  consume un perfil y declara SOLO sus desviaciones
│   ├── workload/                  # Subconjunto de namespaces/: los que existen en
│   │   │                          # TODOS los clusters (hub y spokes). Los overlays de
│   │   │                          # spoke referencian solo esta carpeta, nunca base/
│   │   │                          # completo — el resto de namespaces/ es exclusivo del hub.
│   │   └── kustomization.yaml
│   ├── identity/                  # Objetos Group (vacíos), solo hub
│   ├── admission/                 # ValidatingAdmissionPolicy
│   └── kustomization.yaml         # Índice: TODO lo del hub (namespaces/* + workload/)
└── overlays/
    ├── hub/kustomization.yaml     # -> ../../base completo
    ├── dev/kustomization.yaml     # -> ../../base/workload (solo el subconjunto compartido)
    ├── test/…
    ├── prod/…
    └── contingencia/…
```

Cada cluster tiene su propia Application apuntando al overlay de su rol
(`overlays/<rol>`); el hub gobierna los namespaces exclusivos suyos más los
compartidos, cada spoke gobierna solo los compartidos. Nunca hay un directorio
hermano de `base/`: todo lo específico de un subconjunto de clusters vive
DENTRO de `base/`, como `workload/`.

El patrón sigue la práctica documentada por Red Hat para onboarding de
proyectos con GitOps: una **plantilla única** de gobierno (allí un Helm chart
`helper-proj-onboarding` con "t-shirt sizes"; aquí un perfil de Kustomize) y
**una carpeta por tenant/namespace** que solo aporta sus parámetros. Así no se
versionan N copias del mismo manifiesto —la duplicación de YAML crudo es el
antipatrón que señalan las prácticas recomendadas de OpenShift GitOps— y a la
vez la pregunta «¿qué gobierna `canary-demo-dev`?» se responde abriendo
`namespaces/canary-demo-dev/`.

Los `components` de Kustomize no encajan aquí (son para *features opcionales*
de una app, no para replicar un juego de recursos en N namespaces); el
mecanismo canónico de Kustomize para este caso es el que se usa: base sin
namespace + transformer `namespace:` en cada consumidor. Un ApplicationSet con
generador `git directories` sobre `namespaces/` sería el paso siguiente si los
namespaces se contaran por cientos o el alta fuera self-service de los equipos;
con 7 namespaces y 5 clusters destino (hub + 4 spokes, cada uno con su propia
Application vía `overlays/<rol>`), una Application por cluster mantiene el
plano de control simple sin necesitar ese generador.

## Índice de namespaces gobernados

Este componente gobierna namespaces de PLATAFORMA — de privilegio (`identity/`,
`admission/`) o exclusivos del hub. Los namespaces de NEGOCIO
(`workshop-demo-dev`, `canary-demo-dev`...) NO viven aquí: ver
[`namespace-governance-workload/README.md`](../namespace-governance-workload/README.md)
y la nota en "Qué namespaces entran y cuáles no" más abajo.

6 directorios bajo `base/namespaces/` (2 compartidos con los spokes vía
`base/workload/`, 4 exclusivos del hub):

| Directorio | Perfil | Overlay | Desviaciones |
|---|---|---|---|
| `quay-enterprise` | platform | hub | Namespace propio; cuota 32 CPU / 56Gi req |
| `stackrox` | platform | hub | Namespace propio; cuota 24 CPU / 48Gi req |
| `developer-hub` | platform | hub | Namespace propio; limits 16 CPU / 32Gi |
| `openshift-pipelines` | platform | hub | Namespace propio (+label monitoring); limits 24 CPU / 48Gi |
| `kuadrant-system` | platform | **hub + todos los spokes** | LimitRange 2Gi; `app-developers` view |
| `platform-gateway` | platform | **hub + todos los spokes** | LimitRange 2Gi; `app-developers` view |

## Cómo añadir un namespace nuevo

1. Crear `gitops/base/namespaces/<ns>/kustomization.yaml` con `namespace: <ns>`
   y `../../profiles/platform-namespace` como resource — es el único perfil de
   este componente (el perfil `app-namespace`, para namespaces de negocio,
   vive en [`namespace-governance-workload/`](../namespace-governance-workload/README.md)).
2. Si el namespace es hub-only y nadie más lo declara, añadir su
   `namespace.yaml` al directorio (los multi-cluster NO: su Namespace viaja
   con el producto).
3. Si necesita una cuota o límites distintos, añadir un
   `resourcequota-patch.yaml` / `limitrange-patch.yaml` y referenciarlo en
   `patches:` — el perfil no se toca.
4. Añadir el directorio a `resources:`:
   - **Hub-only** (Quay, ACS, Developer Hub, Pipelines...): directo en
     `gitops/base/kustomization.yaml`.
   - **Compartido con los spokes** (como `kuadrant-system`,
     `platform-gateway`): en `gitops/base/workload/kustomization.yaml` — así
     llega automáticamente al hub (que incluye `workload/`) y a los 4 spokes
     (cuyos overlays lo referencian).
5. Validar con `oc kustomize gitops/overlays/<rol>` para **cada** overlay que
   deba llevarlo (`hub` siempre; además `dev`/`test`/`prod`/`contingencia` si
   es compartido) y abrir PR: el diff muestra exactamente el gobierno del
   namespace nuevo, nada más.

## Decisiones

### Qué namespaces entran y cuáles no

- **Entran**: los de productos que viven SOLO en el hub (quay-enterprise,
  stackrox, developer-hub, openshift-pipelines). Su Namespace deja de
  declararse en el producto y pasa a su directorio de aquí.
- **No entran** los Namespace de productos multi-cluster (keycloak,
  cert-manager, metallb-system, kuadrant-system, platform-gateway,
  istio-system): su Namespace debe viajar con el producto a cada cluster;
  sacarlo rompería un despliegue limpio de un spoke. Sus cuotas/RBAC del hub
  SÍ se gobiernan aquí.
- **No entran** open-cluster-management ni los namespaces de operadores: los
  crea el componente `acm` (dependencia del bootstrap).
- **No entran aquí** los Namespace de las aplicaciones (`workshop-demo-dev`,
  `canary-demo-dev`...): viven en el componente hermano
  `namespace-governance-workload/`, en la instancia de CARGAS
  (`openshift-gitops`), no en la de gobierno. Un RoleBinding a los ClusterRole
  estándar `edit`/`view`/`admin` de un namespace de negocio no acuña privilegio
  nuevo en la flota como sí hacen las Policies de ACM y los `Group` de este
  componente — y necesita compartir instancia con las Applications de negocio
  que dependen de él, para que el sync-wave garantice el orden entre ambas (el
  orden entre DOS instancias de Argo no está garantizado). Ver D.2/A.2 del
  [`governance-backlog.md`](../docs/governance-backlog.md).

### Dimensionado de cuotas

Medido con `oc adm top pods` y la suma de requests/limits declarados de los pods
en marcha; la cuota deja ~50-100 % de margen para rollouts (surge) y crecimiento.
Cada cuota va SIEMPRE con un LimitRange que inyecta defaults: sin él, la cuota
rechaza cualquier pod que no declare resources.

Los namespaces de aplicaciones usan el sobre estándar de la Policy de ACM
`require-resourcequota` (nombre `platform-quota`, 4 CPU / 8Gi req, 8 CPU / 16Gi
lim): la Policy VERIFICA lo que Git declara en vez de crear la cuota por
enforce. Los perfiles y la Policy deben moverse juntos si el sobre cambia.

### Perfiles RBAC (grupos genéricos, mapear a Entra/LDAP en el cluster real)

Este componente solo tiene el perfil `platform-namespace` (2 grupos: RBAC de
`app-developers` sobre namespaces de plataforma es únicamente `view`, para
depurar su exposición — nunca `edit` aquí). El perfil `app-namespace` (3
grupos, incluido `app-developers: edit`) vive en el componente hermano — ver
su tabla de RBAC en
[`namespace-governance-workload/README.md`](../namespace-governance-workload/README.md).

| Grupo | Permiso | Dónde |
|---|---|---|
| `platform-admins` | `admin` | Todos los namespaces de este componente |
| `app-developers` | `view` | platform-gateway y kuadrant-system (depurar su exposición) |
| `platform-viewers` | `view` | Todos los namespaces de este componente |

### NetworkPolicy

El perfil `platform-namespace` NO las trae: los namespaces de operadores
quedan fuera a propósito, sus flujos internos (webhooks, conversion,
scanners) son del operador y una policy genérica los rompería sin aportar
valor didáctico. Las 4 NetworkPolicy (modelo cerrado: mismo namespace +
gateway compartido + monitoring + routers) solo existen en el perfil
`app-namespace` del componente hermano, para namespaces de negocio.

## Referencias

- Red Hat: [Project onboarding using GitOps and Helm](https://www.redhat.com/en/blog/project-onboarding-using-gitops-and-helm)
  (una carpeta por tenant + chart compartido de Namespace/Quota/LimitRange/NetworkPolicy/RBAC).
- Red Hat Developer: [OpenShift GitOps recommended practices](https://developers.redhat.com/blog/2025/03/05/openshift-gitops-recommended-practices)
  (evitar duplicación de YAML crudo; usar una herramienta de gestión de YAML).
- Kustomize: [Components](https://kubectl.docs.kubernetes.io/guides/config_management/components/)
  (para features opcionales, no para fan-out por namespace).
- Argo CD: [Git directory generator](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Git/)
  (una Application por directorio: el siguiente escalón si esto crece a cientos).

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

## Estructura: perfil compartido + un directorio por namespace

```
gitops/base/
├── profiles/                    # El QUÉ: plantillas compartidas, sin namespace
│   ├── app-namespace/           #   cuota + límites + RBAC (3 grupos) + 4 NetworkPolicy
│   └── platform-namespace/      #   cuota + límites + RBAC (2 grupos), sin NetworkPolicy
├── namespaces/                  # El DÓNDE: un directorio por namespace gobernado
│   └── <ns>/kustomization.yaml  #   consume un perfil y declara SOLO sus desviaciones
└── kustomization.yaml           # Índice: enumera los 11 namespaces gobernados
```

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
con 11 namespaces y un solo cluster destino, una única Application mantiene el
plano de control simple.

## Índice de namespaces gobernados

| Directorio | Perfil | Desviaciones |
|---|---|---|
| `workshop-demo-dev` | app | — |
| `canary-demo-dev` | app | — |
| `bluegreen-demo-dev` | app | — |
| `circuit-breaker-demo-dev` | app | — |
| `api-demo-dev` | app | — |
| `quay-enterprise` | platform | Namespace propio; cuota 32 CPU / 56Gi req |
| `stackrox` | platform | Namespace propio; cuota 24 CPU / 48Gi req |
| `developer-hub` | platform | Namespace propio; limits 16 CPU / 32Gi |
| `openshift-pipelines` | platform | Namespace propio (+label monitoring); limits 24 CPU / 48Gi |
| `kuadrant-system` | platform | LimitRange 2Gi; `app-developers` view |
| `platform-gateway` | platform | LimitRange 2Gi; `app-developers` view |

## Cómo añadir un namespace nuevo

1. Crear `gitops/base/namespaces/<ns>/kustomization.yaml` con `namespace: <ns>`
   y el perfil como resource (`../../profiles/app-namespace` o
   `.../platform-namespace`).
2. Si el namespace es hub-only y nadie más lo declara, añadir su
   `namespace.yaml` al directorio (los multi-cluster NO: su Namespace viaja
   con el producto).
3. Si necesita una cuota o límites distintos, añadir un
   `resourcequota-patch.yaml` / `limitrange-patch.yaml` y referenciarlo en
   `patches:` — el perfil no se toca.
4. Añadir el directorio al `resources:` de `gitops/base/kustomization.yaml`.
5. Validar con `kubectl kustomize gitops/overlays/hub` y abrir PR: el diff
   muestra exactamente el gobierno del namespace nuevo, nada más.

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
- **No entran (aún)** los Namespace de las aplicaciones (`*-demo-dev`): el
  criterio correcto es que el namespace y su cuota son gobierno de plataforma,
  pero hoy los declara `workshop-demo-app-config` y ese repo está en plena
  reestructuración. Propuesta: cuando esa reestructuración termine, mover los
  cinco Namespace a sus directorios de aquí y dejar en el repo de apps solo los
  workloads. Mientras tanto, este componente ya gobierna sus cuotas, límites,
  RBAC y red (recursos nuevos, sin conflicto de ownership).

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

| Grupo | Permiso | Dónde |
|---|---|---|
| `platform-admins` | `admin` | Todos los namespaces gobernados (en ambos perfiles) |
| `app-developers` | `edit` | Perfil app (los 5 namespaces de aplicaciones) |
| `app-developers` | `view` | platform-gateway y kuadrant-system (depurar su exposición) |
| `platform-viewers` | `view` | Todos los namespaces gobernados (en ambos perfiles) |

### NetworkPolicy

Solo el perfil `app-namespace` las trae (modelo cerrado: mismo namespace +
gateway compartido + monitoring + routers). Los namespaces de operadores quedan
fuera a propósito: sus flujos internos (webhooks, conversion, scanners) son del
operador y una policy genérica los rompería sin aportar valor didáctico.

## Referencias

- Red Hat: [Project onboarding using GitOps and Helm](https://www.redhat.com/en/blog/project-onboarding-using-gitops-and-helm)
  (una carpeta por tenant + chart compartido de Namespace/Quota/LimitRange/NetworkPolicy/RBAC).
- Red Hat Developer: [OpenShift GitOps recommended practices](https://developers.redhat.com/blog/2025/03/05/openshift-gitops-recommended-practices)
  (evitar duplicación de YAML crudo; usar una herramienta de gestión de YAML).
- Kustomize: [Components](https://kubectl.docs.kubernetes.io/guides/config_management/components/)
  (para features opcionales, no para fan-out por namespace).
- Argo CD: [Git directory generator](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Git/)
  (una Application por directorio: el siguiente escalón si esto crece a cientos).

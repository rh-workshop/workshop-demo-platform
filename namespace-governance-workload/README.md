# namespace-governance-workload — gobierno de namespaces de NEGOCIO

Centraliza cuota, límites, RBAC y aislamiento de red de los namespaces de
**aplicaciones de negocio** (`workshop-demo-dev`, `canary-demo-dev`...): el
mismo problema que resuelve [`namespace-governance/`](../namespace-governance/README.md)
para namespaces de plataforma, pero para el otro dominio de riesgo.

## Por qué es un componente aparte, y no parte de `namespace-governance/`

Dos motivos, no uno:

1. **Instancia de Argo distinta.** `namespace-governance/` vive en
   `gitops-governance` (la instancia de PRIVILEGIO: Policies de ACM, Groups,
   políticas de admisión). Un `RoleBinding` a los `ClusterRole` estándar
   `edit`/`view`/`admin` de un namespace de negocio **no acuña privilegio
   nuevo** en la flota — es el mismo nivel de riesgo que cualquier otro
   `RoleBinding` que ya se permite en los AppProjects `apps-nonprod`/`apps-prod`.
   No necesita la identidad separada de gobierno.

2. **Orden garantizado.** Este componente y las Applications de negocio que
   despliegan DENTRO de sus namespaces deben vivir en la MISMA instancia de
   Argo CD. El `sync-wave` solo garantiza orden entre Applications de una
   misma instancia — entre dos instancias (`openshift-gitops` y
   `gitops-governance`) no hay ninguna garantía de secuencia. Por eso este
   componente vive en `openshift-gitops` (cargas), la misma instancia que
   `workshop-services-*`.

## El problema que resuelve

Antes de este componente, cada Application de negocio (`app-canary-service-dev`,
etc.) creaba su propio namespace con `syncOptions: [CreateNamespace=true]` **en
el mismo sync** que desplegaba la aplicación. Eso deja una ventana real —aunque
breve— donde el namespace existe sin cuota, sin límites, sin RBAC y sin
aislamiento de red: el primer pod puede arrancar antes de que el gobierno
llegue.

Este componente sincroniza el gobierno del namespace en `sync-wave: "-1"`,
ANTES que las Applications de negocio (`sync-wave: "0"` o superior). Cuando la
Application del servicio se sincroniza después, encuentra el namespace ya
gobernado.

**`CreateNamespace=true` se conserva** en las Applications de negocio — no hace
falta quitarlo. Argo lo trata como "crear si falta, adoptar y aplicar metadata
si ya existe": con el namespace ya creado por este componente, simplemente lo
adopta sin recrearlo ni fallar, y sigue aplicando `managedNamespaceMetadata`
(la etiqueta de tenant) sobre él.

## Estructura

```
gitops/
├── base/
│   ├── profiles/
│   │   └── app-namespace/         # cuota + límites + RBAC (3 grupos) + 4 NetworkPolicy
│   └── namespaces/                # un directorio por namespace de negocio
│       ├── workshop-demo-dev/     #   desviación: Role acotado (Secrets del CI)
│       ├── workshop-demo-test/
│       ├── workshop-demo-prod/
│       ├── workshop-demo-contingencia/
│       ├── canary-demo-dev/
│       ├── bluegreen-demo-dev/
│       ├── circuit-breaker-demo-dev/
│       └── api-demo-dev/
└── overlays/
    ├── hub/          # workshop-demo-dev (asimetría: corre en el hub, no en cluster-dev)
    ├── dev/          # canary, bluegreen, circuit-breaker, api (los 4 servicios didácticos)
    ├── test/         # workshop-demo-test (solo demo-service tiene overlay test)
    ├── prod/         # workshop-demo-prod
    └── contingencia/ # workshop-demo-contingencia
```

## Por qué la asimetría hub/dev/test/prod/contingencia

Herencia documentada en `docs/backlog.md` §8: `workshop-demo-dev` corre en el
**hub** (asimetría del material original), mientras que los otros 4 servicios
didácticos (`canary`, `bluegreen`, `circuit-breaker`, `api`) corren en
**`cluster-dev`**. Solo `demo-service` tiene overlay en `test`/`prod`/
`contingencia` en `workshop-demo-app-config` — los otros 4 son exclusivos de
dev. Por eso hay 5 overlays con reparto distinto de namespaces, no uno.

## Perfil `app-namespace`

Replica exactamente lo que hoy aplica la Policy de ACM
`require-namespace-isolation`/`require-resourcequota`/`require-limitrange` por
`enforce` sobre el patrón `*-demo-*` — verificado contra un namespace real en
vivo (`canary-demo-dev`) antes de escribirlo:

- `ResourceQuota platform-quota`: 4 CPU / 8Gi req, 24 CPU / 24Gi lim.
- `LimitRange default-limits`: 1 CPU / 2Gi por defecto, 25m / 64Mi de request.
- `RoleBinding` de 3 grupos: `app-developers` → `edit`, `platform-admins` →
  `admin`, `platform-viewers` → `view`.
- 4 `NetworkPolicy` (modelo cerrado): mismo namespace + `platform-gateway` +
  `monitoring` + routers de `openshift-ingress`. Nada más entra por defecto.

## Desviación de `workshop-demo-dev`

Alberga los Secrets del CI (`argocd-env-secret`, `git-credentials`,
`cosign-signing-key`, `quay-push-credentials`, `acs-pipeline-credentials`). Con
el `edit` estándar del perfil, cualquier miembro de `app-developers` los leía
— escalada directa al GitOps de los 3 clusters. Sustituye el `RoleBinding` de
`app-developers` por un `Role app-developer-no-secrets`: mismos verbos que
`edit` sobre workloads, sin `secrets` ni `serviceaccounts`, y Tekton en solo
lectura (lanzar un `PipelineRun` equivale a leer los Secrets que monta).

Kustomize prohíbe por seguridad referenciar recursos fuera del árbol del
directorio actual (`LoadRestrictionsRootOnly`), así que el resto del perfil
(cuota, límites, RBAC de admin/viewer, las 4 NetworkPolicy) está **copiado**
en `namespaces/workshop-demo-dev/` en vez de referenciado desde
`../../profiles/app-namespace/`. Si el perfil cambia, replicar el cambio aquí
también.

## Cómo añadir un namespace de negocio nuevo

1. Crear `gitops/base/namespaces/<ns>/kustomization.yaml` con `namespace: <ns>`
   y `../../profiles/app-namespace` como resource (o copiar los ficheros del
   perfil si el namespace necesita una desviación de RBAC como
   `workshop-demo-dev`).
2. Añadirlo al overlay del cluster donde corre el servicio.
3. Añadir la entrada al `list` del `ApplicationSet` `workload-<ambiente>`
   correspondiente (`gitops/appsets/applicationset-workload-<ambiente>.yaml`),
   con `producto: namespace-governance-workload`, `proyecto: governance` y
   `wave: "-1"` — el `wave` es lo que garantiza que este gobierno llegue antes
   que la Application del servicio.
4. Añadir el destino (`server` + `namespace`) al `AppProject governance`
   (`bootstrap/manifests/appproject-governance.yaml`).
5. Validar con `oc kustomize gitops/overlays/<rol>` y abrir PR.

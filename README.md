# workshop-platform — configuración de la plataforma

Este repositorio guarda la configuración de **todos los productos que sostienen
la plataforma** sobre OpenShift, desplegada por el patrón oficial **Red Hat ACM +
OpenShift GitOps** desde un hub central. Es el tercer repositorio del modelo,
junto al de **aplicación** (`workshop-app`) y al de **configuración de
despliegue** (`workshop-config`).

## Modelo mental: GitOps central multi-cluster

Hay **un solo Argo CD, en el cluster hub**, con Red Hat ACM. Desde ahí se
despliega a los clusters workload (dev, prod), importados por ACM. No hay un Argo
por cluster. Este es el patrón canónico documentado por Red Hat: la cadena
**`ManagedClusterSetBinding` → `Placement` → `GitOpsCluster` → `ApplicationSet`**.

- **`ManagedClusterSetBinding`** vincula el cluster set al namespace de Argo.
- **`Placement`** selecciona los clusters destino por su etiqueta `environment`
  (dev / prod). El hub lleva `role=hub` y **no** recibe cargas workload.
- **`GitOpsCluster`** registra en Argo los clusters que deciden los Placement:
  crea un Secret de cluster por cada uno. Sin él, Argo no sabe cómo llegar a un
  spoke.
- **`ApplicationSet`** con generador **`clusterDecisionResource`** lee las
  PlacementDecisions y genera una Application por (producto × cluster): fan-out
  automático. Un producto nuevo o un cluster nuevo se propagan solos.

Los productos se dividen en dos grupos según dónde viven:

| Grupo | Productos | Dónde se despliega |
|---|---|---|
| **Workload** | keycloak, connectivity-link, cert-manager, metallb | A los spokes por ambiente, vía `ApplicationSet` |
| **Hub** | acm, quay, acs, pipelines | Solo al hub, vía `Application` directa |

> **Por qué pipelines es hub-only.** El CI construye la imagen y la publica en
> el registro; el CD le pide a Argo que sincronice. Ninguna de las dos cosas
> corre dentro de un spoke: quien despliega a dev/prod es Argo CD. Un solo Tekton
> en el hub basta — no hace falta instalarlo en cada cluster.

## La otra frontera: GitOps vs Ansible

Dentro de cada producto, no todo se puede declarar en Git. Hay dos planos:

| Plano | Qué es | Quién lo aplica | Dónde vive |
|---|---|---|---|
| **Declarativo** | CRs que reconcilia el operador, `Namespace`, `ConfigMap` | **Argo CD** | `<producto>/gitops/` |
| **Imperativo** | Lo que solo existe **detrás de la API del producto** | **Ansible** | `<producto>/ansible/` |

> **Por qué no todo puede ser GitOps.** Argo reconcilia *recursos de Kubernetes*.
> Una organización de Quay, un cliente de Keycloak o una política de ACS **no son
> recursos de Kubernetes**: viven en la base de datos del producto y solo se crean
> por su API REST. No hay CRD que los represente. Ese trabajo lo hace Ansible, de
> forma idempotente.

## Cómo se despliega

Solo se aplica **una** pieza a mano; el resto lo encadena Argo:

```bash
oc apply -f gitops/apps/root-application.yaml
```

Esa Application raíz sincroniza `gitops/`, que contiene:

```
gitops/
├── clusters/      # la cadena ACM+Argo: binding, placements, GitOpsCluster
├── appsets/       # los ApplicationSet que hacen fan-out a los spokes por rol
└── apps/          # el AppProject + las Applications de los productos hub
```

El CR `ArgoCD` y las `Subscription`/`OperatorGroup` de los operadores **no** se
gestionan aquí: se aplican en el bootstrap del cluster, una sola vez.

## Estructura

```
workshop-platform/
├── gitops/                 # el árbol GitOps central (clusters, appsets, apps)
├── quay/{gitops,ansible}/       # QuayRegistry → Argo · orgs/robots → API
├── keycloak/{gitops,ansible}/   # Keycloak/RealmImport → Argo · clientes → API
├── metallb/gitops/         # MetalLB, IPAddressPool, L2Advertisement
├── cert-manager/gitops/    # ClusterIssuer
├── connectivity-link/gitops/    # Kuadrant, Gateway
├── pipelines/gitops/       # TektonConfig (+ firma con Chains)
└── acs/{gitops,ansible}/        # Central/SecuredCluster → Argo · políticas → API
```

Cada `gitops/` sigue Kustomize: `base/` con el *qué* y `overlays/<ambiente>/` con
el *dónde y cuánto*. El **hostname** de cada producto expuesto (Keycloak, Gateway)
se fija en el overlay del ambiente, nunca en la base.

## Qué gobierna cada producto

| Producto | Va por GitOps | Va por Ansible |
|---|---|---|
| **Quay** | `QuayRegistry`, namespace | organizaciones, repositorios, robots |
| **Keycloak** | `Keycloak`, `KeycloakRealmImport`, namespace | clientes y sus secretos |
| **MetalLB** | `MetalLB`, `IPAddressPool`, `L2Advertisement` | — |
| **cert-manager** | `ClusterIssuer` | — |
| **Connectivity Link** | `Kuadrant`, `Gateway` | — |
| **Pipelines** | `TektonConfig` (con Chains) | claves de firma cosign *(fuera de Git)* |
| **ACS** | `Central`, `SecuredCluster` | **políticas, colecciones, informes** |
| **ACM** | `MultiClusterHub`, `Policy`/`Placement`/`PlacementBinding` | — |

## Reglas que no se rompen

- **Ningún secreto en Git.** Los manifiestos referencian un `Secret` por su
  nombre; el valor se crea en el cluster o lo sincroniza un gestor de secretos.
  Los playbooks leen sus credenciales del entorno o de un *vault*.
- **La instalación del operador no se gestiona aquí.** `Subscription` y
  `OperatorGroup` se aplican una vez al preparar el cluster.
- **Idempotencia.** Un `oc apply -k` y una reejecución de los playbooks se
  repiten sin efectos secundarios.

# workshop-demo-platform-config — configuración de la plataforma

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
| **Workload** | keycloak, connectivity-link, cert-manager, metallb, service-mesh | A los spokes por ambiente, vía `ApplicationSet` |
| **Hub** | acm, quay, acs, pipelines, developer-hub | Solo al hub, vía `Application` directa |

> **Por qué pipelines es hub-only.** El CI construye la imagen y la publica en
> el registro; el CD le pide a Argo que sincronice. Ninguna de las dos cosas
> corre dentro de un spoke: quien despliega a dev/prod es Argo CD. Un solo Tekton
> en el hub basta — no hace falta instalarlo en cada cluster.

## Quién instala vs quién configura: ACM vs Argo

Instalar operadores por Argo CD es fragil — OLM resuelve dependencias a su ritmo y
Argo pelea con eso (Subscriptions `OutOfSync`, hooks imperativos). El patron de
referencia de Red Hat separa las dos cosas:

| Tarea | Herramienta | Donde |
|---|---|---|
| **Instalar el operador** (+ fijar canal) | **ACM Policy** (`OperatorPolicy`) | `acm/gitops/base/operadores/` |
| **Configurar el operando** (los CR) | **Argo CD** | `<producto>/gitops/` |

`OperatorPolicy` es superior a una `Subscription` a secas: no solo crea el objeto,
**verifica que el operador quedo sano** (CSV instalado, deployment disponible, CRD
presente). Se agrupan en dos Policies por destino — `instalar-operadores-hub`
(quay, acs, developer-hub, pipelines) e `instalar-operadores-workload` (keycloak,
metallb, cert-manager, connectivity-link) — cada una con su Placement por rol.

Asi, un cluster nuevo importado por ACM recibe sus operadores por politica, y Argo
solo se ocupa de la configuracion.

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

El día 0 lo ejecuta el **playbook de bootstrap** — idempotente, y también la vía
de día 2 para el propio plano de control:

```bash
ansible-playbook bootstrap/ansible/bootstrap.yml -e base_domain=<dominio-base-del-cluster>
```

Ese playbook instala los operadores del hub (GitOps, ACM), aplica el CR `ArgoCD`
y el RBAC del controller, crea **todos** los AppProjects (`gitops-control`,
`workshop-platform`, `workshop-multicluster`, `workshop`) y termina aplicando la
Application raíz. A partir de ahí gobierna Argo: la raíz sincroniza `gitops/`,
que contiene:

```
gitops/
├── clusters/      # la cadena ACM+Argo: binding, placements, GitOpsCluster
├── appsets/       # los ApplicationSet que hacen fan-out a los spokes por rol
└── apps/          # las Applications de los productos hub
```

El CR `ArgoCD`, los AppProjects y las `Subscription`/`OperatorGroup` de los
operadores del hub **no** los sincroniza Argo: son plano de control y viven en
`bootstrap/manifests/`, aplicados por el playbook. La regla que enseña el
material: **lo que Argo necesita para existir no lo gestiona Argo** — la
barandilla (el AppProject) no debe ser instalable por el mismo mecanismo al que
limita.

## Estructura

```
workshop-platform/
├── bootstrap/              # día 0: manifiestos del plano de control + playbook (ansible/)
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
| **Developer Hub** | CR `Backstage` + ConfigMaps (app-config, plugins, RBAC csv), Software Templates | — *(todo declarativo)* |
| **Service Mesh** | CR `Istio` + `IstioCNI` *(vía **Helm**, no Kustomize — ver nota)* | — |

## Reglas que no se rompen

- **Ningún secreto en Git.** Los manifiestos referencian un `Secret` por su
  nombre; el valor se crea en el cluster o lo sincroniza un gestor de secretos.
  Los playbooks leen sus credenciales del entorno o de un *vault*.
- **La instalación del operador no se gestiona aquí.** `Subscription` y
  `OperatorGroup` se aplican una vez al preparar el cluster.
- **Idempotencia.** Un `oc apply -k` y una reejecución de los playbooks se
  repiten sin efectos secundarios.

## Helm vs Kustomize: por qué service-mesh es la excepción

Todos los productos usan **Kustomize** (`base` + `overlays`) menos **service-mesh**,
que usa **Helm** (`service-mesh/helm/` con `values.yaml` + `envs/values-<amb>.yaml`).
Es deliberado, como ejemplo comparativo:

- **Kustomize** parchea valores conocidos sobre un YAML fijo. Es lo natural para
  CRs de operador con pocos cambios por ambiente (hostname, réplicas). Lo usan los
  demás productos.
- **Helm** templatiza: los valores se inyectan en `{{ plantillas }}` desde un
  fichero de values, y admite lógica (el `IstioCNI` se renderiza con un `if`).
  Es la herramienta cuando hay templating real o se consume un chart de terceros.

Regla práctica (consenso 2026): *Kustomize para lo conocido, Helm para lo
desconocido*. Para estos CRs simples Kustomize bastaría; el chart existe para
mostrar la diferencia. Argo consume Helm de forma nativa con `helm.valueFiles`.

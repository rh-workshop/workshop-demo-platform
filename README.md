# workshop-demo-platform-config — configuración de la plataforma

Este repositorio guarda la configuración de **todos los productos que sostienen
la plataforma** sobre OpenShift, desplegada por el patrón oficial **Red Hat ACM +
OpenShift GitOps** desde un hub central. Es el tercer repositorio del modelo,
junto al de **aplicación** (`workshop-app`) y al de **configuración de
despliegue** (`workshop-config`).

## Modelo mental: GitOps central multi-cluster

Hay **un solo Argo CD, en el cluster hub**, con Red Hat ACM. Desde ahí se
despliega a los clusters workload (dev, test, prod, contingencia — un cluster
por ambiente; los que existan), importados por ACM. No hay un Argo por cluster.
Este es el patrón canónico documentado por Red Hat: la cadena
**`ManagedClusterSetBinding` → `Placement` → `GitOpsCluster` → `ApplicationSet`**.

> **¿Vas a adoptar esta base con tus propios clusters/repos/apps?** Todo lo
> específico de un adoptante es un dato: el checklist completo, en orden, está
> en [`docs/adopcion-cliente.md`](docs/adopcion-cliente.md).

- **`ManagedClusterSetBinding`** vincula el cluster set al namespace de Argo.
- **`Placement`** selecciona los clusters destino por su etiqueta `environment`
  (dev / test / prod / contingencia). El hub lleva `role=hub` y **no** recibe
  cargas workload. Un ambiente sin cluster no genera nada: se activa al
  importar su cluster, sin tocar manifiestos.
- **`GitOpsCluster`** registra en Argo los clusters que deciden los Placement:
  crea un Secret de cluster por cada uno. Sin él, Argo no sabe cómo llegar a un
  spoke.
- **`ApplicationSet`** con generador **`clusterDecisionResource`** lee las
  PlacementDecisions y genera una Application por (producto × cluster): fan-out
  automático. Un producto nuevo o un cluster nuevo se propagan solos.

Los productos se dividen en dos grupos según dónde viven:

| Grupo | Productos | Dónde se despliega |
|---|---|---|
| **Workload** | keycloak, connectivity-link, cert-manager, kafka, metallb, service-mesh | A los spokes por ambiente, vía `ApplicationSet` |
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
| **Instalar el operador** (+ fijar canal) | **ACM Policy** (`OperatorPolicy`) | `acm/gitops/base/policies/install-operators/` |
| **Configurar el operando** (los CR) | **Argo CD** | `<producto>/gitops/` |

`OperatorPolicy` es superior a una `Subscription` a secas: no solo crea el objeto,
**verifica que el operador quedo sano** (CSV instalado, deployment disponible, CRD
presente). Se agrupan en dos Policies por destino — `install-operators-hub`
(quay, acs, developer-hub, pipelines) e `install-operators-workload` (keycloak,
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
de día 2 para el propio plano de control. Todo lo específico del entorno es
**parametrizable**: cualquiera lo reutiliza con sus propios clusters sin tocar
el playbook.

```bash
# 1. Describir el entorno propio: copiar la plantilla y editarla (queda fuera de Git)
cp bootstrap/ansible/clusters.example.yml bootstrap/ansible/clusters.yml

# 2. Credenciales de los spokes, SIEMPRE por el entorno (nunca en Git):
#    un token cluster-admin (oc whoami -t) o la ruta a un kubeconfig por spoke,
#    en la variable que cada entrada de clusters.yml declara (token_env/kubeconfig_env)
export SPOKE_DEV_KUBECONFIG=/ruta/al/kubeconfig-dev
export SPOKE_PROD_KUBECONFIG=/ruta/al/kubeconfig-prod

# 3. (Solo repos privados) credenciales del repositorio Git
export GIT_REPO_URL=... GIT_USERNAME=... GIT_TOKEN=...

# 4. Ejecutar con el KUBECONFIG del HUB activo
ansible-playbook bootstrap/ansible/bootstrap.yml
```

Variables (defaults en el playbook; valores reales en `clusters.yml`, o con `-e`):

| Variable | Qué es | Default |
|---|---|---|
| `base_domain` | dominio de apps completo del hub (`apps.cluster-X...`) | *(obligatoria)* |
| `managed_clusters` | inventario: nombre, `environment`, `role` y, por spoke, `api_url` + `token_env`/`kubeconfig_env` | solo `local-cluster` |
| `quay_host` | hostname del registro Quay | derivado de `base_domain` |
| `keycloak_host` | hostname del SSO | derivado de `base_domain` |
| `storage_class` | StorageClass para volúmenes persistentes | `""` (la default del cluster) |
| `use_metallb` | desplegar MetalLB (solo bare-metal; en cloud sobra) | `true` |

> **MetalLB solo en bare-metal.** En un cloud (AWS, Azure, GCP) el cloud provider
> ya provisiona un balanceador real para cada `Service` de tipo LoadBalancer, y
> MetalLB en modo L2 **no funciona**: la red virtual no reenvía el ARP gratuito en
> el que se apoya, así que las IPs del pool no serían enrutables. Poner
> `use_metallb: false` evita instalar un componente inservible que además dejaría
> el Gateway esperando una IP que nunca llega.

Ese playbook instala los operadores del hub (GitOps, ACM), aplica el CR `ArgoCD`
y el RBAC del controller, crea **todos** los AppProjects (`gitops-control`,
`workshop-platform`, `workshop-multicluster`, `workshop`), aplica la Application
raíz, espera a que Argo deje el `MultiClusterHub` en `Running` y entonces
**importa los spokes en ACM** (namespace + `ManagedCluster` +
`KlusterletAddonConfig` + `auto-import-secret`, esperando a que cada uno quede
`Available`) y homologa sus etiquetas `environment`/`role`. El import es
idempotente: un spoke ya unido no se re-importa. A partir de ahí gobierna Argo:
la raíz sincroniza `gitops/`, que contiene:

```
gitops/
├── clusters/      # la cadena ACM+Argo: binding, placements, GitOpsCluster
├── appsets/       # los ApplicationSet: fan-out de productos a los spokes por rol,
│                  # descubrimiento de los servicios del repo de aplicaciones
│                  # (workshop-services-dev) y previews efímeros por Pull Request
│                  # (workshop-previews-pr: una Application por PR abierto, en su
│                  # namespace demo-service-pr-<n>, destruida al cerrarse el PR)
└── apps/hub/      # las Applications de lo que solo vive en el hub: los productos
                   # (acm, quay, acs, monitoring...) y el pipeline del workshop
```

### El orden de arranque: por qué hay sync-waves

En un cluster **nuevo** los CRDs de ACM (`Placement`, `ManagedClusterSetBinding`,
`GitOpsCluster`) todavía no existen: los instala el `MultiClusterHub`, que a su vez
lo crea Argo al sincronizar `acm/`. Sin orden explícito la raíz intenta aplicarlo
todo a la vez, los recursos que usan esos CRDs fallan, y como el sync se aborta
entero **tampoco se crea el `MultiClusterHub`**: el arranque se bloquea a sí mismo.

Las `sync-wave` rompen ese ciclo — Argo no pasa de una wave hasta que la anterior
está sana:

| Wave | Qué | Por qué ahí |
|---|---|---|
| `-1` | `namespace-governance` | Las cuotas y el RBAC existen antes de que nada despliegue dentro |
| `0` | `config-acm` | Crea el `MultiClusterHub`, que instala los CRDs de ACM |
| `2` | Resto de productos del hub | Ya hay plataforma donde apoyarse |
| `3` | `Placement`, `ManagedClusterSetBinding`, `GitOpsCluster` | Sus CRDs existen desde la wave 0 |
| `4` | Los `ApplicationSet` | El generador `clusterDecisionResource` lee las `PlacementDecision` de la wave 3 |

El `SkipDryRunOnMissingResource=true` de esos recursos es complementario, no
alternativo: evita que el dry-run inicial invalide el sync, pero **no** ordena la
aplicación real. Hacen falta las dos cosas.

### Cuándo un ApplicationSet y cuándo una Application suelta

La regla no es "servicios sí, operadores no": es **si el conjunto varía o no**.
Un ApplicationSet existe para que nadie tenga que editar Git cuando aparece un
elemento nuevo. Si el conjunto es uno y fijo, el generador sobra.

| Qué se despliega | Qué varía | Cómo se declara |
|---|---|---|
| Servicios del workshop | el dev añade y quita apps (y cada servicio decide en qué ambientes vive creando su overlay) | AppSets `workshop-services-<ambiente>`, generador `git`: escanean `apps/*/overlays/<ambiente>` |
| Operadores de workload (keycloak, connectivity-link, cert-manager, kafka, metallb) | ACM añade y quita clusters | AppSet `workload-<ambiente>` (uno por ambiente: dev/test/prod/contingencia), generador `matrix(clusterDecisionResource × list)` |
| Configuración de monitorización | va a **todos** los clusters, hub incluido | AppSet `monitoring` sobre `clusters-all`; el overlay sale de la etiqueta `environment` |
| Operadores solo del hub (acm, quay, acs, pipelines) | **nada**: un destino conocido | Application suelta en `apps/hub/` |

Las etiquetas de las que dependen los Placement (`environment`, `role`) las
homologa el playbook de bootstrap sobre **todos** los ManagedCluster: ACM no las
pone al importar un spoke, y sin ellas ningún Placement lo elige — el cluster se
queda sin desplegar en silencio. Añadir un cluster es añadir una entrada a
`managed_clusters` en `bootstrap/ansible/clusters.yml` (con su `api_url` y la
variable de entorno de sus credenciales) y reejecutar el bootstrap, que lo
importa y lo etiqueta; nada más lo nombra.

Por eso **los operadores sí pasan por ApplicationSet** — los de workload, que
hacen fan-out a los spokes. Los del hub no, porque un generador que siempre
devuelve un elemento es una indirección sin propósito: nunca se instalan en los
clusters administrados (ver el playbook de bootstrap).

Consecuencia práctica: **en `apps/hub/` va solo lo que ningún ApplicationSet
genera.** Declarar ahí un servicio que ya descubre el AppSet crearía dos dueños
sobre el mismo destino.

> `connectivity-link` aparece en los dos modelos y **no es un duplicado**:
> `connectivity-link-hub` (Application suelta) instala Kuadrant en el hub, que
> también expone APIs, y `connectivity-link-dev` (generada por `workload-dev`)
> lo instala en el spoke. Mismo overlay, destinos distintos.

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
├── vars/                   # platform-vars.yml: el ÚNICO fichero de datos de los playbooks
│                           # de producto (prefijo de orgs, ambientes, apps, clients)
├── gitops/                 # el árbol GitOps central (clusters, appsets, apps)
├── quay/{gitops,ansible}/       # QuayRegistry → Argo · orgs/robots → API
├── keycloak/{gitops,ansible}/   # Keycloak/RealmImport → Argo · clientes → API
├── metallb/gitops/         # MetalLB, IPAddressPool, L2Advertisement
├── cert-manager/gitops/    # ClusterIssuer
├── connectivity-link/gitops/    # Kuadrant, Gateway
├── pipelines/gitops/       # TektonConfig (+ firma con Chains)
├── workshop-pipelines/     # gitops/: CI, CD y promoción entre orgs de Quay · runs/: PipelineRun de ejemplo
└── acs/{gitops,ansible}/        # Central/SecuredCluster → Argo · políticas → API
```

> **Por qué los pipelines del workshop viven aquí y no en el repo de
> aplicaciones:** el pipeline de CI monta el workspace `git-credentials`, un
> token con permiso de ESCRITURA sobre `workshop-demo-app-config` (promociona
> el digest). Quien edita el pipeline controla ese token, así que su definición
> es gobierno de plataforma. Por la misma razón las **Applications** de los
> servicios no las declara el repo de aplicaciones: las generan los
> ApplicationSets `workshop-*` de `gitops/appsets/` a partir de sus carpetas
> `apps/*/overlays/dev`.

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

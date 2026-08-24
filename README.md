# workshop-platform — configuración de la plataforma

Este repositorio guarda la configuración de **todos los productos que sostienen
la plataforma** sobre OpenShift. Es el tercer repositorio del modelo, junto al de
**aplicación** (`workshop-app`) y al de **configuración de despliegue**
(`workshop-config`).

## La frontera que ordena este repositorio

No todo lo que configura un producto se puede declarar en Git y dejar que Argo CD
lo reconcilie. Hay dos planos, y **cada carpeta de producto los separa**:

| Plano | Qué es | Quién lo aplica | Dónde vive |
|---|---|---|---|
| **Declarativo** | Objetos que el operador reconcilia: CRs, `Namespace`, `ConfigMap` | **Argo CD** | `<producto>/gitops/` |
| **Imperativo** | Lo que solo existe **detrás de la API del producto** | **Ansible** | `<producto>/ansible/` |

> **Por qué no todo puede ser GitOps.** Argo CD reconcilia *recursos de
> Kubernetes*. Una organización de Quay, un cliente de Keycloak o una política de
> ACS **no son recursos de Kubernetes**: viven dentro de la base de datos del
> producto y solo se crean llamando a su API REST. No hay CRD que los represente,
> así que no hay nada que Argo pueda vigilar. Ese trabajo lo hace Ansible, de
> forma **idempotente**: se puede reejecutar sin duplicar nada.

## Cómo se despliega: app-of-apps

Argo CD **no** se gestiona a sí mismo en este repositorio, y los `AppProject`
tampoco. El CR `ArgoCD` y los proyectos se aplican **a mano en el bootstrap del
clúster**, una sola vez, para no mezclar OLM/GitOps con la reconciliación de Argo
(la fuente clásica de Applications `OutOfSync` perpetuas).

Lo único que Argo gestiona es el árbol de `Application`. La estrategia es
**app-of-apps**: se aplica una sola Application raíz y ella descubre a las demás.

```
gitops/apps/
├── root-application.yaml     # la ÚNICA que se aplica a mano
└── children/                 # una Application por producto — las descubre la raíz
    ├── quay-application.yaml
    ├── keycloak-application.yaml
    ├── metallb-application.yaml
    ├── cert-manager-application.yaml
    ├── connectivity-link-application.yaml
    ├── pipelines-application.yaml
    └── acs-application.yaml
```

```bash
oc apply -f gitops/apps/root-application.yaml
```

A partir de ahí, cada hija apunta a `<producto>/gitops/overlays/<ambiente>` y
Argo lo sincroniza solo.

## Estructura

```
workshop-platform/
├── gitops/apps/            # app-of-apps: raíz + una Application por producto
├── quay/
│   ├── gitops/             # QuayRegistry, namespace          → Argo CD
│   └── ansible/            # organizaciones, repos, robots     → API
├── keycloak/
│   ├── gitops/             # Keycloak, KeycloakRealmImport     → Argo CD
│   └── ansible/            # clientes y sus secretos           → API
├── metallb/gitops/         # MetalLB, IPAddressPool, L2Advertisement → Argo CD
├── cert-manager/gitops/    # ClusterIssuer                     → Argo CD
├── connectivity-link/gitops/  # Kuadrant, Gateway              → Argo CD
├── pipelines/gitops/       # TektonConfig (+ firma con Chains) → Argo CD
└── acs/
    ├── gitops/             # Central, SecuredCluster           → Argo CD
    └── ansible/            # políticas, colecciones, informes  → API
```

Cada `gitops/` sigue el patrón Kustomize del resto de la plataforma: `base/` con
el *qué* y `overlays/<ambiente>/` con el *dónde y cuánto*.

## Qué gobierna cada producto

| Producto | Va por GitOps | Va por Ansible |
|---|---|---|
| **Quay** | `QuayRegistry`, namespace | organizaciones, repositorios, robots |
| **Keycloak** | CR `Keycloak`, `KeycloakRealmImport`, namespace | clientes y sus secretos |
| **MetalLB** | `MetalLB`, `IPAddressPool`, `L2Advertisement` | — *(sin plano de API)* |
| **cert-manager** | `ClusterIssuer`, `Certificate` | — *(sin plano de API)* |
| **Connectivity Link** | `Kuadrant`, `Gateway` | — |
| **Pipelines** | `TektonConfig` (con Tekton Chains) | claves de firma cosign *(fuera de Git)* |
| **ACS** | `Central`, `SecuredCluster` | **políticas, colecciones, informes** |

Dos casos que conviene tener presentes:

- **ACS es el extremo de Ansible.** El `Central` y el `SecuredCluster` son CRs,
  pero las políticas de seguridad, las colecciones y los informes de
  vulnerabilidades —lo que de verdad se ajusta a diario— solo existen tras la API
  de RHACS. No hay CRD.
- **MetalLB y cert-manager son 100% GitOps.** No tienen plano de API propio; todo
  su estado son CRs. Ahí Ansible sobra.

## Reglas que no se rompen

- **Ningún secreto en Git.** Ni contraseñas, ni tokens de robot, ni claves de
  firma, ni secretos de cliente. Los manifiestos referencian un `Secret` **por su
  nombre**; el valor se crea en el clúster o lo sincroniza un gestor de secretos.
  Los playbooks leen sus credenciales de variables de entorno o de un *vault*,
  nunca de un fichero versionado.
- **La instalación del operador no se gestiona aquí.** Las `Subscription` y los
  `OperatorGroup` se aplican una sola vez al preparar el clúster. Este repositorio
  guarda la **configuración** que el operador reconcilia, no su instalación.
- **Idempotencia.** Tanto un `oc apply -k` como una reejecución de los playbooks
  deben poder repetirse sin efectos secundarios.

## Cómo se aplica

La parte declarativa, dejando que Argo CD la sincronice (o a mano con Kustomize):

```bash
oc kustomize quay/gitops/overlays/dev
```

La parte imperativa, con Ansible, una vez que el producto ya responde:

```bash
ansible-playbook quay/ansible/organizaciones.yml
```

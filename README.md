# workshop-platform — configuración de los productos de plataforma

Este repositorio guarda la configuración de los productos que sostienen la
plataforma: **Quay** (registro de imágenes) y **Keycloak** (proveedor de
identidad). Es el tercer repositorio del modelo, junto al de **aplicación**
(`workshop-app`) y al de **configuración de despliegue** (`workshop-config`).

## La frontera que ordena este repositorio

No todo lo que configura un producto se puede declarar en Git y dejar que Argo CD
lo reconcilie. Hay dos planos, y **cada carpeta de producto los separa**:

| Plano | Qué es | Quién lo aplica | Dónde vive |
|---|---|---|---|
| **Declarativo** | Objetos que el operador reconcilia: `QuayRegistry`, `Keycloak`, `KeycloakRealmImport`, `Namespace`, `ConfigMap` | **Argo CD** | `<producto>/gitops/` |
| **Imperativo** | Lo que solo existe **detrás de la API del producto**: organizaciones y robots de Quay, clientes de Keycloak | **Ansible** | `<producto>/ansible/` |

> **Por qué no todo puede ser GitOps.** Argo CD reconcilia *recursos de
> Kubernetes*. Una organización de Quay o un cliente de Keycloak **no son
> recursos de Kubernetes**: viven dentro de la base de datos del producto y solo
> se crean llamando a su API REST. No hay CRD que los represente, así que no hay
> nada que Argo pueda vigilar. Ese trabajo lo hace Ansible, de forma
> **idempotente**: se puede reejecutar sin duplicar nada.

## Estructura

```
workshop-platform/
├── quay/
│   ├── gitops/        # QuayRegistry, namespace — los reconcilia Argo CD
│   └── ansible/       # organizaciones, repositorios y cuentas robot — API
└── keycloak/
    ├── gitops/        # Keycloak, KeycloakRealmImport — los reconcilia Argo CD
    └── ansible/       # clientes y sus secretos — API de administración
```

Cada `gitops/` sigue el patrón Kustomize del resto de la plataforma: `base/` con
el *qué* y `overlays/<ambiente>/` con el *dónde y cuánto*.

## Qué gobierna cada producto

### Quay

| Va por GitOps | Va por Ansible |
|---|---|
| El `QuayRegistry` (la instancia, sus componentes y su almacenamiento) | Las **organizaciones** |
| El `Namespace` | Los **repositorios** y su visibilidad |
| El `Secret` de configuración, *referenciado por nombre* | Las **cuentas robot** y sus permisos |

### Keycloak

| Va por GitOps | Va por Ansible |
|---|---|
| El CR `Keycloak` (instancia, base de datos, hostname) | Los **clientes** creados tras el arranque |
| El `KeycloakRealmImport` (el realm de partida) | Los **secretos de cliente** que consumen las aplicaciones |
| El `Namespace` | Ajustes que se hacen en la consola de administración |

## Reglas que no se rompen

- **Ningún secreto en Git.** Ni contraseñas, ni tokens de robot, ni secretos de
  cliente. Los manifiestos referencian un `Secret` **por su nombre**; el valor se
  crea en el clúster o lo sincroniza un gestor de secretos. Los playbooks leen
  sus credenciales de variables de entorno o de un *vault*, nunca de un fichero
  versionado.
- **La instalación del operador no se gestiona aquí.** Las `Subscription` y los
  `OperatorGroup` se aplican una sola vez al preparar el clúster. Este repositorio
  guarda la **configuración** que el operador reconcilia, no su instalación.
- **Idempotencia.** Tanto un `oc apply -k` como una reejecución de los playbooks
  deben poder repetirse sin efectos secundarios.

## Cómo se aplica

La parte declarativa, con Kustomize (o dejando que Argo CD la sincronice):

```bash
oc kustomize quay/gitops/overlays/dev
```

La parte imperativa, con Ansible, una vez que el producto ya responde:

```bash
ansible-playbook quay/ansible/organizaciones.yml
```

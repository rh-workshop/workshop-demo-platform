# quay — registro de contenedores

`company-quay`, la instancia de Quay Enterprise del hub. Registro central de
imágenes de la plataforma: build (CI) → push → firma → escaneo → promoción
entre organizaciones por ambiente.

## GitOps vs playbooks — qué gestiona cada uno

| | Vive en | Por qué |
|---|---|---|
| El `QuayRegistry` (CR del operador) | `gitops/base/quayregistry.yaml`, Argo | Es un recurso de Kubernetes: Argo lo reconcilia igual que cualquier otro CR |
| `config.yaml` (`SUPER_USERS`, feature flags, storage) | `Secret quay-config-bundle`, sincronizado por `ExternalSecret` desde OpenBao | Contiene `SECRET_KEY`/`DATABASE_SECRET_KEY`: nunca en Git |
| Organizaciones, repos, robots, cuotas, auto-prune | `ansible/organizations.yml` + `governance.yml` | No son recursos de Kubernetes — viven en la base de datos de Quay, solo accesibles por su API REST. Argo no tiene nada que reconciliar |

## `configBundleSecret` — el huevo-gallina del día-0

`config.yaml` (`SECRET_KEY`, `DATABASE_SECRET_KEY`, `SUPER_USERS`, feature
flags) es lo único que el operador de Quay necesita para arrancar, pero es un
secreto y el almacén (OpenBao) no existe todavía en el arranque en frío.
Resuelto en 2 pasos, no 1:

1. **`bootstrap/ansible/bootstrap.yml`** (paso 10) crea el `Secret
   quay-config-bundle` directo en Kubernetes, con claves generadas
   aleatoriamente — la única vez que esto es imperativo sobre Kubernetes en
   todo el componente.
2. **`quay/ansible/config-bundle-vault.yml`** corre después, una vez que
   OpenBao ya está vivo: traslada ese mismo valor al almacén
   (`platform/quay/config-bundle`). El `ExternalSecret`
   (`gitops/base/externalsecret-quay-config-bundle.yaml`) toma posesión del
   Secret desde ahí — **cambios futuros a `config.yaml` van por el almacén**,
   nunca por `oc create secret` a mano.

## Hallazgo real: escribir cuotas exige un feature flag, no solo `SUPER_USERS`

Verificado en vivo (2026-09-04) y documentado en detalle en
[`docs/production-backlog.md`](../docs/production-backlog.md#15-parecía-bug-de-la-ui-era-una-feature-flag-que-faltaba-2026-09-04):
un superusuario confirmado (`quayadmin`) no podía cambiar cuotas desde la
consola — `403 insufficient_scope`. No era un bug de la UI: el endpoint de
escritura de cuota (`OrganizationQuota.put` en el código fuente de Quay)
exige además `FEATURE_SUPERUSERS_FULL_ACCESS: true`, que **no** viene
incluido por tener `SUPER_USERS` configurado. Ya está en `config.yaml` desde
el bootstrap; si se reconstruye el config bundle a mano, no olvidar este flag.

## Storage: S3 nativo vs NooBaa

`quay_storage_backend` en `vars/platform-vars.yml` decide el componente
(`gitops/components/storage-s3/` o `storage-noobaa/`):

- **`s3`** (default en nube): Quay habla directo con el object storage vía
  `CredentialsRequest`. `quay/ansible/storage.yml` crea el bucket si falta y
  escribe `DISTRIBUTED_STORAGE_CONFIG` en el config bundle.
- **`noobaa`** (alternativa on-prem/bare-metal sin object storage real): MCG
  emula S3 sobre un PVC de 50Gi. Marcado NO-PRODUCCIÓN en un cluster de nube —
  ver `docs/production-backlog.md`, hallazgo de almacenamiento.

## Organizaciones y flujo de promoción

4 organizaciones por ambiente (`{{ org_prefix }}-{dev,test,prod,contingencia}`,
hoy `company-*`) más `company-tooling` (imágenes del CI: semgrep, syft,
gitleaks, espejadas desde upstream por `mirror-tooling.yml` para que el CI
nunca dependa de un registro externo en tiempo de build).

Cada organización tiene sus propios robots (`+puller`, `+pusher`) con permisos
mínimos, asignados por `robot-permissions.yml` (incluido desde
`organizations.yml`). La promoción entre ambientes (`dev → test → prod`) no
reconstruye la imagen: copia el mismo dígesto de una organización a otra
(`skopeo copy`), preservando la firma — ver
`workshop-pipelines/gitops/base/pipeline-promote-image.yaml`.

## Cómo ejecutar los playbooks

Todos leen credenciales del entorno, nunca de Git:

```bash
export QUAY_HOST=<host-de-quay>
export QUAY_TOKEN=<token-oauth>   # Applications -> Create new application -> Generate token
ansible-playbook quay/ansible/organizations.yml   # organizaciones, repos, robots
ansible-playbook quay/ansible/governance.yml      # cuota + auto-prune por organización
ansible-playbook quay/ansible/mirror-tooling.yml  # espejar herramientas del CI
ansible-playbook quay/ansible/pull-secrets.yml    # credenciales de origen del registro, al almacén
```

`config-bundle-vault.yml` y `storage.yml` los invoca `bootstrap.yml` en orden;
no suelen ejecutarse sueltos salvo para reconstruir el config bundle a mano.

## Referencias

- [`docs/production-backlog.md`](../docs/production-backlog.md) — hallazgos
  de la revisión contra la documentación oficial de Red Hat.
- [`docs/production-outside-the-lab.md`](../docs/production-outside-the-lab.md) —
  qué de esto es NO-PRODUCCIÓN (Postgres managed, storage NooBaa, TLS
  wildcard) y el camino real para un cliente.

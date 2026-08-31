# Guía de adopción: qué cambiar para usar esta plataforma con TUS clusters

Esta base funciona con **cualquier** conjunto de clusters, repositorios y
aplicaciones **sin tocar lógica**: todo lo específico de un adoptante es un
**dato**, y este documento dice dónde vive cada uno y en qué orden se cambia.
Úsalo como checklist, de arriba abajo.

Regla general del repositorio: **iteración sobre datos, no ramificación** — los
playbooks y ApplicationSets recorren listas; desactivar algo es comentar una
entrada, nunca editar un `when`.

## 0. Decisiones previas (tómalas antes de tocar nada)

| Decisión | Opciones | Dónde impacta |
|---|---|---|
| Prefijo de organizaciones del registro | `company` u otro | `vars/platform-vars.yml` (`org_prefix`) + placeholders literales (paso 4) |
| Cuántos ambientes | los 4 (`dev/test/prod/contingencia`) o un subconjunto | `clusters.yml`; un ambiente sin cluster queda inactivo solo |
| Lenguaje(s) de las aplicaciones | `dotnet` / `java` / `python` / `go` | parámetro `language` de cada PipelineRun de CI |
| Dominios | el `*.apps.<cluster>` de cada cluster o dominio corporativo propio | overlays por ambiente (paso 5) |
| MetalLB | solo bare-metal (en cloud, `use_metallb: false`) | `clusters.yml` |
| Repositorios Git | fork de los 3 repos (app, app-config, platform-config) | URLs en AppSets/AppProjects (paso 4) |

## 1. Haz fork de los tres repositorios

- `workshop-demo-app` — código (lo construye el CI; Argo NO lo mira).
- `workshop-demo-app-config` — Kustomize de despliegue de cada servicio.
- `workshop-demo-platform-config` — este repo: plataforma, GitOps y pipelines.

## 2. Describe TUS clusters (un solo fichero, fuera de Git)

```bash
cp bootstrap/ansible/clusters.example.yml bootstrap/ansible/clusters.yml
```

Edita `clusters.yml`: `base_domain` del hub, `storage_class`, `use_metallb` y
una entrada por cluster en `managed_clusters` (nombre, `environment`, `role`,
`api_url` y el NOMBRE de la variable de entorno con su token). Ese fichero está
en `.gitignore` y **nunca** se versiona. No hace falta tener los 4 ambientes:
un ambiente sin cluster no genera Applications; al añadirlo después basta
reejecutar el bootstrap.

## 3. Fija tu modelo de plataforma (un solo fichero, SÍ versionado)

Edita `vars/platform-vars.yml` — lo consumen los playbooks de Quay, Keycloak y
ACS por iteración:

- `org_prefix` — tu prefijo de organizaciones del registro.
- `org_email_domain` — dominio de los correos administrativos.
- `environments` — ambientes con su cuota, retención y `ci_push` (quién puede
  publicar; `false` = solo promoción).
- `image_repositories` — un elemento por aplicación (mismos nombres que las
  carpetas `apps/<servicio>` del repo de configuración).
- `tooling_repositories` — espejos de las herramientas del CI.
- `keycloak_realm` y `keycloak_clients` — un client M2M por servicio expuesto.

## 4. Sustituye los valores literales que Argo/Tekton leen de Git

Argo CD y Tekton no leen variables de Ansible: los manifiestos llevan valores
literales. Son DOS sustituciones mecánicas sobre tu fork:

```bash
# 4a. URLs de los repositorios (AppSets, Applications, AppProjects, pipelines)
git grep -l 'github.com/rh-workshop' | xargs sed -i \
  's|github.com/rh-workshop|github.com/<TU-ORGANIZACION>|g'

# 4b. Prefijo de organizaciones en defaults de pipelines y runs (y en el repo
#     de app-config, en los newName de los overlays)
git grep -l 'company-' -- workshop-pipelines | xargs sed -i 's/company-/<tu-prefijo>-/g'
```

Y en `workshop-demo-app-config`: los `newName:` de los overlays
(`CHANGE_ME_QUAY_HOST/company-<amb>/<servicio>`) con tu host de Quay y tu
prefijo. El nombre del `QuayRegistry` (`company-quay`, en
`quay/gitops/base/quayregistry.yaml`) también lleva el prefijo; si lo cambias,
cambia el hostname derivado (`quay_host` en el bootstrap).

## 5. Pon TUS dominios en los overlays por ambiente

El hostname de cada producto expuesto se fija **en el overlay del ambiente,
nunca en la base**. Ficheros a editar (por ambiente `dev/test/prod/contingencia`):

| Producto | Fichero(s) del overlay |
|---|---|
| Keycloak | `keycloak/gitops/overlays/<amb>/keycloak-*.yaml` + patch del Route en `kustomization.yaml` |
| Gateway (Connectivity Link) | `connectivity-link/gitops/overlays/<amb>/gateway-hostname.yaml`, `route-apis-host.yaml`, `authpolicy-default-issuer.yaml` (issuer = el Keycloak del MISMO ambiente) |
| Servicios (app-config) | `apps/<servicio>/overlays/<amb>/httproute-*.yaml` (hostname) y `authpolicy-*.yaml` (issuer) |
| Monitorización | `monitoring/gitops/overlays/{prod,contingencia}/prometheus-retention.yaml` (la `storageClassName` de TU cluster) |

El realm (`workshop`) aparece en los `issuerUrl` y en el `KeycloakRealmImport`
(`keycloak/gitops/base/keycloakrealmimport-workshop.yaml`): si usas otro realm,
renómbralo en esos tres sitios y en `keycloak_realm` de `vars/platform-vars.yml`.

## 6. Espeja las herramientas del CI en TU registro

Única excepción a "solo Red Hat" (no existe imagen Red Hat de estas tres);
espejo con skopeo, nunca Docker Hub/ghcr.io en tiempo de build. Lo hace el
bootstrap (o `quay/ansible/mirror-tooling.yml` suelto) leyendo `source` y `tag`
de `tooling_repositories` en `vars/platform-vars.yml`: subir de versión es
cambiar el tag ahí (y en los defaults literales de
`pipeline-ci-build-image.yaml`, que Tekton no lee de vars) y reejecutar.

## 7. Crea los secretos (NUNCA en Git)

El bootstrap genera solos `quay-config-bundle` y `rhdh-backend-secret` si
faltan. Los del CI/CD se crean a mano — recetas completas en
`workshop-pipelines/README.md`:

1. `quay-push-credentials` — robot pusher del ambiente de CI.
2. `cosign-signing-key` — llavero de firma (generado directo como Secret).
3. `acs-pipeline-credentials` — token de Central + su CA.
4. `git-credentials` — PAT con escritura sobre TU fork de app-config.
5. `quay-promotion-credentials` — robot de promoción (credencial SEPARADA).
6. `argocd-env-configmap` + `argocd-env-secret` — cuenta técnica `pipeline`.

El pull secret del kubelet (`quay-pull-credentials`, ligado al ServiceAccount
`builder` de cada namespace de CI) ya NO se crea a mano: lo siembra
`quay/ansible/pull-secrets.yml` fusionando el robot pusher del ambiente con el
puller de tooling (lectura, solo esa organización), consultando sus tokens a la
API de Quay.

## 8. Arranca

```bash
export SPOKE_DEV_TOKEN=... SPOKE_TEST_TOKEN=... SPOKE_PROD_TOKEN=... SPOKE_CONTINGENCIA_TOKEN=...
ansible-playbook bootstrap/ansible/bootstrap.yml     # hub + spokes + Quay completo (orgs, gobierno, espejos, pull secrets)

# Los playbooks de Quay también corren sueltos (p. ej. tras añadir un ambiente);
# QUAY_TOKEN sale del secreto quay-enterprise/quay-admin-token que persiste el bootstrap.
export QUAY_HOST=... QUAY_TOKEN=...
ansible-playbook quay/ansible/organizations.yml      # orgs/robots por ambiente
ansible-playbook quay/ansible/governance.yml         # cuotas y retención
ansible-playbook quay/ansible/mirror-tooling.yml     # espejo de herramientas del CI
ansible-playbook quay/ansible/pull-secrets.yml       # pull secret del builder (pusher + tooling puller)

export KEYCLOAK_HOST=... KEYCLOAK_ADMIN=... KEYCLOAK_PASSWORD=...
ansible-playbook keycloak/ansible/clients.yml        # clients M2M

export ACS_HOST=... ACS_TOKEN=... QUAY_ROBOT_USER=... QUAY_ROBOT_TOKEN=... COSIGN_PUBLIC_KEY="$(cat cosign.pub)"
ansible-playbook acs/ansible/integrations.yml        # registro + firma (anota el ID que imprime)
```

## 9. Adapta el CI a tus aplicaciones

Por cada aplicación: un PipelineRun de CI (copiar
`workshop-pipelines/runs/pipelinerun-ci-build-image.yaml`) fijando
`image-repository`, `overlay-path`, `image-name`, `build-args` y **`language`**
(`dotnet` | `java` | `python` | `go`; el contrato de cada task y el del
Containerfile están en `workshop-pipelines/README.md`). El pipeline es el
mismo para todos los lenguajes.

## 10. Qué NO tienes que tocar (lógica)

- `bootstrap/ansible/bootstrap.yml` — recorre `managed_clusters`.
- Los playbooks de producto — recorren `vars/platform-vars.yml`.
- Los `Pipeline`/`Task` de Tekton — parametrizados por el run.
- Los ApplicationSets — el fan-out lo deciden Placements y carpetas de overlay:
  un servicio entra en un ambiente **creando `apps/<servicio>/overlays/<amb>`**;
  un cluster entra en el modelo **añadiéndolo a `clusters.yml`**.

## Nota sobre los ambientes de los servicios de demostración

Solo `demo-service` recorre la cadena completa dev → test → prod →
contingencia. Los otros cuatro servicios (`api-service`, `canary-service`,
`bluegreen-service`, `circuit-breaker-service`) viven SOLO en dev **por
decisión**, no por olvido: existen para enseñar patrones (API management,
canary, blue-green, circuit breaker), no promoción. Sus organizaciones de
registro y sus Placements ya soportan los 4 ambientes: promocionar uno es crear
sus overlays `test/prod/contingencia`, sin tocar plataforma.

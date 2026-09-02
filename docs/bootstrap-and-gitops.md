# Bootstrap y GitOps: quién arranca la plataforma y quién la gobierna

> **EJECUTADO.** Este documento analiza el arranque (día 0) que existía, lo
> contrasta con la práctica establecida y propone la separación de
> responsabilidades. La migración de la sección 5 **se ejecutó y validó en
> vivo**: el plano de control (CR `ArgoCD`, RBAC del controller y todos los
> AppProjects) lo aplica ahora `bootstrap/ansible/bootstrap.yml`, los dos roots
> corren en el AppProject `gitops-control`, la Application `workshop-argocd`
> desapareció (sus recursos fueron adoptados sin recrearse) y el AppProject
> `workshop` dejó de ser drift.

## 1. El estado actual (verificado en el cluster y en los repos)

En `workshop-demo-app-config`, la Application `workshop-argocd` (onda 0, en
`project: default`) despliega `platform/argocd/overlays/dev`, que contiene:

- el **AppProject `workshop-platform`** — el proyecto que usan las otras 12
  Applications del root: el proyecto se despliega a sí mismo por GitOps;
- el **CR `ArgoCD`** de la instancia `openshift-gitops` — Argo CD se reconfigura
  a sí mismo, incluido el controller que hace la reconciliación;
- el **ClusterRole/ClusterRoleBinding** `argocd-gateway-api` — Argo CD se amplía
  sus propios permisos.

Además, el AppProject `workshop` (participantes) existe **solo en el cluster**
(aplicado con `kubectl apply`, sesión 05): no está en ningún repositorio — drift.

En `workshop-demo-platform-config` el criterio es el contrario y está escrito:
«El CR `ArgoCD` y las `Subscription`/`OperatorGroup` de los operadores **no** se
gestionan aquí: se aplican en el bootstrap del cluster». Los dos repos del mismo
workshop enseñan dos criterios opuestos.

## 2. Qué dice la práctica establecida

- **La autogestión de Argo CD es un patrón soportado, no un antipatrón.** La
  documentación oficial dice: *«Argo CD is able to manage itself since all
  settings are represented by Kubernetes manifests»*, con un requisito
  obligatorio: *«When managing Argo CD with Argo CD, you **must** enable the
  `ServerSideApply=true` sync option»*.
  ([Declarative Setup](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/))
- **Los AppProjects declarativos en el árbol app-of-apps son práctica común**,
  normalmente en una app dedicada de "projects" con sync-wave temprana; el
  huevo-gallina se resuelve exactamente como aquí: la app de projects corre en
  un proyecto privilegiado. ([Cluster Bootstrapping](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/),
  [Self-Managed Argo CD — App of Everything](https://medium.com/devopsturkiye/self-managed-argo-cd-app-of-everything-a226eb100cf0))
- **Pero app-of-apps es una herramienta de administrador**: *«App of Apps is an
  admin-only tool»* y los proyectos con acceso al namespace de Argo *«tienen
  efectivamente privilegios de administrador»*. Upstream recomienda revisar el
  campo `project` de cada hija y ser conservador con auto-sync y prune sobre la
  app que gestiona al propio Argo.
  ([Cluster Bootstrapping](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/))
- **En OpenShift GitOps, la instancia se configura por el CR `ArgoCD`** que
  reconcilia el operador; para producción se recomienda no depender de la
  instancia por defecto tal cual y configurar siempre vía CR.
  ([Red Hat: Setting up an Argo CD instance](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/1.13/html/argo_cd_instance/setting-up-argocd-instance),
  [Stephen Nimmo: Bootstrapping an OpenShift Cluster with OpenShift GitOps](https://stephennimmo.com/2025/06/24/bootstrapping-an-openshift-cluster-with-openshift-gitops/))
- **El patrón Red Hat multi-cluster** arranca el GitOps de los clusters por
  **Policy de ACM** (operador + Application inicial) y deja a Argo el resto —
  coherente con `acm/gitops/base/policies/install-operators/` de este repo.
  ([GExperts: Bootstrapping Cluster Configuration with RHACM and OpenShift GitOps](https://gexperts.com/wp/bootstrapping-openshift-gitops-with-rhacm/),
  [blog.stderr.at: Setup OpenShift GitOps/Argo CD](https://blog.stderr.at/gitopscollection/2024-02-02-setup-argocd/))

**Veredicto:** el patrón actual no es un antipatrón *per se* — es la variante
"self-managed" documentada — pero está mal ejecutado (falta `ServerSideApply`,
`prune: true` + `selfHeal` sobre el propio CR `ArgoCD`, todo colgando de
`project: default`) y, sobre todo, **contradice el criterio que el propio
material enseña** en este repo y en el engagement real: instalación y arranque
imperativos, configuración por Argo.

## 3. Riesgos concretos del estado actual

1. **Sync del CR `ArgoCD` sin server-side apply**: violación directa del
   requisito upstream; un apply client-side sobre un CR que el operador completa
   con defaults produce conflictos de campos y OutOfSync (hoy mitigado con
   `resourceIgnoreDifferences`, que oculta el síntoma).
2. **Un commit malo en `platform/argocd/` puede dejar el controller inoperativo**
   (p. ej. un límite de memoria demasiado bajo → OOMKilled). Con `selfHeal` el
   propio Argo reintenta aplicar la configuración rota. La red de seguridad real
   es el **operador** (sigue reconciliando el CR) y un `oc apply` manual del CR
   corregido — es decir, la recuperación es imperativa de todos modos.
3. **`prune: true` en el root + AppProject dentro del árbol**: un error de
   renderizado que haga desaparecer el AppProject del manifiesto deja a las 12
   Applications del proyecto sin proyecto válido (sync bloqueado con
   «project not found»).
4. **Escalada de privilegios silenciosa**: la app en `project: default` puede
   desplegar cualquier cosa en cualquier destino; hoy gestiona un ClusterRole
   que amplía los permisos del propio controller. Un commit en ese path es
   equivalente a cluster-admin.
5. **Drift no versionado**: el AppProject `workshop` vive solo en el cluster.

## 4. Separación propuesta

Regla única, la misma del engagement: **el plano de control de GitOps no se
gestiona a sí mismo**. Tres planos, tres herramientas:

| Plano | Qué contiene | Quién lo aplica | Dónde vive |
|---|---|---|---|
| **Bootstrap (día 0, imperativo)** | Operadores del hub (GitOps, ACM), CR `ArgoCD`, RBAC del controller (`argocd-gateway-api`), **todos los AppProjects**, credenciales de repos/seeds, y el `oc apply` de las root Applications | **Ansible** (idempotente, reejecutable para día 2 del propio plano de control) | `bootstrap/ansible/` de este repo |
| **Declarativo (día 1..N)** | Apps de negocio, pipelines, políticas Kuadrant, CRs de producto, appsets, placements, Policies de ACM (incluida la instalación de operadores de los spokes) | **Argo CD** | `gitops/` y `<producto>/gitops/` (este repo) + `workshop-demo-app-config` |
| **API de producto** | Orgs/robots de Quay, clients de Keycloak, integraciones de ACS | **Ansible por producto** (ya existe) | `<producto>/ansible/` |

Decisiones concretas:

- **El CR `ArgoCD` sale del árbol de Argo** y pasa al playbook de bootstrap
  (server-side apply). Cambiarlo en día 2 = editar el YAML en Git y reejecutar
  el playbook: sigue versionado, pero quien lo aplica no es el componente que
  ese YAML puede romper.
- **Los AppProjects los crea el bootstrap**, antes que cualquier Application.
  Desaparece el huevo-gallina y ninguna Application necesita `project: default`.
  El root pasa a un proyecto de control acotado (p. ej. `gitops-control`:
  destino `openshift-gitops`, kinds `Application`/`AppProject` solamente).
- **El AppProject `workshop` (participantes) se versiona** en el bootstrap: hoy
  es drift.
- **`platform/argocd/` de `workshop-demo-app-config` desaparece como app de
  Argo**: su contenido (AppProject, CR `ArgoCD`, ClusterRole) es gobierno de
  plataforma, no de equipos de aplicación — se muda a `bootstrap/` de este repo.
- **`platform/pipelines/` se queda donde está y bajo Argo**: son recursos
  namespaced propiedad del equipo de aplicación (Pipelines, SA, RoleBindings),
  encajan en el AppProject `workshop-platform`; los `runs/` siguen siendo
  manuales.
- **La instalación de operadores no cambia de criterio**: en los spokes, por
  `OperatorPolicy` de ACM (ya en `acm/gitops/base/policies/install-operators/`); en el **hub**,
  el huevo-gallina (ACM aún no existe) lo resuelve el mismo playbook de
  bootstrap instalando GitOps + ACM.

Valor didáctico: el workshop pasa a enseñar una frontera nítida — «lo que Argo
necesita para existir no lo gestiona Argo» — que además coincide con el patrón
del repo de plataforma y con el modelo del engagement.

## 5. Plan de migración (sin romper las Applications ni el cluster)

Estado de partida verificado en `cluster-qthlq`: 14 Applications Synced/Healthy;
`workshop-root` y `workshop-argocd` en `project: default`; las otras 12 en
`workshop-platform`.

| # | Paso | Riesgo | Mitigación |
|---|---|---|---|
| 1 | Crear `bootstrap/ansible/` en este repo con el playbook y los manifiestos (AppProjects, CR `ArgoCD`, ClusterRole) copiados tal cual de `platform/argocd/base/` | Ninguno (solo Git) | Revisar con `oc diff` antes del paso 3 |
| 2 | En el cluster: quitar `selfHeal`/`prune` de `workshop-argocd` (o pausar auto-sync) para que deje de pelear durante la transición | Bajo | Es un `oc patch` reversible |
| 3 | Ejecutar el playbook por primera vez (server-side apply): **adopta** los recursos existentes sin recrearlos | Conflicto de field managers | `kubernetes.core.k8s` con `server_side_apply` + `force_conflicts` |
| 4 | Borrar la Application `workshop-argocd` **sin cascada** (`argocd app delete --cascade=false`; no tiene finalizer de recursos, así que el borrado del objeto no arrastra al AppProject ni al CR) y quitarla del `kustomization.yaml` del root en el mismo commit | **Alto si se borra con cascada**: se llevaría el AppProject `workshop-platform` y las 12 apps quedarían sin proyecto | Verificar tras el borrado: `oc get appproject workshop-platform` y `oc get argocd openshift-gitops` intactos |
| 5 | Commit en `workshop-demo-app-config`: eliminar `platform/argocd/` y actualizar README (tabla de ondas: la onda 0 pasa al bootstrap) | Bajo — el root ya no la referencia | El root prunea la carpeta huérfana solo si algo la referenciara; no es el caso |
| 6 | Crear el AppProject `gitops-control` (bootstrap) y mover `workshop-root` de `project: default` a él (`oc patch` + actualizar el YAML del root) | Medio: un proyecto mal acotado bloquea el sync del root con «not permitted in project» | Probar primero el whitelist con `argocd app sync --dry-run`; rollback = volver a `default` |
| 7 | Versionar el AppProject `workshop` de los participantes en el bootstrap (hoy solo existe en el cluster) | Ninguno | `oc get appproject workshop -o yaml` como base, limpiando campos de servidor |
| 8 | Actualizar los README de ambos repos y el material de la sesión 05 para reflejar la nueva frontera | Ninguno | — |

Orden estricto: 3 antes que 4 (el bootstrap debe ser dueño de los recursos antes
de que Argo los suelte); 4 antes que 5 (el objeto Application primero, el path
de Git después); 6 al final (es endurecimiento, no dependencia).

## 6. Nota sobre el AppProject que se despliega a sí mismo

No es una herejía — upstream lo hace en el patrón "app of everything" — pero el
precio es exactamente el rodeo observado: una Application privilegiada en
`project: default` cuyo repositorio se convierte en cluster-admin efectivo. En
una plataforma con frontera de gobierno seria (y en material que la enseña), el
AppProject es la **barandilla**, y la barandilla no debe ser instalable por el
mismo mecanismo al que limita. Crearlo en el bootstrap cuesta una tarea de
Ansible y elimina el huevo-gallina, el `project: default` y el riesgo de prune.

## 7. Secretos manuales del día-0 (recetas de recreación)

Ningún Secret vive en Git. Los del CI están documentados en
`workshop-pipelines/README.md`; estos dos NO lo estaban y el día-0 de un
cluster nuevo se atasca justo ahí:

### `quay-config-bundle` (namespace `quay-enterprise`)

Lo referencia `quay/gitops/base/quayregistry.yaml` (`configBundleSecret`); sin
él el operador de Quay no reconcilia el `QuayRegistry`. Contiene un único
`config.yaml` con las claves de instancia (`SECRET_KEY`, `DATABASE_SECRET_KEY`)
y los toggles de features (auth por base de datos, auto-prune, cuotas):

```bash
# SECRET_KEY y DATABASE_SECRET_KEY: aleatorias y ÚNICAS por instalación; el
# resto de claves se copia de la instalación de referencia (o de la consola de
# config de Quay). Guardar el config.yaml resultante fuera de Git.
cat > /tmp/quay-config.yaml <<YAML
SECRET_KEY: "$(openssl rand -hex 32)"
DATABASE_SECRET_KEY: "$(openssl rand -hex 32)"
AUTHENTICATION_TYPE: Database
FEATURE_USER_INITIALIZE: true
FEATURE_USER_CREATION: false
FEATURE_ANONYMOUS_ACCESS: false
FEATURE_GARBAGE_COLLECTION: true
FEATURE_AUTO_PRUNE: true
FEATURE_CHANGE_TAG_EXPIRATION: true
DEFAULT_TAG_EXPIRATION: 2w
TAG_EXPIRATION_OPTIONS: [2w, 4w, 8w]
FEATURE_GENERAL_OCI_SUPPORT: true
FEATURE_REFERRERS_API: true
FEATURE_QUOTA_MANAGEMENT: true
FEATURE_USER_LOG_ACCESS: true
YAML
oc create secret generic quay-config-bundle -n quay-enterprise \
  --from-file=config.yaml=/tmp/quay-config.yaml
rm /tmp/quay-config.yaml
```

### `rhdh-backend-secret` (namespace `developer-hub`)

Lo referencia `developer-hub/gitops/base/configmap-app-config.yaml`
(`${BACKEND_SECRET}`, el token de servicio del backend de Backstage); sin él el
pod de Developer Hub arranca en CrashLoop por variable sin resolver:

```bash
oc create secret generic rhdh-backend-secret -n developer-hub \
  --from-literal=BACKEND_SECRET="$(openssl rand -base64 32)"
```

## 8. La cuenta de Argo CD del pipeline (decisión de seguridad)

El paso de CD (`argocd-task-sync-and-wait`) usaba `admin` con la password real
en `argocd-env-secret`, dentro de `workshop-demo-dev` — el namespace donde el
grupo `app-developers` tenía `edit` (que incluye `get secrets`): leer ese
Secret escalaba a control total del GitOps de los 3 clusters. Se corrigió en
DOS capas, para que ninguna dependa de la otra:

1. **Cuenta local `pipeline`** (`bootstrap/manifests/argocd.yaml`:
   `extraConfig` + `rbac`): solo `get`/`sync` sobre las Applications del
   proyecto `workshop-platform`. Alta de la password:

   ```bash
   PASS=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
   HASH=$(htpasswd -nbBC 10 "" "$PASS" | tr -d ':\n' | sed 's/\$2y/\$2a/')
   oc patch secret argocd-secret -n openshift-gitops -p \
     "{\"stringData\":{\"accounts.pipeline.password\":\"$HASH\",\"accounts.pipeline.passwordMtime\":\"$(date -u +%FT%TZ)\"}}"
   oc create secret generic argocd-env-secret -n workshop-demo-dev \
     --from-literal=ARGOCD_USERNAME=pipeline --from-literal=ARGOCD_PASSWORD="$PASS" \
     --dry-run=client -o yaml | oc apply -f -
   ```

2. **`app-developers` sin `secrets` en `workshop-demo-dev`**
   (`namespace-governance/.../workshop-demo-dev/`): Role propio equivalente a
   `edit` pero sin `secrets` ni `serviceaccounts`; el resto de namespaces de
   aplicación conservan `edit` porque no albergan secretos de CI.

3. **Y sin escribir en Tekton, que es lo que de verdad cerraba el agujero.**
   La capa 2, por sí sola, era ilusoria: el Role concedía `["*"]` sobre
   `pipelineruns` y `taskruns`, y **quien puede crear un run puede leer
   cualquier Secret del namespace** — basta declarar un `taskSpec` propio que
   monte `cosign-signing-key`, `git-credentials`, `quay-push-credentials` o
   `argocd-env-secret` como workspace y volcarlo al log. El permiso de crear
   runs equivale al de `get secrets`. Desde la auditoría, `app-developers`
   tiene Tekton en **solo lectura** en ese namespace: lanzar el CI es tarea de
   plataforma o de un disparador automático. En producción el corte correcto es
   otro namespace: los Secrets del CI no deben convivir con un grupo que pueda
   ejecutar cargas ahí (ver `docs/backlog.md`).

## 9. Qué gobierna cada mecanismo (criterio, no preferencia)

La plataforma tiene tres mecanismos y el reparto **no es una cuestión de gusto**:
cada uno puede hacer cosas que los otros no. El orden es de preferencia — se baja
al siguiente solo cuando el anterior es incapaz.

### 1. Argo CD (Git) — el DEFAULT

Todo objeto de Kubernetes cuya definición pueda versionarse. Es el mecanismo por
defecto: el estado deseado vive en Git, se revisa por Pull Request y Argo lo
reconcilia de forma continua.

Entra aquí: `QuayRegistry`, `MultiClusterObservability`, `Keycloak`, `Kuadrant`,
`Gateway`, `Deployment`, `Namespace`, `Pipeline`, `Task`,
`AppProject` (vía bootstrap), `CredentialsRequest`…

### 2. Policy de ACM — lo que Argo no alcanza o no debe versionar

Dos casos concretos:

- **Contenido que no puede estar en Git**, típicamente un secreto. La función
  `fromSecret` de un *hub template* LEE el valor en el hub y lo materializa en el
  cluster destino sin que pase por el repositorio. Ejemplo:
  `require-registry-pull-secret`, que replica la credencial del registro.
- **Gobierno continuo sobre N clusters y N namespaces**, donde una lista
  enumerada envejecería. El `object-templates-raw` descubre los namespaces solos,
  repone el objeto si alguien lo borra y alcanza cualquier spoke nuevo que entre
  en su `Placement`. Ejemplos: `require-limitrange`, `require-resourcequota`,
  `install-operators-workload`.

Ventaja sobre sembrar con Ansible: no hay que reejecutar nada por cada cluster ni
mantener a mano una lista de namespaces.

### 3. Ansible — solo lo que NO puede ir por los otros dos

Es la excepción, no la norma. Solo dos categorías:

- **APIs que no son Kubernetes.** No tienen CRD, así que ni Argo ni una Policy
  pueden reconciliarlas: la API de Quay (organizaciones, robots, cuotas,
  auto-prune), la de ACS (integraciones, política de firma), la de Keycloak
  (clientes), la de AWS (crear el bucket de S3) y `skopeo` para el espejado.
- **Secretos de día-0 y el bootstrap.** Lo que Argo necesita para existir (CR
  `ArgoCD`, AppProjects) y los secretos que se componen consultando una API
  externa.

  **Ansible instala EXACTAMENTE DOS operadores, y no debe instalar ninguno más:**
  OpenShift GitOps y ACM. Son los únicos que no pueden instalarse a sí mismos —
  sin Argo no hay quien aplique lo declarativo, y sin ACM no existe el kind
  `OperatorPolicy` con el que se instalan los demás.

  **Los otros doce los instala ACM** con `OperatorPolicy`
  (`acm/gitops/base/policies/install-operators/`): Quay, ACS, Keycloak,
  Connectivity Link, cert-manager, Service Mesh, Pipelines, Developer Hub, MCG,
  AMQ Streams y el resto. Añadir un operador nuevo es añadir una entrada a esa
  Policy — nunca al bootstrap.

  El motivo de fondo: una `OperatorPolicy` alcanza los cuatro clusters de carga
  por su `Placement` y repone la instalación si alguien la retira. El bootstrap
  solo actúa sobre el hub y solo cuando alguien lo ejecuta.

### La prueba para decidir

> ¿Es un objeto de Kubernetes y su contenido puede versionarse? → **Argo**.
> ¿Es de Kubernetes pero su contenido es secreto, o hay que mantenerlo en varios
> clusters/namespaces que cambian? → **Policy de ACM**.
> ¿No es de Kubernetes, o es lo que arranca a Argo? → **Ansible**.

### Errores que este criterio evita

- **Dos dueños sobre el mismo objeto.** `quay/ansible/storage.yml` parcheaba una
  anotación del `QuayRegistry` que gobierna Argo: el siguiente sync la revertía.
  Se cambió por reiniciar los pods del operador — una acción sobre el DESPLIEGUE,
  no sobre el CR.
- **Listas que envejecen.** `pull-secrets.yml` sembraba el secreto namespace por
  namespace desde una lista en `platform-vars.yml`: cada servicio nuevo obligaba a
  editarla y a reejecutar el playbook por cada cluster. Hoy siembra UN origen en
  el hub y la Policy lo replica.

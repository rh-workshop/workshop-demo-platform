# Backlog de gobierno, identidad y cumplimiento

Trabajo derivado de la auditoría de septiembre de 2026 sobre el modelo de
permisos de la plataforma. Es un backlog **distinto** de `backlog.md` (mejoras
funcionales) y de `production-backlog.md` (endurecimiento por producto): aquí solo
entra lo que responde a **quién puede hacer qué, sobre qué, y cómo se demuestra**.

## Cómo está dividido

Cada punto pertenece a **un** dominio de decisión. La división es el criterio de
todo el backlog, porque mezclar dominios es justo lo que produjo los defectos que
lo originan:

| Dominio | Pregunta que responde | Quién decide |
|---|---|---|
| **A. Identidad de la máquina** | ¿Con qué credencial escribe Argo en cada cluster? | Plataforma |
| **B. Frontera de despliegue** | ¿Qué puede desplegar cada repositorio y en qué destino? | Plataforma + Seguridad |
| **C. Identidad de las personas** | ¿Qué ve y qué puede accionar cada grupo en la UI? | Seguridad + RR.HH. |
| **D. Dueño del objeto** | ¿Quién declara cada recurso: Argo, ACM o el playbook? | Plataforma |
| **E. Integridad del cambio** | ¿Cómo se demuestra que un cambio fue revisado? | Seguridad + Cumplimiento |
| **F. Continuidad** | ¿Qué pasa si se pierde el hub? | Plataforma + Riesgo |
| **G. Evidencia** | ¿Qué le enseñamos a un auditor? | Cumplimiento |

Un punto que toque dos dominios está mal planteado y hay que partirlo.

**Severidad**: CRÍTICO (brecha explotable hoy) · ALTO (control ausente que una
auditoría marcaría) · MEDIO (mejora de robustez) · BAJO (higiene).

---

## A. Identidad de la máquina

### A.1 Argo CD escribía en los spokes como cluster-admin — HECHO
`GitOpsCluster` no declaraba `managedServiceAccountRef`, así que ACM entregaba el
token del addon `application-manager`, cuyo ClusterRole es `['*']/['*']/['*']`.
Todo el RBAC enumerado del hub terminaba en el borde del hub: en dev, test, prod y
contingencia Argo podía borrar cualquier cosa.

Resuelto con un `ManagedServiceAccount` (token rotado cada 30 días) y un
`ClusterPermission` de 24 reglas por spoke. Verificado leyendo el ClusterRole
dentro del spoke de producción: cero comodines de escritura, lectura global
preservada para el diff, sin `ClusterRole` ni `ClusterRoleBinding`.

### A.2 Separar la identidad por dominio dentro del hub — ALTO
Una sola ServiceAccount acumula los ClusterRoles de base, operadores, gateway-api,
namespace-governance y políticas. La suma es un superusuario: quien controle
cualquier repo sincronizado alcanza todo lo que la unión permite.

**Restricción técnica verificada:** Argo CD no admite dos cluster-secrets con la
misma URL de servidor (argoproj/argo-cd#9606, #15027), así que "una identidad por
dominio en una sola instancia" **no es posible** sin impersonation.

**Impersonation queda descartada de momento — corregido tras reverificar contra
upstream (2026-09-03):** "Service Account Impersonation" (`AppProject.spec.
destinationServiceAccounts` + `argocd-cm: application.sync.impersonation.enabled`)
es **Beta desde Argo CD v2.13.0**, no alpha. GitOps 1.21.3 embebe Argo CD **3.4.5**
(verificado en vivo: `argocd version --client --short`), muy por encima de ese
umbral — el mecanismo ya está disponible y configurable hoy. La afirmación previa
de que "llega en Argo CD 3.5" mezclaba esto con `app-sync-using-impersonation.md`
("Application Sync using Impersonation"), un flujo distinto y más nuevo (since
v3.5.0) que sí sigue en beta y con matices propios.

Lo que sí sigue siendo cierto, y es la razón real para no adoptarlo todavía:
**las release notes oficiales de OpenShift GitOps 1.21 no mencionan impersonation
en ningún punto** — ni GA, ni Technology Preview, ni deprecado. Sin ninguna postura
pública de Red Hat sobre el feature, no hay SLA ni compromiso de compatibilidad
para un control de segregación de funciones en un banco. La brecha no es madurez
upstream (ya resuelta); es ausencia de soporte declarado por el fabricante de la
distribución que se instala.

**Camino elegido:** dos instancias, que es el modelo GA y documentado —
`openshift-gitops` cluster-scoped para plataforma y gobierno, y una instancia
propia para las aplicaciones. Coste ~5-7 pods.

**Reevaluar** cuando Red Hat declare una postura de soporte para impersonation en
OpenShift GitOps (Technology Preview o GA) — no cuando llegue Argo CD 3.5, que ya
está superado por la versión instalada. Verificar en cada release notes de GitOps.

### A.3 Permisos del server y del applicationset-controller — HECHO
`defaultClusterScopedRoleDisabled` retira los roles cluster-scoped de **todos** los
componentes, no solo del application-controller. Documentado en
`clusterrole-argocd-server.yaml`, incluido el detalle de que un rol que siga la
convención de nombres del operador es borrado por él en la siguiente
reconciliación.

### A.4 `clusterrole-argocd-base.yaml` no lo aplicaba el playbook — HECHO
Estaba en Git y en el cluster, pero `bootstrap.yml` no lo listaba: se había
aplicado a mano. Con `defaultClusterScopedRoleDisabled: true`, un bootstrap limpio
habría dejado a Argo sin ningún permiso, ni de lectura. Añadido junto a
`clusterrole-argocd-server.yaml`, ambos antes que el resto.

### A.5 Permisos de escritura que nadie usaba — HECHO
Comparando los ClusterRoles contra el inventario real de kinds renderizados
sobraban 17: `appprojects`, `subscriptions`, `operatorgroups`, `servicemonitors`,
`prometheusrules`, `pipelineruns`, `taskruns`, `placementdecisions`, `policysets`,
`istiorevisions`, `issuers`, `secretstores`, `gatewayclasses`, `grpcroutes`,
`referencegrants` y `dnspolicies`.

Los dos más sensibles: `appprojects` permitía a Argo reescribir la barandilla que
lo limita, y OLM le permitía instalar operadores — que equivale a ejecutar código
con permisos de cluster. `PlacementDecision` se retiró solo de escritura: el
generador de los AppSets la lee, y esa lectura la cubre la regla global.

---

## B. Frontera de despliegue

### B.1 `workshop-multicluster` concentraba 50 de 69 Applications — HECHO
El eje de división actual es *de qué repositorio viene*, no dominio ni criticidad.
El resultado es un sobre único que mezcla el CR de ACM, un RoleBinding de gobierno
y un ConfigMap de retención de Prometheus, con `server: '*'` sobre 23 namespaces de
5 clusters.

**División propuesta**, por dominio × criticidad:

| Proyecto | Contenido | Destinos |
|---|---|---|
| `gitops-control` | root app | hub, ns de Argo |
| `governance` | cuotas, límites, RBAC, políticas ACM | hub + ns gobernados de spokes |
| `platform-hub` | Quay, ACS, Pipelines, RHDH, OpenBao | hub |
| `platform-workload-nonprod` | productos en dev y test | `*-dev`, `*-test` |
| `platform-workload-prod` | productos en prod y contingencia | `*-prod`, `*-contingencia` |
| `apps-nonprod` | 12 apps de negocio | `*-dev`, `*-test` |
| `apps-prod` | 6 apps de negocio | `*-prod`, `*-contingencia` |
| `workshop-preview` | previews de PR | cluster de dev |

Migradas las 69 sin recrear un solo recurso: cambiar `spec.project` no toca lo
desplegado, porque Argo rastrea por nombre de Application. El reparto final cuadra
con el previsto — 14 en cada `platform-workload-*`, 12 en `apps-nonprod`, 11 en
`platform-hub`, 6 en `apps-prod` y en `governance`, 5 en `tuning`, 1 en
`gitops-control`.

Antes de migrar se comprobó que cada Application cabe en su proyecto destino
(kinds y namespaces contra la allow-list). Solo un recurso no encajaba: el CR
`Console` que declaraba `connectivity-link` — su propio comentario lo llamaba
"decisión del administrador del cluster", que es tuning y no configuración de
producto. Se movió al componente `tuning`, creado para eso.

`workshop-multicluster` y `workshop-platform` quedaron vacíos y se retiraron.

**Por qué también por ambiente:** el patrón dominante en la industria es por
equipo/dominio, y partir por ambiente difumina el *ownership*. Pero el AppProject
es la única barandilla que impide que un manifiesto de dev aterrice en un namespace
de prod, y para segregación de funciones eso pesa más. La síntesis es dominio para
el ownership, ambiente para la criticidad.

### B.2 Permisos sin uso en los AppProjects — HECHO
- `Secret` en `workshop-multicluster`: ningún manifiesto renderizaba uno, y con el
  permiso abierto un commit podía sobrescribir `cosign-signing-key`,
  `argocd-env-secret` u `openbao-eso-token`, con selfHeal manteniendo el valor.
- `RoleBinding` y `Route` en `workshop-platform`: cero usos en los repos de apps;
  el primero permitía enlazar `admin` donde viven los secretos del CI.
- 4 destinos `*-demo-dev` huérfanos: esos namespaces los gobierna la Policy de ACM.
- Un `ServiceAccount` duplicado.

La whitelist de `workshop-platform` quedó en 10 kinds, que es exactamente lo que
los repos de aplicaciones renderizan: nada de más, nada de menos.

### B.3 `Deployment` y `PersistentVolumeClaim` en `workshop-multicluster` — HECHO
Faltaban para el PostgreSQL de Keycloak. Lo interesante del caso: el AppProject
**funcionó como barrera** — frenó un recurso no previsto en vez de aplicarlo en
silencio. Es la evidencia de que la división por proyectos aporta valor real.

### B.4 El `ClusterSecretStore` no tenía `conditions` — HECHO
Cualquier `ExternalSecret` podía materializar cualquier ruta que el token
`eso-read` alcanzara — incluida `platform/keycloak/db-prod` — en un namespace donde
corren pods de negocio. Acotado a los cuatro namespaces que declaran
ExternalSecret: `keycloak`, `kafka` y los dos de ACM. Añadir uno es ahora una
decisión de plataforma, no de quien despliega la aplicación.

### B.5 `KafkaUser` declara sus propias ACLs — MEDIO
Un servicio del repo de apps se autoconcede `Read`/`Write` sobre cualquier topic.
La identidad y sus ACL deberían declararse en el dominio de plataforma; el repo de
apps solo declara sus propios `KafkaTopic`.

### B.6 Los previews de PR aterrizan en el hub — MEDIO
Código de una rama sin revisar corre junto a ACM, Quay, ACS y Argo. Deben ir al
cluster de desarrollo.

### B.7 El proyecto `workshop` es aula, no patrón — BAJO
`*/*` namespaced sobre `user*` permite a un alumno tocar el namespace de otro, y el
repo se sirve por `http://`. Aceptable para formación; hay que dejar escrito que
**no** es plantilla para el banco.

---

## C. Identidad de las personas

### C.1 La cuenta del CI podía sincronizar producción — HECHO
El glob `workshop-platform/*` abarcaba `app-*-prod` y `app-*-contingencia`, y la
credencial vive en el namespace de dev: quien leyera ese Secret desplegaba a
producción. Acotado a `*-dev`, con lectura global conservada para diagnóstico.

Dos detalles del arreglo: la política se asigna **directamente a la cuenta local**
y no a través de un rol, porque con SSO activo un grupo que se llamara igual
heredaría sus permisos; y se retiró `login`, que una cuenta de automatización no
necesita.

### C.2 No había roles intermedios: o admin o nada — HECHO
Solo existe `role:admin` para cluster-admins. Los grupos `platform-admins`,
`app-developers` y `platform-viewers` que referencian los RoleBindings **no existen
ni en la política ni como Group**. Roles propuestos: `platform-operator`,
`app-developer` (sync solo en dev/test, *deny* explícito en prod),
`release-manager` (sync en prod, no desarrolla), `auditor` (solo lectura, sin logs
porque pueden contener datos de clientes).

**Límite verificado:** el RBAC de Argo solo filtra por `<project>/<app>`. **No se
puede filtrar por label ni por cluster destino.** Con los proyectos ya partidos
por ambiente (B.1), el filtro es exacto y no depende de convenciones de nombres.

Los 6 roles quedaron probados uno a uno con `argocd admin settings rbac can`:
`app-developer` sincroniza en no-productivos y tiene *deny* explícito en
producción, `release-manager` justo al revés, `auditor` ve todo y no toca nada —
tampoco los logs, que en producción pueden llevar datos de clientes.

### C.3 Grupos: en el IdP, no en Git — HECHO
Faltaban dos piezas, no una: los grupos **y** el mapeo del claim. El proveedor
`rhbk` no declaraba `claims.groups`, así que aunque se crearan en Keycloak nunca
habrían llegado a OpenShift.

Creados los cinco grupos en el realm `sso`, añadido el mapper `groups` al cliente
`idp-4-ocp` con `full.path=false` (nombres simples, como espera la política de
Argo) y declarado el claim en el IdP. Probado de extremo a extremo: al iniciar
sesión, OpenShift creó el `Group` con la anotación
`oauth.openshift.io/generated: true` y Argo resolvió el rol correspondiente.

La pertenencia vive solo en el IdP, no en Git: versionarla crearía una segunda
fuente de verdad. Contrapartida operativa, documentada en
[`identity-and-groups.md`](identity-and-groups.md): se refresca al iniciar sesión,
así que una baja exige deshabilitar al usuario en Keycloak, no solo sacarlo del
grupo.

### C.4 Terminal web (`exec`) — HECHO
La doc de Argo advierte que da *"los mismos privilegios que la ServiceAccount del
pod"*, y el audit log registra al SA de Argo, **no a la persona**. `oc rsh` queda
auditado con identidad real.

### C.5 Cuenta `admin` local y Route pública — MEDIO
Cuenta con contraseña en un Secret, sin MFA y fuera del SSO. Desactivarla tras
validar el acceso por grupos.

---

## D. Dueño del objeto

### D.1 Cuotas y límites tenían dos dueños — HECHO
Argo (`namespace-governance`) y las políticas de ACM declaraban el mismo
LimitRange con valores distintos; ganaba el último en reconciliar y el hub quedaba
NonCompliant.

**Criterio adoptado — Argo aplica, ACM verifica:** el gobierno se declara una vez
en Kustomize y lo aplica Argo, también en los spokes. Así un cliente **sin ACM**
conserva su gobierno con solo OpenShift GitOps. Donde ACM existe, aporta el reporte
de cumplimiento que Argo no da.

**La excepción, que no es duplicidad:** los namespaces que no se pueden enumerar
por adelantado — los de negocio y los previews de PR, que nacen con cada rama. Ahí
la política va en `enforce`, porque un Kustomize no declara lo que aún no existe.

### D.2 Renombrar `namespace-governance` a `governance` — MEDIO
De 34 recursos, 18 son RBAC y solo 4 son Namespace: el nombre describe la minoría.
Al incorporar grupos y cuotas cluster-scoped, un nombre por namespace obliga a
inventar un componente hermano. Estructura: `cluster/` (Group, PriorityClass,
ClusterResourceQuota), `profiles/` y `namespaces/<ns>/`.

### D.3 Separar `governance` de `platform-tuning` — HECHO
El tuning de nodos (MachineConfig, KubeletConfig, Tuned) y del plano de control
(APIServer, etcd) **no** es gobierno: si un commit se equivoca, los nodos reinician
en cadena y revertir no repara rápido, porque la corrección dispara otro rollout.

**Corrección respecto a un análisis previo:** puede vivir en Argo, no hace falta
sacarlo a Ansible. Lo que dice la doc de Red Hat es que **no se sincronice
automáticamente** — la mitigación oficial es quitar `syncPolicy.automated` entero
(no basta `selfHeal: false`) y usar sync waves. El riesgo documentado: si el nodo
que reinicia aloja el application-controller, el sync se aborta y el
comportamiento queda indefinido.

Alternativa igual de válida: entregarlo como política de ACM en `inform`, y pasar a
`enforce` solo dentro de la ventana.

### D.4 Namespaces con dos creadores — BAJO
En los spokes, los namespaces de producto los declara Argo (base del componente) y
la `OperatorPolicy` de ACM. Sin conflicto de campos hoy, pero conviene elegir: ACM
los crea (es prerequisito del operador) y Argo los adopta con `CreateNamespace=false`.

### D.5 `self-provisioners` permitía crear proyectos fuera del gobierno — HECHO
Cualquier usuario autenticado podía crear un Project sin cuota, sin NetworkPolicy y
sin RBAC, lo que vaciaba de sentido el modelo entero. Retirado con la Policy
`require-no-self-provisioner`, en `enforce` sobre los 5 clusters.

Al escribirla apareció un detalle: pedir a la vez que el ClusterRoleBinding exista
y que no tenga sujetos deja la Policy oscilando. Basta `mustnothave` sobre el
sujeto — al ser el único, ACM elimina el binding entero.

---

## E. Integridad del cambio

### E.1 CODEOWNERS — HECHO (falta activar la protección de rama)
El mismo repo y la misma rama contenían los ClusterRoles, el RBAC por namespace,
las políticas de flota y la configuración de un producto: un cambio de RBAC
necesitaba la misma aprobación que un cambio de color en un panel.

Los tres repos llevan ya `.github/CODEOWNERS`. En plataforma el eje es el
**dominio** (plano de control y gobierno exigen seguridad; los overlays de prod y
contingencia, ventana de cambio); en los repos de aplicaciones el eje es el
**ambiente** — dev y test los aprueba el equipo, prod y contingencia también quien
opera. `base/` cuenta como producción, porque lo heredan todos los ambientes.

**Pendiente y necesario:** activar en cada repo "Require review from Code Owners"
sobre la rama por defecto y crear los equipos en la organización. Sin la
protección de rama el fichero es documentación, no un control — y sin los equipos,
GitHub lo ignora en silencio. Los nombres son marcadores `@CHANGE_ME_ORG/*`.

### E.2 Ventanas de mantenimiento — HECHO
Ningún AppProject define `syncWindows`. Un banco tiene cierres de mes y batch
nocturno en los que nada debe cambiar en producción aunque haya un commit.
`manualSync: false` en la ventana de bloqueo impide saltársela.

### E.3 Firma de commits verificada por Argo — MEDIO
Ningún AppProject usa `signatureKeys`. Matices verificados: Argo **solo verifica
GPG** (ni SSH ni sigstore), verifica el commit HEAD, y Azure DevOps no firma los
merges automáticamente — habría que firmar desde el pipeline de promoción. En Argo
CD 3.5 `signatureKeys` se sustituye por `sourceIntegrity`.

### E.4 Validación determinista en el PR — HECHO
**El punto de mayor retorno de todo el backlog.** Cinco de los seis defectos de
esta auditoría se detectan ahora antes del merge:

| Control | Qué habría detectado |
|---|---|
| `oc apply --dry-run=server -k` | La probe con dos handlers (falló en bucle) |
| `kubeconform` + schemas de CRD | Campos inválidos en CRs de producto |
| Conftest: prohibir placeholders fuera de dev | El issuer `CHANGE_ME` que llegó a 3 entornos |
| Conftest: kinds ⊆ whitelist del AppProject | El `Deployment` bloqueado por el proyecto |
| Conftest: `verbs: ["*"]` prohibido | Permisos excesivos |
| Cruce con recursos de políticas ACM | El LimitRange con dos dueños |

Implementado como Task `manifest-validate` y Pipeline `validate-manifests` en
`workshop-pipelines/gitops/`, disparados por `on-event: [pull_request]` desde el
`.tekton/` de los tres repos. El repo de plataforma se registró en Pipelines as
Code, donde faltaba.

Cada control se probó reproduciendo el defecto que lo motiva: un `CHANGE_ME` en un
overlay de prod, un `ClusterRole` con comodín y un `Secret` fuera de la allow-list
del AppProject — los tres detenidos. Y los repos actuales pasan limpios: 26
overlays renderizan, cero marcadores, cero comodines.

El control del AppProject queda desactivado en el repo de plataforma (`appproject:
""`): allí conviven manifiestos de varios proyectos y compararlos contra uno solo
daría falsos positivos. Se recupera con la partición de B.1.

### E.5 `FailOnSharedResource` y `orphanedResources` — BAJO
Dos Applications pueden pelearse por el mismo recurso sin que nadie se entere.

---

## F. Continuidad

### F.1 No hay backup del hub ACM — CRÍTICO
Todo el plano de control vive en un cluster sin copia: 69 Applications, los
AppProjects, las credenciales de import de los 4 spokes, Quay, ACS Central,
OpenBao. Con *push model*, perder el hub significa **no desplegar en ningún
ambiente, contingencia incluida** — el sitio de respaldo no puede activarse por
GitOps si el GitOps no existe.

Dos trampas documentadas: tras un restore los spokes importados quedan en
`Pending Import` y hay que re-importarlos a mano; y el tracking por *label* de Argo
choca con Velero, hace falta `resourceTrackingMethod: annotation`.

### F.2 Dependencias circulares hub ↔ contingencia — ALTO
Quay solo está en el hub, así que tras un reinicio de nodo en contingencia los pods
**no pueden hacer pull**. ACS Central en el hub deja el admission controller sin
Central. Y Keycloak es el IdP de los clusters: **esto ocurrió durante la auditoría**
— al reiniciarse Keycloak, el login del cluster dejó de funcionar y hubo que
recuperar el acceso con un token de ServiceAccount.

### F.3 Identidad de emergencia — HECHO
Consecuencia directa de F.2, y confirmada en vivo: el cluster tenía **un solo**
proveedor de identidad (Keycloak) y `kubeadmin` ya estaba retirado, así que un
fallo del IdP dejaba el cluster inaccesible justo cuando había que arreglarlo.

Resuelto de forma distinta en el hub y en los spokes, porque el problema no es el
mismo:

**El hub usa htpasswd como único proveedor.** El hub *despliega* Keycloak: si
además autenticara contra él, arreglar un Keycloak caído exigiría entrar al
cluster y entrar al cluster exigiría Keycloak. Se retiró el proveedor `rhbk`. La
pertenencia a grupos pasa a asignarse con `oc adm groups add-users` — es un
cluster de operación con pocas cuentas nominales, no una plataforma de
autoservicio. Ver `bootstrap/manifests/oauth-hub.reference.yaml`.

**Los spokes conservan Keycloak y añaden htpasswd.** Allí no hay circularidad. Se
entrega en tres piezas: el Secret por `ManifestWork` (es un secreto, no puede ir
a Git), el proveedor por la Policy `require-break-glass-idp` (`musthave` sobre la
lista, así que **añade** sin tocar `rhbk`) y `cluster-admin` por
`ClusterPermission` — autenticar sin autorizar no sirve en una emergencia.

Probado de extremo a extremo en los cuatro spokes: login correcto, `whoami`
devuelve la cuenta y `auth can-i '*' '*'` responde `yes`.

**La cuenta no puede llamarse `admin`.** Con `mappingMethod: claim` OpenShift
rechaza que dos identidades reclamen el mismo usuario: si ya existe un `admin`
que entró por Keycloak, el login htpasswd falla con HTTP 500 y
`cannot be claimed by identity ... already mapped to [rhbk:...]`.

### F.6 Réplicas incompletas que no se notan — HECHO
Keycloak llevaba tres días a **1/2 réplicas** en prod y contingencia sin que
saltara nada. No era un rollout lento: el pod `keycloak-0` conservaba en memoria
la credencial anterior de PostgreSQL y fallaba su probe con
`password authentication failed for user "keycloak"`. El StatefulSet actualiza en
orden inverso y espera a que esa réplica esté lista, así que el rollout no
avanzaba nunca.

Se corrigió recreando el pod — la contraseña del Secret ya era la correcta, sólo
el proceso arrancado seguía con la vieja.

Lo que hacía el fallo invisible es que **no hay caída**: la réplica sana atiende y
Keycloak responde 200. La Application queda `Synced/Progressing`, que en un panel
con decenas de aplicaciones se confunde con un despliegue en curso.

Añadida la Policy `require-workloads-fully-available`, que compara
`status.readyReplicas` con las pedidas en los StatefulSet de plataforma. En
`inform`: la corrección depende del caso y una Policy que reiniciara pods por su
cuenta convertiría un problema de disponibilidad en una caída.

Documentado además en `externalsecret-keycloak-pgsql-user.yaml` que rotar la
contraseña exige **tres** pasos —almacén, `ALTER USER` en la base de datos y
reinicio del StatefulSet—; omitir el tercero reproduce exactamente este fallo.

### F.4 Backup y cifrado de etcd — ALTO
Los Secrets que ESO materializa están **en claro** en etcd y en sus snapshots.
`APIServer.spec.encryption.type: aesgcm` y un CronJob de `cluster-backup.sh` a
almacenamiento externo. Nota: el backup de ACM **no** cubre etcd.

### F.5 HA del propio Argo CD — MEDIO
Sin `ha.enabled`, con Redis en instancia única y sin PDB. Ya hubo un OOM del
controller que dejó los syncs colgados.

---

## G. Evidencia

### G.1 El audit log no sale del cluster — CRÍTICO
Vive en los masters con rotación local: se pierde en días. PCI-DSS pide 12 meses
con 3 inmediatos. Sin esto no hay forma de demostrar quién cambió qué.

Agravante que refuerza A.2: **hoy toda escritura aparece como la misma
ServiceAccount**. Un auditor no puede distinguir un cambio de cuota de un cambio de
RBAC. Separar identidades no es solo mínimo privilegio: es lo que hace legible el
audit log.

### G.2 Compliance Operator con PCI-DSS y CIS — ALTO
No está instalado. Es la evidencia técnica continua que pide una auditoría, y
detecta drift de nodos que GitOps no ve. Hay que ejecutar los perfiles de
plataforma **y** de nodo.

### G.3 Notificaciones de Argo — MEDIO
Los eventos que registran quién sincronizó tienen TTL de horas. Git dice quién
cambió; no dice quién desplegó ni cuándo llegó al cluster.

### G.4 Verificación de firma en el nodo — MEDIO
ACS verifica en admisión, pero el webhook es evitable si Central cae —
precisamente el escenario de F.2. `ClusterImagePolicy` (GA en 4.20) hace que el
**nodo** rechace el pull, sin depender de ningún servicio.

### G.5 Historial de cumplimiento — BAJO
El estado de las políticas es instantáneo. Un auditor pregunta por una fecha
pasada. La API de historial de ACM es Technology Preview; alternativa GA: métricas
en Observability con retención larga.

---

## Orden de ataque

El criterio es **cerrar brechas explotables antes que añadir controles nuevos**, y
dentro de eso, lo que no rompe nada antes de lo que exige ventana.

**Fase 1 — HECHA.** A.1, A.3, A.4, A.5, B.2, B.3, B.4, C.1, D.1, D.5, F.3.

Verificado en el cluster: el CI ya no puede sincronizar prod ni contingencia
(`argocd admin settings rbac can` responde No), los 9 permisos retirados dan `no`
en `oc auth can-i` y los 13 necesarios siguen en `yes`, las 10 Policies de ACM
quedan Compliant en los 5 clusters, el ClusterSecretStore sigue `Valid` con los 7
ExternalSecret sincronizando, y el break-glass inicia sesion como cluster-admin
sin pasar por Keycloak.

**Fase 2 — HECHA.** E.4 (validación en el PR) · E.1 (CODEOWNERS).

Queda una acción fuera de Git: activar "Require review from Code Owners" en la
rama por defecto de los tres repos y crear los equipos de la organización. Hasta
entonces CODEOWNERS sugiere revisores pero no los exige.

**Fase 3 — HECHA en su mayor parte.** B.1 (8 AppProjects) · C.2 (roles de UI) ·
C.4 (`exec`) · D.3 (tuning separado) · E.2 (ventanas).

Se migró por lotes de riesgo creciente —tuning, aplicaciones no productivas, el
resto— verificando entre cada uno que ninguna Application se rompía. Las 69
quedaron sanas.

**Pendiente de la fase:** A.2 (dos instancias de Argo), que separa la identidad de
la máquina en el hub. Es independiente del resto y no bloquea nada.

**Fase 4 — continuidad y evidencia (1-2 meses)**
F.1 (backup del hub, con restore probado) · G.1 (audit log al SIEM) · F.4 (etcd) ·
G.2 (Compliance Operator) · F.2 (romper las dependencias circulares).

**Fase 5 — refinamiento**
El resto de MEDIO y BAJO, más E.3 cuando GitOps incorpore Argo CD 3.5.

---

## Lo que se decidió NO hacer

- **Impersonation ahora** (A.2): alpha en la versión instalada, sin soporte.
  Reevaluar con Argo CD ≥ 3.5.
- **Sacar el tuning a Ansible** (D.3): puede vivir en Argo sin sync automático.
  Ansible se reserva para los seeds vía API, que no son recursos de Kubernetes.
- **Cuatro instancias de Argo**: con 69 Applications el volumen no lo justifica.
  Dos, divididas por *persona y privilegio*, no por volumen.
- **AppProjects solo por ambiente**: difumina el ownership. La división es por
  dominio, y el ambiente entra dentro de cada dominio.
- **Auto-remediación con IA**: los propios fabricantes la condicionan a aprobación
  humana, los modos operador están en alpha y no hay evidencia pública en entornos
  regulados.

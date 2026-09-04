# Identidad: grupos, roles y quién ve qué

Cómo una persona pasa de iniciar sesión a tener permisos, y dónde se decide cada
paso. Complementa `governance-backlog.md`, que dice *qué falta*; esto dice *cómo
funciona lo que ya hay*.

## Un solo modelo, en los 5 clusters

Hub y spokes autentican igual: **solo htpasswd**, sin OIDC.

| | Hub y spokes |
|---|---|
| Proveedor | **Solo htpasswd** |
| Pertenencia a grupos | `oc adm groups add-users` |

**Ningún cluster autentica contra Keycloak, ni siquiera los spokes que lo
despliegan como producto.** La razón original era la circularidad del hub —
despliega Keycloak, así que no puede depender de él para autenticar, o un
Keycloak caído deja el cluster sin forma de entrar a repararlo. Los spokes no
tienen esa circularidad técnica (su Keycloak no depende de sí mismos), pero el
problema de fondo es el mismo: Keycloak es un producto que la plataforma
gobierna vía GitOps, no un IdP corporativo externo e independiente del cluster
que lo aloja. Un `Deployment` mal sincronizado o un `RealmImport` roto tiene el
mismo efecto que el hub quería evitar. Se unificó: **todo el mundo usa htpasswd,
en los 5 clusters** (`bootstrap/manifests/oauth-hub.reference.yaml` y
`oauth-spoke.reference.yaml`, mismo modelo).

**Consecuencia:** la pertenencia a grupos NO llega por claim OIDC en ningún
cluster. Los objetos `Group` los declara Git
(`namespace-governance/.../identity/`, vacíos) y la pertenencia se da de alta a
mano con `oc adm groups add-users`, por cluster — el hub y cada spoke tienen
bases de identidad independientes.

## Alta y baja de una persona

```bash
oc adm groups add-users <grupo> <usuario>       # alta
oc get group <grupo> -o jsonpath='{.users}'     # comprobación
```

No hay pertenencia declarada en Git a propósito: versionarla crearía una segunda
fuente de verdad frente a lo que el cluster ya tiene.

### Dar de baja a una persona

**En cada cluster donde tenga cuenta** — el hub y los spokes tienen bases de
identidad independientes:

```bash
oc delete oauthaccesstoken --field-selector=userName=<usuario>   # corta las sesiones vivas
oc adm groups remove-users <grupo> <usuario>
oc delete identity htpasswd:<usuario> ; oc delete user <usuario>
```

Y quitar la línea del usuario del fichero htpasswd (regenerar el Secret), que es
lo que impide volver a entrar con la misma contraseña.

## Los grupos y lo que pueden hacer

| Grupo | Rol en Argo | Puede | No puede |
|---|---|---|---|
| `platform-admins` | `admin` | Todo | — |
| `platform-operators` | `platform-operator` | Ver y sincronizar plataforma y gobierno en los 5 clusters; acciones y logs | Crear o editar Applications; sincronizar `tuning`; `exec` |
| `app-developers` | `app-developer` | Sincronizar, accionar y ver logs en `apps-nonprod`; **ver** producción | Sincronizar producción (*deny* explícito), logs de producción, `exec` |
| `release-managers` | `release-manager` | Sincronizar y accionar `apps-prod`, con sus logs | Sincronizar dev y test, `exec` |
| `platform-viewers` | `auditor` | Ver aplicaciones, proyectos, clusters y repositorios | Sincronizar, **ver logs** (en producción pueden llevar datos de clientes), `exec` |
| cuenta local `pipeline` | — (política directa) | Sincronizar `apps-nonprod/*-dev` | Todo lo demás |

Dos decisiones que no son obvias:

**El `deny` es explícito, no implícito.** Con `defaultPolicy: ""` bastaría no
conceder, pero un `deny` gana siempre sobre cualquier `allow` posterior: si alguien
amplía un glob por error dentro de un año, producción sigue cerrada.

**La cuenta del CI recibe su política directamente, no a través de un rol.** Con
SSO activo, un grupo del proveedor que se llamara igual que el rol heredaría sus
permisos.

## Segregación de funciones

Quien desarrolla no despliega a producción; quien despliega no desarrolla. En Argo
lo imponen los roles; en Git, `CODEOWNERS`; y el AppProject impide que un
manifiesto de un ambiente aterrice en otro. Tres capas distintas para la misma
regla, que es lo que la hace demostrable ante una auditoría.

Comprobación reproducible:

```bash
argocd admin settings rbac can role:app-developer   sync applications apps-prod/app-demo-service-prod    # No
argocd admin settings rbac can role:release-manager sync applications apps-prod/app-demo-service-prod    # Yes
argocd admin settings rbac can role:release-manager sync applications apps-nonprod/app-demo-service-dev  # No
argocd admin settings rbac can role:auditor         get  logs         apps-prod/app-demo-service-prod    # No
```

## Qué sí está en Git, y qué no

| Pieza | Dónde | Por qué |
|---|---|---|
| Los objetos `Group` (vacíos) | `namespace-governance/.../identity/` | Un binding a un grupo inexistente se aplica sin error y no concede nada |
| La pertenencia (`users`) | En ningún sitio | Se da de alta a mano por cluster; versionarla crearía una segunda fuente de verdad |
| `RoleBinding` por namespace | `namespace-governance/` | Acceso acotado; Argo puede concederlo |
| `ClusterRoleBinding` del hub | `bootstrap/manifests/` | Conceder `cluster-admin` desde un commit sería una vía de escalada |
| Acceso a los spokes | `gitops/clusters/human-access/` (`ClusterPermission`) | Lo aplica el agente de ACM, fuera del alcance de Argo |
| El `OAuth` de cada cluster y su Secret htpasswd | `bootstrap/manifests/oauth-{hub,spoke}.reference.yaml` (referencia, no se aplica por GitOps) | El Secret con el hash es material sensible; el OAuth es plano de control |

Los manifiestos de `Group` **omiten el campo `users`**, no lo declaran vacío. La
diferencia no es cosmética: con `users: []` Argo se apropia del campo y cada
sincronización borra la pertenencia. Se comprobó en el cluster, y vació un grupo
real. Omitirlo hace que Argo nunca lo posea.

## Los spokes tienen su propia identidad

La autenticación es **por cluster**: cada uno resuelve los grupos contra sus
propios objetos `Group` y sus propios `ClusterRoleBinding`/`ClusterPermission`, y
el hub no los federa. Entrar en el hub no da acceso a un spoke — hay que dar de
alta a la persona con `oc adm groups add-users` en cada cluster donde necesite
entrar.

El acceso de lectura a los spokes lo reparte ACM con una `ClusterPermission` por
cluster (`cluster-reader` para `platform-operators` y `platform-viewers`,
`gitops/clusters/human-access/clusterpermission-platform-groups.yaml`). El
binding referencia el `Group` por nombre — funciona igual sin depender de si la
pertenencia se dio de alta a mano o llegó por claim.

### Las cuentas de emergencia (break-glass)

Con un único proveedor htpasswd, la cuenta habitual y la de emergencia son el
mismo mecanismo: no hay un segundo proveedor que añadir. Lo que distingue a las
de break-glass es que llevan `cluster-admin` y se reservan para cuando el resto
del acceso (grupos, roles) no está disponible o no basta.

| Pieza | Cómo llega | Por qué así |
|---|---|---|
| El Secret con el hash (todas las cuentas, nominales y break-glass) | Se crea a mano en el bootstrap, nunca en Git | Es un secreto |
| `cluster-admin` para las cuentas de break-glass | `oc adm policy add-cluster-role-to-user` (hub) / `ClusterPermission` de ACM (spokes) | Autenticar sin autorizar no sirve de nada en una emergencia |

**Ninguna cuenta se llama `admin`.** No aporta nada frente a un nombre nominal o
`breakglass1`/`breakglass2` en el audit log, y es el nombre que confunde con
`kubeadmin`/la consola por convención — evitarlo también evita que alguien
intente loguearse con credenciales de otro sistema pensando que es la misma
cuenta.

Su uso debería disparar una alerta: el audit log registra el usuario real en
cada acceso, así que una regla sobre los nombres de break-glass en el SIEM avisa
de cada uso de emergencia. Rotar las contraseñas tras cada uso.

## `exec` está denegado a propósito

El terminal web da los privilegios de la ServiceAccount del pod, y el audit log
registra a Argo, **no a la persona**. Para depurar está `oc rsh`, que sí queda
atribuido a quien lo ejecuta.

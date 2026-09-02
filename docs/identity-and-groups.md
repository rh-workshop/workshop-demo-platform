# Identidad: grupos, roles y quién ve qué

Cómo una persona pasa de iniciar sesión a tener permisos, y dónde se decide cada
paso. Complementa `governance-backlog.md`, que dice *qué falta*; esto dice *cómo
funciona lo que ya hay*.

## Dos modelos, según el cluster

El hub y los spokes autentican distinto, y no es una inconsistencia:

| | Hub | Spokes |
|---|---|---|
| Proveedor | **Solo htpasswd** | Keycloak (`rhbk`) |
| Pertenencia a grupos | `oc adm groups add-users` | Claim `groups` del OIDC |

**El hub despliega Keycloak, así que no puede depender de él para autenticar.**
Si lo hiciera, arreglar un Keycloak caído exigiría entrar al cluster, y entrar al
cluster exigiría Keycloak: el servidor OAuth devuelve 500 y no entra nadie,
tampoco quien va a repararlo. Por eso el hub tiene un único proveedor htpasswd,
que valida el propio API server contra un Secret local.

En los spokes no hay circularidad —su Keycloak no depende de ellos mismos— así
que sí usan OIDC, que es lo que permite gestionar la pertenencia en un solo
sitio.

## La cadena (spokes)

```
Keycloak (realm sso)          OpenShift                    Argo CD
  usuario ∈ grupo    ──►   Group sincronizado   ──►   rol según la política
```

1. **Keycloak** es la única fuente de la pertenencia. El cliente `idp-4-ocp` lleva
   un mapper `groups` con `full.path=false`, que emite nombres simples
   (`platform-admins`, no `/platform-admins`).
2. **OpenShift** recibe el claim porque el proveedor `rhbk` declara
   `claims.groups: [groups]`. Al iniciar sesión, el servidor OAuth **crea o
   actualiza** el `Group` con la anotación `oauth.openshift.io/generated: true`.
3. **Argo CD** resuelve el rol con `scopes: [groups]` y las líneas `g, <grupo>,
   role:<rol>` de `spec.rbac.policy`.

Consecuencia operativa que conviene tener presente: **la pertenencia se refresca
al iniciar sesión**. Sacar a alguien de un grupo en Keycloak no le retira el acceso
hasta su siguiente login.

### Dar de baja a una persona

Deshabilitarla en Keycloak **no basta**, y es el error más fácil de cometer:

- El token de OpenShift ya emitido **sigue siendo válido hasta que expire** (24 h
  por defecto). Keycloak solo interviene en el próximo inicio de sesión, que ya
  no ocurrirá.
- El usuario **permanece en `Group.users`** indefinidamente: el servidor OAuth
  solo retira a alguien de un grupo *durante un login exitoso* con menos claims.

El procedimiento correcto, **en cada cluster donde haya entrado** — el hub y los
spokes tienen bases de identidad independientes:

```bash
oc delete oauthaccesstoken --field-selector=userName=<usuario>   # corta las sesiones vivas
oc adm groups remove-users <grupo> <usuario>
oc delete identity rhbk:<sub> ; oc delete user <usuario>
```

Y deshabilitar la cuenta en Keycloak, que es lo que impide volver a entrar.

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

## Alta de una persona

1. Crearla en Keycloak (realm `sso`) y añadirla al grupo que le corresponda.
2. Que inicie sesión una vez en la consola de OpenShift.
3. Comprobar: `oc get group <grupo> -o jsonpath='{.users}'`.

No hay paso 4: **la pertenencia** no se declara en Git. Vive en el IdP a
propósito — versionarla crearía una segunda fuente de verdad y las bajas
llegarían tarde.

## Qué sí está en Git, y qué no

| Pieza | Dónde | Por qué |
|---|---|---|
| Los objetos `Group` (vacíos) | `namespace-governance/.../identity/` | Un binding a un grupo inexistente se aplica sin error y no concede nada |
| La pertenencia (`users`) | En ningún sitio | La escribe el servidor OAuth en cada login |
| `RoleBinding` por namespace | `namespace-governance/` | Acceso acotado; Argo puede concederlo |
| `ClusterRoleBinding` del hub | `bootstrap/manifests/` | Conceder `cluster-admin` desde un commit sería una vía de escalada |
| Acceso a los spokes | `gitops/clusters/human-access/` (`ClusterPermission`) | Lo aplica el agente de ACM, fuera del alcance de Argo |

Los manifiestos de `Group` **omiten el campo `users`**, no lo declaran vacío. La
diferencia no es cosmética: con `users: []` Argo se apropia del campo y cada
sincronización borra la pertenencia. Se comprobó en el cluster, y vació un grupo
real. Omitirlo hace que Argo nunca lo posea.

## Los spokes tienen su propia identidad

La autenticación es **por cluster**: cada uno resuelve los grupos contra sus
propios objetos y sus propios bindings, y el hub no los federa. Entrar en el hub
no da acceso a un spoke.

El acceso de lectura a los spokes lo reparte ACM con una `ClusterPermission` por
cluster (`cluster-reader` para `platform-operators` y `platform-viewers`). Los
`Group` no hacen falta allí: los crea el servidor OAuth del spoke en el primer
login.

Para eso el OAuth de cada spoke debe pedir el claim `groups`. Lo garantiza la
Policy `require-oidc-groups-claim`, en modo **`enforce`**: si falta, ACM lo añade.

La Policy no escribe un `OAuth` fijo. El proveedor `rhbk` lleva un `issuer` y un
`clientSecret` **distintos en cada cluster**, y una plantilla con valores fijos
los reescribiría con los de otro, dejándolo sin acceso por Keycloak. En su lugar
usa `object-templates-raw` con `lookup`: lee el proveedor del propio cluster y lo
reinyecta tal cual, aportando únicamente el claim. Verificado en los cuatro
spokes — cada uno conservó su issuer.

### El break-glass de los spokes

Cada spoke tiene **dos** proveedores: `rhbk` para el día a día y `break-glass`
(htpasswd) para cuando Keycloak no responde. Sin el segundo, un Keycloak caído
deja el cluster sin forma de entrar a repararlo.

Son tres piezas, y ninguna sirve sin las otras dos:

| Pieza | Cómo llega | Por qué así |
|---|---|---|
| El Secret con el hash | `ManifestWork` por cluster | Es un secreto: no puede vivir en Git |
| El proveedor en el `OAuth` | Policy `require-break-glass-idp` | No lleva material sensible, solo el nombre del Secret |
| `cluster-admin` para la cuenta | `ClusterPermission` de ACM | Autenticar sin autorizar no sirve de nada en una emergencia |

La Policy usa `musthave` sobre la lista de `identityProviders`: **añade** el
proveedor sin tocar `rhbk`. Verificado en los cuatro — cada uno conserva su
issuer y su claim `groups`.

**La cuenta se llama `breakglass1`, no `admin`.** Con `mappingMethod: claim`,
OpenShift rechaza que dos identidades reclamen el mismo usuario: si ya existe un
`admin` que entró por Keycloak, el login htpasswd falla con
`cannot be claimed by identity ... already mapped to [rhbk:...]` y un HTTP 500.
El nombre debe ser exclusivo de este proveedor.

Probado de extremo a extremo: login correcto en los cuatro spokes, `whoami`
devuelve `breakglass1` y `auth can-i '*' '*'` responde `yes`.

## Acceso de emergencia

Si Keycloak no responde, el servidor OAuth devuelve 500 y **nadie entra**, ni para
arreglarlo. Por eso existe el proveedor `break-glass` (htpasswd, dos cuentas),
independiente de cualquier servicio externo. Procedimiento y custodia en
`bootstrap/manifests/oauth-break-glass.reference.yaml`.

Su uso debería disparar una alerta: el audit log registra `breakglass1` como
usuario, así que una regla sobre ese nombre en el SIEM avisa de cada acceso.

## `exec` está denegado a propósito

El terminal web da los privilegios de la ServiceAccount del pod, y el audit log
registra a Argo, **no a la persona**. Para depurar está `oc rsh`, que sí queda
atribuido a quien lo ejecuta.

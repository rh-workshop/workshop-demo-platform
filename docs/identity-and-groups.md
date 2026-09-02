# Identidad: grupos, roles y quién ve qué

Cómo una persona pasa de iniciar sesión a tener permisos, y dónde se decide cada
paso. Complementa `governance-backlog.md`, que dice *qué falta*; esto dice *cómo
funciona lo que ya hay*.

## La cadena

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

Para eso el OAuth de cada spoke debe pedir el claim `groups`, cosa que hoy **no
hace** — lo vigila la Policy `require-oidc-groups-claim`, que los reporta
`NonCompliant`. Va en modo `inform` a propósito: el proveedor `rhbk` referencia
un `clientSecret` distinto en cada cluster, y una Policy en `enforce` sobre el
objeto `OAuth` completo lo reescribiría dejando el cluster sin acceso por
Keycloak. Se corrige con un patch por cluster, documentado en la Policy.

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

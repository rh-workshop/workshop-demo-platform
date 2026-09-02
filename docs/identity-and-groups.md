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
hasta su siguiente login. Para una baja, deshabilitar el usuario en Keycloak —
eso sí corta el flujo OAuth de inmediato.

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

No hay paso 4: no se declara nada en Git. La pertenencia vive en el IdP a
propósito — versionarla crearía una segunda fuente de verdad y las bajas llegarían
tarde.

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

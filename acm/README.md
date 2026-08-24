# acm — hub de gobierno multi-cluster

Esta carpeta guarda la configuración de Red Hat Advanced Cluster Management: el
hub (`MultiClusterHub`) y las políticas de gobierno (`Policy` +
`Placement` + `PlacementBinding`).

## Se despliega por app-of-apps, como el resto

La configuración de ACM se sincroniza con Argo CD igual que los demás productos:
tiene su Application en `gitops/apps/children/acm-application.yaml` y se despliega
sola al aplicar la raíz.

> **Nota sobre versiones.** En combinaciones antiguas de ACM/MCE con OpenShift
> GitOps, el motor de MCE rompía el caché de esquema OpenAPI de Argo y las
> Applications que apuntaban a recursos de ACM se quedaban en estado `Unknown`.
> **Con ACM 2.17 / MCE 2.17.1 ese problema está resuelto:** Argo descubre y
> reconcilia `MultiClusterHub`, `Policy`, `Placement` y `PlacementBinding` sin
> error de esquema. Verificado en vivo — la Application queda `Healthy` y compara
> los recursos correctamente. Si se trabaja sobre una versión anterior donde el
> problema persista, esta carpeta se puede aplicar directo con
> `oc apply -k acm/gitops/overlays/dev` en lugar de por app-of-apps.

## Qué contiene

| Recurso | Qué hace |
|---|---|
| `MultiClusterHub` | Enciende el hub de ACM (gestión de clústeres, gobierno, observabilidad) |
| `Policy` | La regla de gobierno: exige que exista una `ResourceQuota` en el namespace |
| `Placement` | A qué clústeres gestionados aplica la política (`environment=prod`) |
| `PlacementBinding` | Une la `Policy` con el `Placement` |

Todo es declarativo: las políticas de ACM **sí** son CRs (a diferencia de las de
ACS, que van por API). Aquí Ansible no hace falta.

# acm — hub de gobierno multi-cluster

Esta carpeta guarda la configuración de Red Hat Advanced Cluster Management: el
hub (`MultiClusterHub`) y las políticas de gobierno (`Policy` + `Placement` +
`PlacementBinding`).

## Se despliega por app-of-apps, como producto hub

ACM vive solo en el cluster hub, así que su Application está en
`gitops/apps/hub/acm-application.yaml` y apunta a `in-cluster`. No forma parte del
fan-out por ApplicationSet (eso es para los productos workload que van a spokes).

Verificado en vivo sobre **ACM 2.17 / MCE 2.17.1 + OpenShift GitOps 1.21.3**: Argo
descubre y reconcilia `MultiClusterHub`, `Policy`, `Placement` y `PlacementBinding`
sin error de esquema OpenAPI. (En combinaciones antiguas de ACM/MCE con GitOps
existía un bug que dejaba estas Applications en `Unknown`; en estas versiones está
resuelto.)

## Qué contiene

| Recurso | Qué hace |
|---|---|
| `MultiClusterHub` | Enciende el hub de ACM (gestión de clusters, gobierno, observabilidad) |
| `Policy` | La regla de gobierno: exige que exista una `ResourceQuota` en el namespace |
| `Placement` | A qué clusters gestionados aplica la política (`environment=prod`) |
| `PlacementBinding` | Une la `Policy` con el `Placement` |

Las políticas de ACM **sí** son CRs (a diferencia de las de ACS, que van por API):
aquí Ansible no hace falta.

> **Placement y ManagedClusterSetBinding.** Un `Placement` solo ve los clusters de
> los cluster sets *vinculados a su namespace*. La cadena GitOps del repo ya crea
> el `ManagedClusterSetBinding` en `openshift-gitops` (ver `gitops/clusters/`); si
> se aplican estas políticas en otro namespace, hay que asegurar el binding
> correspondiente o el Placement no seleccionará ningún cluster.

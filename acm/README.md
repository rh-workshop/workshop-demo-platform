# acm — hub de gobierno multi-cluster

Esta carpeta guarda la configuración de Red Hat Advanced Cluster Management: el
hub (`MultiClusterHub`) y las políticas de gobierno (`Policy` +
`Placement` + `PlacementBinding`).

## Por qué ACM no tiene una Application en el app-of-apps

A diferencia del resto de productos, la configuración de ACM **no se sincroniza
con Argo CD cuando el hub y Argo conviven en el mismo clúster**. El motor de MCE
(multicluster-engine) rompe el caché de esquema OpenAPI que Argo usa para
descubrir recursos, y las Applications que apuntan a recursos de ACM se quedan en
estado `Unknown` — ni sanas ni con error, sencillamente sin poder reconciliar.

Por eso los manifiestos de esta carpeta se aplican **directo**, no por app-of-apps:

```bash
oc apply -k acm/gitops/overlays/dev
```

El `MultiClusterHub` es un objeto de control del hub, hub-local, y las políticas
las evalúa el propio motor de gobierno de ACM sobre los clústeres gestionados —
no necesitan que Argo las empuje.

## Qué contiene

| Recurso | Qué hace |
|---|---|
| `MultiClusterHub` | Enciende el hub de ACM (gestión de clústeres, gobierno, observabilidad) |
| `Policy` | La regla de gobierno: exige que exista una `ResourceQuota` en el namespace |
| `Placement` | A qué clústeres gestionados aplica la política (`environment=prod`) |
| `PlacementBinding` | Une la `Policy` con el `Placement` |

Todo es declarativo: las políticas de ACM **sí** son CRs (a diferencia de las de
ACS, que van por API). Aquí Ansible no hace falta.

# acm — hub de gobierno multi-cluster

Esta carpeta guarda la configuración de Red Hat Advanced Cluster Management: el
hub (`MultiClusterHub`) y las políticas de gobierno (`Policy` + `Placement` +
`PlacementBinding`).

## Se despliega por app-of-apps, como producto hub

ACM vive solo en el cluster hub, así que su Application está en
`gitops/apps-governance/application-acm.yaml` y apunta a `in-cluster`. La
sincroniza la instancia de GOBIERNO (`gitops-governance`), no la de cargas: las
Policies de ACM son un canal de ejecución remota en toda la flota y solo esa
instancia tiene permiso para escribirlas. No forma parte del
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
| `Policy` | La regla de gobierno (instalar operadores, exigir `ResourceQuota`…) |
| `Placement` | A qué clusters gestionados aplica cada política |
| `PlacementBinding` | Une cada `Policy` con su `Placement` |

## Estructura: placements centralizados

```
gitops/base/
├── placements/            # los Placement, COMPARTIDOS entre políticas
│   ├── placement-clusters-hub.yaml       # role=hub (el cluster de management)
│   └── placement-clusters-workload.yaml  # environment in [dev, prod]
└── policies/              # una carpeta por política
    └── <política>/
        ├── policy.yaml           # la política (o <ámbito>-policy.yaml si tiene varias)
        └── placementbinding.yaml # a qué Placement se dirige
```

Los `Placement` van en un directorio propio y NO dentro de la carpeta de una
política: un mismo Placement puede dirigir varias políticas (varios
`PlacementBinding`, o un `PolicySet`), así que anidarlo bajo una de ellas sería
engañoso. Es la convención del
[policy-collection](https://github.com/open-cluster-management-io/policy-collection)
upstream: las contribuciones ya no incluyen el placement, porque "placement
resources can be shared to avoid duplication".

Convenciones de nombre:

- **Placement → por criterio de selección** (`clusters-hub`, `clusters-workload`),
  igual que los `clusters-*` de `gitops/clusters/`: el nombre responde "¿qué
  clusters selecciona?", no "¿quién lo usa?". Así `clusters-hub` lo comparten
  hoy la política de operadores del hub y `require-resourcequota` sin que el
  nombre mienta.
- **PlacementBinding → por la política que une** (`<política>-binding`): cada
  binding pertenece a exactamente una Policy/PolicySet (sus `subjects`),
  mientras que un Placement puede tener muchos bindings. El binding es "el
  enchufe de la política", no del placement.

> **¿Por qué NO se unifican con los Placement de `gitops/clusters/`?** Aquellos
> (`clusters-all/dev/prod`) viven en `openshift-gitops` porque los consumen el
> `GitOpsCluster` y el generador `clusterDecisionResource` de los
> ApplicationSets, que leen las `PlacementDecision` en el namespace de Argo. Los
> de aquí viven en `open-cluster-management` porque `Policy`, `Placement` y
> `PlacementBinding` deben compartir namespace (regla del framework de
> gobierno). Son dos consumidores distintos con requisitos de namespace
> incompatibles: la separación es correcta, no una duplicación.

Las políticas de ACM **sí** son CRs (a diferencia de las de ACS, que van por API):
aquí Ansible no hace falta.

> **Placement y ManagedClusterSetBinding.** Un `Placement` solo ve los clusters de
> los cluster sets *vinculados a su namespace*. La cadena GitOps del repo ya crea
> el `ManagedClusterSetBinding` en `openshift-gitops` (ver `gitops/clusters/`); si
> se aplican estas políticas en otro namespace, hay que asegurar el binding
> correspondiente o el Placement no seleccionará ningún cluster.

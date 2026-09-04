# openbao-store — el puente con External Secrets, en cada cluster

Distinto de [`openbao/`](../openbao/README.md): aquel es el almacén en sí
(existe **una** vez, en el hub); esto es lo que **conecta** cada cluster (hub y
los 4 spokes) a ese almacén. Se despliega en todos, con su propio
`ClusterSecretStore` local — sin él, los `ExternalSecret` de ese cluster no
tienen contra qué resolver.

## Qué despliega, en orden

1. **`externalsecretsconfig.yaml`** (`ExternalSecretsConfig cluster`) — el
   controlador de ESO en sí. La `OperatorPolicy` de ACM solo instala el
   operador; sin este CR, los `ClusterSecretStore`/`ExternalSecret` se crean
   pero nadie los atiende y quedan sin estado — el síntoma que más despista al
   diagnosticar.
2. **`networkpolicy-eso-egress.yaml`** — el operador de ESO niega **todo** su
   egress por defecto; sin esta excepción, el controlador nunca alcanza el
   almacén, aunque el store esté bien configurado.
3. **`clustersecretstore.yaml`** — apunta al almacén: `server` (Service
   interno en el hub, Route pública desde un spoke — lo resuelve cada
   overlay) y el token de autenticación (`eso-read-<ambiente>` o
   `eso-read-hub`, nunca el token raíz).

## `conditions.namespaces` — la lista es deliberada, no un descuido

```yaml
conditions:
  - namespaces:
      - keycloak
      - kafka
      - open-cluster-management
      - open-cluster-management-observability
      - quay-enterprise
```

Sin esta lista, cualquier `ExternalSecret` de cualquier namespace del cluster
podría materializar cualquier ruta que el token `eso-read` alcance — un
namespace de negocio podría traerse `platform/keycloak/db-prod`. **Añadir un
namespace aquí es una decisión de plataforma**, no algo que decida quien
despliega una aplicación. Al dar de alta un `ExternalSecret` nuevo en un
namespace que no está en la lista, el error es
`"using cluster store ... is not allowed from namespace ...: denied by spec.condition"`
— y hay que editar este fichero, en el overlay que corresponda.

## Cómo verificar que un cluster está bien conectado

```bash
oc get clustersecretstore platform-vault -o jsonpath='{.status.conditions}'
# Ready=True, "store validated"

oc get externalsecret -A
# STATUS debe ser SecretSynced en todas
```

Si un `ExternalSecret` queda `SecretSyncedError`, el mensaje distingue la
causa:

| Mensaje | Causa | Dónde mirar |
|---|---|---|
| `denied by spec.condition` | El namespace no está en `conditions.namespaces` | Este componente, overlay del cluster |
| `permission denied` (403 de Vault) | El token `eso-read-*` no tiene la ruta en su policy | `openbao/ansible/bootstrap.yml`, bloque `bao policy write eso-read-*` |
| `Secret does not exist` | La ruta nunca se sembró en el almacén, o se perdió en una reinicialización | El playbook del producto correspondiente (ver [`openbao/README.md`](../openbao/README.md#recuperación-completa-pérdida-de-los-tres-pvc)) |

## Un overlay por cluster, no un manifiesto compartido

Cada cluster (`overlays/{hub,dev,test,prod,contingencia}`) parchea el mismo
`base/`, cambiando solo `server` (endpoint del almacén) y el nombre del
`Secret` con el token — nunca la lógica del store en sí. Ver el comentario de
cabecera de `gitops/base/clustersecretstore.yaml` para el detalle de qué
cambia entre el hub y un cluster de carga.

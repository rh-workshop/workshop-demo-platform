# OpenBao — operación del almacén de secretos

Almacén único de la plataforma, en el hub: 3 réplicas, almacenamiento Raft (un
PVC por réplica), TLS de cert-manager y arranque **sellado**. Lo despliega Argo
(`config-openbao`, `openbao/gitops/overlays/hub`); lo inicializa y le emite los
tokens el playbook `openbao/ansible/bootstrap.yml`.

## Qué es normal y qué no

| Situación | Estado esperado |
|---|---|
| Tras un reinicio de pod, nodo o clúster | La réplica arranca **sellada**. Los datos siguen en su PVC. Hay que desellarla. |
| Argo sincroniza un cambio de la plantilla del StatefulSet | **Ningún pod se reinicia** (`updateStrategy: OnDelete`). El operador aplica el cambio pod a pod cuando decide. |
| Una réplica sellada | Sigue siendo `Ready` (readiness con `sealedcode=204`) para que Argo vea el StatefulSet sano; la etiqueta `openbao-sealed=true` del pod delata el estado. |
| Dos réplicas selladas de tres | El clúster Raft **pierde quórum**: no sirve secretos hasta desellar al menos una más. |

Comprobación rápida:

```bash
oc get pods -n openbao -L openbao-active,openbao-sealed,openbao-initialized
```

## Desellar tras un reinicio

Hacen falta **3 de las 5** claves de Shamir, de custodios distintos. Cada
réplica sellada se desella por separado; el comando se repite una vez por clave
y la pide de forma interactiva (no queda en el historial de la shell):

```bash
for pod in openbao-0 openbao-1 openbao-2; do
  oc exec -n openbao -it "$pod" -- sh -c \
    'BAO_ADDR=https://127.0.0.1:8200 BAO_CACERT=/openbao/tls/ca.crt bao operator unseal'
done   # repetir el bucle con la 2.ª y la 3.ª clave
```

Verificación:

```bash
oc exec -n openbao openbao-0 -- sh -c \
  'BAO_ADDR=https://127.0.0.1:8200 BAO_CACERT=/openbao/tls/ca.crt bao status'
# Sealed=false, HA Enabled=true, Storage Type=raft

oc exec -n openbao openbao-0 -- sh -c \
  'BAO_ADDR=https://127.0.0.1:8200 BAO_CACERT=/openbao/tls/ca.crt BAO_TOKEN=<token-operador> \
   bao operator raft list-peers'
# 3 nodos, 1 leader + 2 follower, los tres Voter=true (autopilot promociona
# un nodo nuevo tras 10 s sano; no requiere acción)
```

Los ExternalSecret se recuperan solos en su siguiente refresco (`1h`); para
forzarlo: `oc annotate externalsecret -A --all force-sync=$(date +%s) --overwrite`.

**Nunca** guardar las claves de desello ni el token raíz en un Secret, un
ConfigMap ni en Git: anularía el sellado. En un entorno productivo la
alternativa correcta es el **auto-unseal con un KMS externo** (`seal "azurekeyvault"`
o `seal "awskms"`): la clave maestra queda cifrada por el KMS y el proceso se
desella solo sin que la clave viva en el clúster. Migración: añadir el bloque
`seal` a la config y ejecutar `bao operator unseal -migrate` con las claves de
Shamir, que pasan a ser claves de recuperación.

## Cambiar la plantilla del StatefulSet (imagen, probes, recursos)

Argo aplica el cambio pero, por `OnDelete`, no reinicia nada. El operador lo
despliega réplica a réplica, **primero las standby y la activa al final**:

```bash
oc get pods -n openbao -L openbao-active          # identificar la activa
oc delete pod -n openbao openbao-2                # una standby
# esperar Running, desellar (3 claves), comprobar que vuelve como follower
# repetir con la otra standby; la activa en último lugar (cede el liderazgo)
```

## Cambiar un campo inmutable (`serviceName`, `volumeClaimTemplates`, `podManagementPolicy`)

Paso manual y único; los pods y los PVC se conservan y el StatefulSet nuevo los
adopta:

```bash
oc delete statefulset openbao -n openbao --cascade=orphan
# Argo recrea el StatefulSet en el siguiente sync (o `argocd app sync config-openbao`)
```

## Recuperación completa (pérdida de los tres PVC)

Solo en ese caso hay que volver a inicializar (`bootstrap.yml`), desellar y
recargar los secretos con los playbooks de cada producto (Quay, ACM
observability, Keycloak, Kafka). Antes de cualquier operación de riesgo,
snapshot de Raft:

```bash
oc exec -n openbao openbao-0 -- sh -c \
  'BAO_ADDR=https://127.0.0.1:8200 BAO_CACERT=/openbao/tls/ca.crt BAO_TOKEN=<token-operador> \
   bao operator raft snapshot save /tmp/raft.snap' && \
oc cp openbao/openbao-0:/tmp/raft.snap ./raft-$(date +%Y%m%d).snap
```

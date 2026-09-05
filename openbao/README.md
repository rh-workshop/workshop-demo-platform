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

## El modelo de tokens: NO hay ninguno persistente de escritura

Solo dos tipos de token existen en el diseño actual:

| Token | Alcance | Dónde vive |
|---|---|---|
| `eso-read-<ambiente>` / `eso-read-hub` | Solo lectura, acotado por policy a las rutas de ese ambiente | `Secret openbao-eso-token(-hub)` en `openbao`, o replicado a cada spoke por la Policy `require-vault-token` de ACM |
| Raíz / operador (`BAO_OPERATOR_TOKEN`) | Total, incluida escritura | **Nunca se guarda en el clúster.** Lo aporta quien ejecuta el playbook, por variable de entorno, y se revoca tras el arranque |

**Cualquier playbook que escriba en el almacén (`bao kv put`) necesita
`BAO_OPERATOR_TOKEN`** — los tokens `eso-read-*` no alcanzan, son de solo
lectura a propósito. Si un playbook de producto falla con `permission denied`
al depositar un secreto, la causa casi siempre es que le falta esa variable, no
que el token esté mal configurado.

Si en algún fichero aparece una referencia a `openbao-dev-token`: es un
**nombre legado**. Este playbook (la versión actual, mantenida) ya no lo crea
ni lo usa en ningún punto — si algún playbook de producto todavía lo
referencia, está desalineado y hay que corregirlo al patrón de arriba.

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
recargar los secretos con los playbooks de cada producto:

```bash
export BAO_OPERATOR_TOKEN='<token raíz emitido en el init>'
ansible-playbook quay/ansible/config-bundle-vault.yml   # config.yaml de Quay
ansible-playbook quay/ansible/pull-secrets.yml          # credenciales de origen del registro
ansible-playbook kafka/ansible/encryption-keys.yml       # llaves de cifrado por ambiente
ansible-playbook acm/ansible/observability.yml          # conexión S3 de Thanos
```

**Reinicializar borra `secret/` por completo, incluida la credencial de
PostgreSQL de Keycloak** (`platform/keycloak/db-<ambiente>`) — ningún playbook
la siembra: se creó a mano en algún punto anterior a este repo. Si el
`ExternalSecret keycloak-pgsql-user` de un cluster queda `SecretSyncedError`
tras la reinicialización, el `Secret` ya materializado conserva el último
valor bueno (ESO no lo borra al fallar el refresco) — se recupera de ahí:

```bash
DB_PASS=$(oc get secret keycloak-pgsql-user -n keycloak -o jsonpath='{.data.password}' | base64 -d)
oc exec -n openbao openbao-0 -- env BAO_TOKEN="$BAO_OPERATOR_TOKEN" BAO_ADDR=https://127.0.0.1:8200 BAO_CACERT=/openbao/tls/ca.crt sh -c \
  "bao kv put -mount=secret platform/keycloak/db-<ambiente> user=keycloak password=$DB_PASS dbname=keycloak"
```

**Mismo gap con `platform/acs/smtp`** (credencial SMTP del reporte de
vulnerabilidades de ACS, ver [`acs/README.md`](../acs/README.md)): tampoco
la siembra ningún playbook — solo `bao kv put` manual. A diferencia de
Keycloak, aquí no hay un `Secret` materializado del que recuperar el valor
(el `ExternalSecret acs-smtp` queda `SecretSyncedError` hasta resembrarla a
mano con la credencial real).

**`bao operator init` NO habilita ningún motor de secretos.** Solo trae
`cubbyhole`, `identity` y `sys` — nada en `secret/`. `bootstrap.yml` ya
incluye el paso (`bao secrets enable -path=secret -version=2 kv`,
idempotente), pero si se ejecuta algún `bao kv put` a mano contra un vault
recién inicializado y sin pasar antes por el playbook, falla con
`preflight capability check returned 403` — no es un problema de permisos del
token, es que el `mount` ni existe todavía.

Antes de cualquier operación de riesgo, snapshot de Raft:

```bash
oc exec -n openbao openbao-0 -- sh -c \
  'BAO_ADDR=https://127.0.0.1:8200 BAO_CACERT=/openbao/tls/ca.crt BAO_TOKEN=<token-operador> \
   bao operator raft snapshot save /tmp/raft.snap' && \
oc cp openbao/openbao-0:/tmp/raft.snap ./raft-$(date +%Y%m%d).snap
```

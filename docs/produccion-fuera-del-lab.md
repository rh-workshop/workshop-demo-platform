# Buenas prácticas de producción NO aplicables en el laboratorio

Estos cambios **no se pueden hacer en el entorno de práctica** (requieren
infraestructura externa: bases de datos gestionadas, almacenamiento S3, red BGP,
CA corporativa, gestor de secretos). Se documentan aquí y se marcan como
`NO-PRODUCCION` en el manifiesto correspondiente, con el fix que tocaría en un
cliente real.

---

## 1. Bases de datos gestionadas y externas

**Afecta:** Keycloak, Quay, ACS (Central), Developer Hub.

En el lab, cada producto usa la base de datos que despliega su operador (un pod,
sin HA, sin backup). En producción esto es inaceptable: el estado crítico (usuarios,
imágenes, políticas, catálogo) no puede vivir en un pod efímero.

**En un cliente:** PostgreSQL gestionado y con HA — Azure Database for PostgreSQL
(Flexible Server, zona redundante) o RDS Multi-AZ. Cada producto apunta a él:
- Keycloak: `spec.db.host` externo + `spec.db.usernameSecret`/`passwordSecret`
- Quay: `postgres: managed: false` + `DB_URI` en el config bundle
- ACS: `central.db.connectionString` + `passwordSecret`
- Developer Hub: `spec.database.enableLocalDb: false` + `POSTGRES_*` por Secret

Las credenciales **siempre** vía External Secrets Operator desde Azure Key Vault,
nunca en Git.

## 2. Almacenamiento de objetos S3 real (Quay)

En el lab, el almacenamiento de imágenes va por NooBaa/MCG, que Red Hat documenta
como de **disponibilidad limitada**. En producción: S3 real — RADOS Gateway (ODF
completo con suscripción), Azure Blob Storage, o un S3 gestionado —, configurado
como `objectstorage: managed: false` + `DISTRIBUTED_STORAGE_CONFIG`.

## 3. MetalLB en modo BGP (no L2)

El lab usa L2/ARP: un solo nodo responde cada IP virtual, es cuello de botella y
el failover depende de que los clientes refresquen la caché ARP (segundos de
corte). En producción: **BGP con BFD** — ECMP real entre nodos y detección de
fallo sub-segundo. Requiere acuerdo con la red del cliente (ASN, peering). Se
añaden `BGPPeer`, `BFDProfile` y `BGPAdvertisement`.

## 4. Certificados de CA corporativa (no autofirmados)

**Afecta:** Keycloak, Quay, Connectivity Link (Gateway), cert-manager.

En el lab, los certificados son autofirmados o del wildcard del clúster — nadie
los valida sin distribuir la CA. En producción: certificado de la **CA corporativa
del cliente** o ACME (Let's Encrypt) con el dominio de negocio, emitido por
cert-manager y sincronizado como Secret desde Key Vault. El `certificateRefs` del
Gateway y el `tlsSecret` de cada producto apuntan a ese Secret.

## 5. Firma de imágenes con clave en Key Vault (Tekton Chains)

En el lab, la clave de firma cosign se genera ad-hoc con
`cosign generate-key-pair` en el clúster. En producción: la clave privada vive en
**Azure Key Vault**, se sincroniza al secret `signing-secrets` por ESO, y se firma
en formato clásico `.sig` (cosign v3 firma DSSE por defecto y ACS 4.x no lo
descubre). Además, un log de transparencia **Rekor** interno.

## 6. Persistencia de rate limiting con Redis (Connectivity Link)

En el lab, Limitador cuenta en memoria: los contadores se pierden en cada
reinicio y no se comparten entre réplicas ni entre sitios. En producción: **Redis**
(gestionado o en clúster con HA), configurado en el CR Limitador con
`storage.redis.configSecretRef`, con la URL vía ESO.

## 7. DNSPolicy para conmutación de sitios (DR)

En el lab (un solo clúster) el wildcard del router basta. En producción con DR: una
`DNSPolicy` con el proveedor DNS del cliente publica y conmuta el endpoint del
Gateway con health checks, alineado al modelo de continuidad (re-sincronizar la
config declarativa en el sitio que se active).

## 8. Autenticación federada real

**Afecta:** Developer Hub (OIDC), Quay/ACS (auth provider corporativo).

En el lab, el acceso es abierto o con admin local. En producción: OIDC contra el
Keycloak de la plataforma (o Entra ID), con los secretos de cliente en Key Vault.
En Developer Hub además el plugin de ingesta de usuarios/grupos del realm.

---

**Resumen:** todo lo anterior comparte un patrón — en el lab se usa el recurso que
el operador despliega por defecto (DB, storage, cert, red); en producción se
sustituye por infraestructura externa gestionada y con HA, y los secretos van
siempre por External Secrets Operator desde Azure Key Vault. La **estructura del
repo no cambia**: se parchea el valor en el overlay del ambiente y se referencia el
Secret por nombre.

# Backlog de endurecimiento a producción

Revisión producto por producto (6 informes, ~65 hallazgos) contra la documentación
oficial de Red Hat y el clúster real. **Este material no es un workshop: es la
plantilla que se copia tal cual a un cliente productivo de banca.** Sin `userXX`,
sin criterio de "aceptable porque es lab" — este documento registra qué falta
para que cada producto cumpla el estándar de producción, no una degradación
intencional que se acepta.

**Leyenda de estado:**
- ✅ **Aplicado** — corregido en el repo (declarativo, factible en el lab)
- 🔧 **Pendiente (Grupo A)** — fix declarativo aplicable en el lab, aún no hecho
- 📋 **Grupo B** — buena práctica de producción **NO factible en el lab** (requiere
  infra externa: DB gestionada, S3, BGP, CA corporativa, Key Vault). Documentado
  como NO-producción en el manifiesto correspondiente.

**Severidad:** 🔴 ALTA · 🟠 MEDIA · 🟡 BAJA

---

## Decisiones de arquitectura tomadas

- **Escaneo de vulnerabilidades (Clair vs ACS).** Clair (en Quay) y ACS comparten
  motor (ClairCore) pero cubren fases distintas: Clair escanea la imagen **en el
  registro** (gate al push, shift-left); ACS escanea **en el clúster** (admisión +
  runtime) y cubre mucho más que CVEs. No se duplican — se integran. **Decisión:
  Clair ON en Quay + integración ACS→Quay** (robot account, tipo `Scanner + Registry`)
  para que ACS surja los resultados de Quay en un solo panel sin re-escanear. Es
  defensa en profundidad, la postura que Red Hat posiciona para banca.

---

## Bugs introducidos y corregidos

| Producto | Bug | Estado |
|---|---|---|
| Service Mesh | El chart crea `IstioCNI` pero no el namespace `istio-cni` → no arregla el `IstioCNINotFound` | ✅ |
| ACS | El playbook parte de premisa falsa ("no hay CRD"); existe `SecurityPolicy` (Policy-as-Code) | ✅ |
| ACM | Placement `clusters-prod` con set `global` sin binding; OperatorPolicy sin version pinning | ✅ |
| OpenBao | `bao operator init` no habilita ningún motor KV — `bootstrap.yml` asumía `secret/` ya existente de una instalación anterior; 4 playbooks de producto apuntaban a `openbao-dev-token`, un nombre que el bootstrap actual ya no crea (solo emite tokens `eso-read-*`, de solo lectura) | ✅ |
| Quay | `quay-config-bundle` era un `Secret` imperativo de una sola vez, sin ruta de actualización declarativa — cualquier cambio de `config.yaml` (como el hallazgo #15 de abajo) exigía `oc create secret` a mano | ✅ |

---

## Keycloak (RHBK 26)

| # | Sev | Hallazgo | Grupo | Estado |
|---|---|---|---|---|
| A1 | 🔴 | `instances: 1` en prod → mínimo 2 (HA) | A | ✅ |
| A2 | 🔴 | Falta PodDisruptionBudget | A | ✅ |
| A3 | 🔴 | DB en-cluster (marcada NO-PRODUCCION; DB externa en prod) | B | 📋 |
| A4 | 🔴 | `hostname.strict: false` en prod (host spoofing) | A | ✅ |
| A5 | 🔴 | Drift `xaEnabled` vs `enable-recovery` → Argo lo rompería | A | ✅ |
| A6 | 🔴 | Route + Service del SSO fuera de Git | A | ✅ |
| M1 | 🟠 | Sin `spec.resources` (sin CPU request) | A | ✅ |
| M2 | 🟠 | Métricas/ServiceMonitor apagados (`metrics-enabled`) | A | ✅ |
| M3 | 🟠 | TLS = service-CA, no cert corporativo | B | 📋 |
| M4 | 🟠 | Realm workshop versionado (KeycloakRealmImport); clients por playbook | A | ✅ |
| M5 | 🟠 | Sin backups de DB | B | 📋 |

## Quay 3.17

| # | Sev | Hallazgo | Grupo | Estado |
|---|---|---|---|---|
| 1 | 🔴 | Clair ON + clairpostgres (integración ACS→Quay) | A | ✅ |
| 2 | 🔴 | Postgres managed marcado NO-PRODUCCION (DB externa en prod) | B | 📋 |
| 3 | 🔴 | Object storage NooBaa marcado NO-PRODUCCION (S3 en prod) | B | 📋 |
| 8 | 🔴 | SUPER_USERS documentado en governance.yml (config bundle por ESO) | A | ✅ |
| 10 | 🔴 | `validate_certs` default true (env override) | A | ✅ |
| 4 | 🟠 | HPA managed: true | A | ✅ |
| 5 | 🟠 | Monitoring: nota (requiere operador all-namespaces) | A | ✅ |
| 6 | 🟠 | TLS wildcard marcado NO-PRODUCCION (cert corporativo en prod) | B | 📋 |
| 11 | 🟠 | Bug permisos robot: fix subelements+include (todos los repos) | A | ✅ |
| 12 | 🟠 | `400=éxito`: limitación documentada + cómo endurecer | A | ✅ |
| 9,13,14 | 🟡 | quota+auto-prune por org (governance.yml); typo corregido | A | ✅ |
| 15 | 🔴 | Escribir cuotas devolvía 403 con CUALQUIER superusuario — no era bug de la consola | A | ✅ |

### #15 — Parecía bug de la UI. Era una feature flag que faltaba (2026-09-04)

**Síntoma:** logueado como `quayadmin` (superusuario confirmado, badge visible),
cualquier intento de cambiar una cuota desde `Organizations → ⚙️ → Configure
Quota → Apply` fallaba con `quota update error, Unauthorized`. Se sospechó
sesión rota, contraseña vieja, o bug de la consola.

**No era ninguna de las tres.** Reproducido en vivo con Playwright, la llamada
real es `PUT /api/v1/organization/<org>/quota/<id>` → `403`,
`error_type: insufficient_scope`. Rastreado hasta el código fuente de Quay
(`endpoints/api/namespacequota.py`, clase `OrganizationQuota.put`):

```python
@require_scope(scopes.SUPERUSER)
def put(self, orgname, quota_id):
    if not allow_if_superuser_with_full_access():
        raise Unauthorized()
```

`allow_if_superuser_with_full_access()` depende del feature flag
`FEATURE_SUPERUSERS_FULL_ACCESS`, cuyo default en `config.py` es **`False`**.
`SUPER_USERS: [quayadmin]` (ya presente en este repo desde el bootstrap) solo
cubre `GET` y el resto de las APIs de gobierno (auto-prune, etc.) — **escribir
cuotas es un caso que Quay separó a propósito**, con su propio flag. Ningún
superusuario puede escribir cuotas sin él, sin importar cómo se autentique.

**Fix:** una línea en `config.yaml` —

```yaml
FEATURE_SUPERUSERS_FULL_ACCESS: true
```

Verificado de punta a punta: el mismo flujo de Playwright que daba `403` pasó
a `200 OK` con `"Successfully updated quota"`.

**La lección, no solo el fix:** ante un `403`/`Unauthorized` de una API de
Quay, la primera pregunta no es "¿el usuario tiene el rol correcto?" sino
"¿el *endpoint* tiene el feature flag correcto?" — Quay expone varias
capacidades de superusuario detrás de flags independientes de `SUPER_USERS`
(este caso; probablemente otros). No asumir que "ya es superusuario" agota la
lista de configuración necesaria.

## Connectivity Link (Kuadrant)

| # | Sev | Hallazgo | Grupo | Estado |
|---|---|---|---|---|
| 1 | 🔴 | TLSPolicy en Git (issuer real en prod); selfsigned marcado NO-PRODUCCION | A | ✅ |
| 2 | 🔴 | Limitador en memoria (falta Redis) | B (Redis externo) | 📋 |
| 3 | 🟠 | HA: Authorino/Limitador 2 réplicas + PDB en prod | A | ✅ |
| 4 | 🟠 | `observability.enable: true` | A | ✅ |
| 5 | 🟠 | mTLS interno gateway↔Authorino/Limitador ON | A | ✅ |
| 6 | 🟠 | Falta DNSPolicy para DR | B | 📋 |
| - | 🟡 | AuthPolicy default del gateway versionada (issuer por overlay) | A | ✅ |

## Service Mesh (OSSM 3)

| # | Sev | Hallazgo | Grupo | Estado |
|---|---|---|---|---|
| SM-1 | 🔴 | Chart crea IstioCNI pero no el namespace `istio-cni` | A | ✅ |
| SM-2 | 🔴 | mTLS STRICT en prod (PeerAuthentication) | A | ✅ |
| SM-3 | 🔴 | istiod HA en prod (autoscale 2-5) | A | ✅ |
| SM-4 | 🟠 | IstioRevisionTag en RevisionBased (no rompe la inyección) | A | ✅ |
| SM-5 | 🟠 | `istioProfile` aplicado también al CR Istio | A | ✅ |
| SM-6 | 🟡 | `values-dev.yaml` con override explícito, sin duplicar | A | ✅ |

## ACS 4.11

| # | Sev | Hallazgo | Grupo | Estado |
|---|---|---|---|---|
| ACS-1 | 🔴 | Las políticas SÍ tienen CRD (`SecurityPolicy`) → deben ser GitOps, no Ansible | A | ✅ |
| ACS-2 | 🔴 | `validate_certs: false` en el playbook | A | ✅ |
| ACS-3 | 🔴 | Enforcement solo por default implícito del operador, no en Git | A | ✅ |
| ACS-4 | 🟠 | Central: scanner AutoSense declarado; DB/TLS/auth marcados NO-PRODUCCION | B | 📋 |
| ACS-5 | 🟠 | Política ahora es CR (reconciliado), no create-only por API | A | ✅ |
| ACS-6 | 🟡 | Valores hub-specific en `base/` (marcados NO-PRODUCCION) | A | ✅ |

## MetalLB

| # | Sev | Hallazgo | Grupo | Estado |
|---|---|---|---|---|
| 1 | 🔴 | L2 marcado NO-PRODUCCION (BGP+BFD en prod) | B | 📋 |
| 2 | 🔴 | Rango de IPs distinto por overlay (dev 10.10.10 / prod 10.10.20) | A | ✅ |
| 3 | 🟠 | Pool dedicado gateway-pool (autoAssign false) + avoidBuggyIPs true | A | ✅ |
| 4 | 🟡 | L2 anuncia ambos pools; nota de acotar interfaces/nodos en prod | A | ✅ |

## cert-manager

| # | Sev | Hallazgo | Grupo | Estado |
|---|---|---|---|---|
| 1 | 🔴 | ClusterIssuer ACME versionado en Git (junto al selfsigned) | A | ✅ |
| 2 | 🟠 | Patrón bootstrap-CA (selfsigned → workshop-ca → issuer ca) | A | ✅ |
| 3 | 🟡 | Overlays dev/prod documentados (dev=CA propia, prod=ACME) | A | ✅ |

## Pipelines / Tekton Chains

| # | Sev | Hallazgo | Grupo | Estado |
|---|---|---|---|---|
| 1 | 🔴 | Clave cosign generada en signing-secrets (firma real); doc + Key Vault en prod | A | ✅ |
| 2 | 🟠 | `transparency.enabled: true` (Rekor) | A | ✅ |
| 3 | 🟠 | `pruner` declarado en Git (keep 100) | A | ✅ |
| 4 | 🟡 | profile documentado + push creds del SA de Chains documentadas | A | ✅ |

## ACM

| # | Sev | Hallazgo | Grupo | Estado |
|---|---|---|---|---|
| 1 | 🔴 | operators/ validado server-side; se aplica al hacer el app-of-apps | A | ✅ |
| 2 | 🔴 | Placement `clusters-prod` clusterSet global→default | A | ✅ |
| 3 | 🔴 | OperatorPolicy con `versions` (pin) + `upgradeApproval: Automatic` | A | ✅ |
| 4 | 🟠 | Namespaces de operadores creados en el árbol | A | ✅ |
| 5 | 🟠 | Policy quota: namespaceSelector (bian-*/user*) + limits | A | ✅ |
| 6 | 🟡 | MultiClusterHub: nota ignoreDifferences (aplica al app-of-apps) | A | ✅ |

## Developer Hub (RHDH 1.10)

| # | Sev | Hallazgo | Grupo | Estado |
|---|---|---|---|---|
| A1 | 🔴 | DB embebida marcada NO-PRODUCCION (PostgreSQL externo en prod) | B | 📋 |
| A2 | 🔴 | OIDC Keycloak en app-config (secret real por ESO en prod) | A | ✅ |
| A3 | 🔴 | backend.auth externalAccess + rhdh-backend-secret (extraEnvs) | A | ✅ |
| M4 | 🟠 | replicas 2 + resources (deployment.patch); NO-PRODUCCION con DB embebida | A | ✅ |
| M5 | 🟠 | Plugins Argo CD + Tekton por OCI (tags verificados) | A | ✅ |
| M6 | 🟠 | RBAC vivo: plugin habilitado + CSV montado + permission.enabled | A | ✅ |
| B7 | 🟡 | integrations github (token por ESO); monitoring/cert notados | A | ✅ |

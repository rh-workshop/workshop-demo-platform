# Backlog de endurecimiento a producción

Revisión producto por producto (6 informes, ~65 hallazgos) contra la documentación
oficial de Red Hat y el clúster real. Este material es un **workshop**: las configs
son de laboratorio y aquí se registra qué falta para llevarlas a producción.

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
| ACM | Placement `clusters-produccion` con set `global` sin binding; OperatorPolicy sin version pinning | 🔧 |

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
| M4 | 🟠 | RealmImport y admin bootstrap fuera de Git | A | 🔧 |
| M5 | 🟠 | Sin backups de DB | B | 📋 |

## Quay 3.17

| # | Sev | Hallazgo | Grupo | Estado |
|---|---|---|---|---|
| 1 | 🔴 | Clair off → sin escaneo de vulnerabilidades | A | 🔧 |
| 2 | 🔴 | Postgres managed 1 pod, sin HA (prod = DB externa) | B | 📋 |
| 3 | 🔴 | Object storage NooBaa "disponibilidad limitada" (prod = S3/RADOS/Azure) | B | 📋 |
| 8 | 🔴 | Sin SUPER_USERS + auto-registro abierto + USER_INITIALIZE on | A (seed) | 🔧 |
| 10 | 🔴 | `validate_certs: false` en el playbook | A | 🔧 |
| 4 | 🟠 | HPA off sin réplicas declaradas | A | 🔧 |
| 5 | 🟠 | Monitoring off (bloqueado por OperatorGroup single-namespace) | A | 🔧 |
| 6 | 🟠 | TLS = wildcard del clúster | B | 📋 |
| 11 | 🟠 | Bug: permisos de robot solo al primer repo (`repositories[0]`) | A | 🔧 |
| 12 | 🟠 | `400=éxito` enmascara errores | A | 🔧 |
| 7,9,13,14 | 🟡 | mirror sin decidir; quota sin default; sin seed quota/prune; typo en comentario | A | 🔧 |

## Connectivity Link (Kuadrant)

| # | Sev | Hallazgo | Grupo | Estado |
|---|---|---|---|---|
| 1 | 🔴 | TLSPolicy en Git (issuer real en prod); selfsigned marcado NO-PRODUCCION | A | ✅ |
| 2 | 🔴 | Limitador en memoria (falta Redis) | B (Redis externo) | 📋 |
| 3 | 🟠 | HA: Authorino/Limitador 2 réplicas + PDB en prod | A | ✅ |
| 4 | 🟠 | `observability.enable: true` | A | ✅ |
| 5 | 🟠 | mTLS interno gateway↔Authorino/Limitador ON | A | ✅ |
| 6 | 🟠 | Falta DNSPolicy para DR | B | 📋 |
| - | 🟡 | Hostname de infra (no de negocio); overlays frágiles; AuthPolicy default huérfana | A | 🔧 |

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
| ACS-4 | 🟠 | Central: DB/TLS/auth/monitoreo sin decisiones de prod | A (parcial) / B (DB) | 🔧 |
| ACS-5 | 🟠 | Playbook create-only, `400=éxito` | A | 🔧 |
| ACS-6 | 🟡 | Valores hub-specific en `base/` (marcados NO-PRODUCCION) | A | ✅ |

## MetalLB

| # | Sev | Hallazgo | Grupo | Estado |
|---|---|---|---|---|
| 1 | 🔴 | Solo L2 (un nodo activo, failover ARP lento) → prod = BGP+BFD | B | 📋 |
| 2 | 🔴 | Mismo rango de IPs en dev y prod (conflicto ARP si comparten L2) | A | 🔧 |
| 3 | 🟠 | Pool sin reserva para el Gateway; `avoidBuggyIPs: false` | A | 🔧 |
| 4 | 🟡 | Sin acotación de speakers/interfaces | A | 🔧 |

## cert-manager

| # | Sev | Hallazgo | Grupo | Estado |
|---|---|---|---|---|
| 1 | 🔴 | En Git solo `selfsigned`; los ACME reales del clúster fuera de Git | A (versionar) / B (ACME real) | 🔧 |
| 2 | 🟠 | selfsigned usado "a pelo", no como bootstrap-CA | A | 🔧 |
| 3 | 🟡 | Overlays dev/prod passthrough (vacíos) | A | 🔧 |

## Pipelines / Tekton Chains

| # | Sev | Hallazgo | Grupo | Estado |
|---|---|---|---|---|
| 1 | 🔴 | Chains activo pero `signing-secrets` VACÍO → no firma nada | A (generar clave) / B (Key Vault) | 🔧 |
| 2 | 🟠 | Sin transparency log (Rekor) | A | 🔧 |
| 3 | 🟠 | Pruner y recursos no declarados en Git | A | 🔧 |
| 4 | 🟡 | `profile: all` en el hub; push creds del SA sin documentar | A | 🔧 |

## ACM

| # | Sev | Hallazgo | Grupo | Estado |
|---|---|---|---|---|
| 1 | 🔴 | Nada del árbol `operators/` aplicado; Policy real en otro namespace | A | 🔧 |
| 2 | 🔴 | Placement `clusters-produccion` con set `global` sin binding → 0 clústeres | A | 🔧 |
| 3 | 🔴 | OperatorPolicy sin `versions` + canales flotantes + `upgradeApproval: None` | A | 🔧 |
| 4 | 🟠 | OperatorPolicy asume namespaces que nadie crea | A | 🔧 |
| 5 | 🟠 | Policy `exigir-resourcequota` solo gobierna `default` | A | 🔧 |
| 6 | 🟡 | MultiClusterHub necesitará `ignoreDifferences` con Argo | A | 🔧 |

## Developer Hub (RHDH 1.10)

| # | Sev | Hallazgo | Grupo | Estado |
|---|---|---|---|---|
| A1 | 🔴 | DB embebida del operador (1Gi, sin backup/HA) | B | 📋 |
| A2 | 🔴 | Sin auth real (guest/anónimo) → OIDC Keycloak | A (config) / B (secret real) | 🔧 |
| A3 | 🔴 | Falta backend service-to-service secret | A | 🔧 |
| M4 | 🟠 | 1 réplica, resources por defecto | A | 🔧 |
| M5 | 🟠 | Plugins Argo CD y Tekton ausentes (OCI, tags verificados) | A | 🔧 |
| M6 | 🟠 | `rbac-policy-configmap` es config muerta (nada lo referencia) | A | 🔧 |
| B7 | 🟡 | monitoring off; catalog sin token GitHub; cert de ingress | A | 🔧 |

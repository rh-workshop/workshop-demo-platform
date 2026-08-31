# Prerrequisitos de implementación — Pipeline de auditoría sobre Kafka (ambiente de Desarrollo)

**Documento de prerrequisitos para el equipo de plataforma**
**Alcance:** ambiente de DESARROLLO (dev)
**Fecha:** <FECHA>
**Versión:** 1.0

---

## Propósito

Este documento describe la implementación del pipeline de auditoría de logs sobre Red Hat
Streams for Apache Kafka en el ambiente de desarrollo, y detalla los valores exactos que
exige su configuración declarativa (GitOps).

> **La instalación y la configuración las ejecuta el equipo de implementación.** Lo que se
> solicita al cliente son **accesos, definiciones de negocio y credenciales**; el resto de
> este documento es descriptivo, para que el equipo de plataforma sepa qué se va a
> desplegar en su ambiente.
>
> El detalle de lo que debe entregar el cliente —y qué valor de referencia se aplicará si
> una decisión no se confirma— está en el fichero **`prerrequisitos-kafka-dev.xlsx`**, que
> es el entregable de seguimiento.

**Decisiones que corresponden al cliente**, hoy cubiertas con valores de referencia:

| Decisión | Valor de referencia |
|---|---|
| Nombre del cluster de Kafka | `demo-kafka` |
| Nombres de los 4 tópicos | `tp.observability.logs.{encrypted,masked}` y sus colas de descarte |
| Nombres de usuarios y grupos de consumo | `log-processor`, `log-sink`, `dummy-data-producer` |
| Retención de los tópicos | 24 h (principales) y 72 h (colas de descarte) |
| Atributos considerados datos personales | `customer.email`, `customer.dni`, `card.pan` |
| Volumen esperado de eventos | 3 particiones · 2,5 MB máximo por mensaje |
| Destino final de los eventos enmascarados | Pendiente de definir |

Cambiar cualquiera de estos valores **después** del despliegue obliga a tocar todos los
clientes que ya se hayan integrado: conviene confirmarlos antes de empezar.

El pipeline consta de tres roles que comparten un mismo binario (Quarkus/Java) más un
emisor de referencia en .NET:

| Componente | Función | Existe en dev |
|---|---|---|
| `log-processor` | Consume eventos cifrados, descifra, enmascara datos personales y publica el resultado | Sí |
| `log-sink` | Consume los eventos enmascarados y los entrega al destino final; **no monta la llave de cifrado** | Sí |
| `dummy-data-producer` (Java) | Emite eventos de prueba con datos ficticios | Solo dev y test |
| `dummy-data-producer-dotnet` (.NET) | Host de referencia del paquete .NET que cifra y publica | Solo dev y test |

---

## 1. Plataforma y cluster

### 1.1 Versión de OpenShift

- OpenShift Container Platform 4.x (versión exacta del ambiente: `<OCP_VERSION>`, a
  confirmar con el equipo de plataforma; debe ser compatible con las CSV pineadas de la
  sección 1.2).

### 1.2 Operadores requeridos

Los operadores **no** se instalan a mano ni los gestiona Argo CD: los instala **Red Hat
Advanced Cluster Management (ACM)** mediante una `OperatorPolicy` con la versión de CSV
**pineada** (el upgrade se decide por Pull Request en Git, nunca automáticamente).

| Operador | Subscription (nombre exacto) | Canal | CSV pineada | Namespace | Mecanismo |
|---|---|---|---|---|---|
| Streams for Apache Kafka (AMQ Streams) | `amq-streams` | `stable` | `amqstreams.v3.2.1-10` | `kafka` | `OperatorPolicy` de ACM (`install-operators-workload`) |
| OpenShift GitOps (Argo CD) | `openshift-gitops-operator` | GA | — | `openshift-gitops` | Bootstrap del hub |
| OpenShift Pipelines (Tekton + Pipelines as Code) | operador de Pipelines | GA | — | `openshift-pipelines` | Instalación de plataforma (hub) |

Todos provienen del catálogo `redhat-operators` (`openshift-marketplace`). No se admiten
operadores community.

> La misma Policy de ACM crea también el namespace destino **antes** que la
> `OperatorPolicy`: sin el namespace, la política queda `NonCompliant` de forma permanente.

### 1.3 Namespaces y etiquetas

| Namespace | Quién lo crea | Etiquetas requeridas | Contenido |
|---|---|---|---|
| `kafka` | Policy de ACM (creación) + ApplicationSet de plataforma (gestión) | `workshop.redhat.com/layer: infrastructure`, `workshop.redhat.com/component: kafka` (adaptar al estándar de etiquetado corporativo `<PREFIJO>/layer`, `<PREFIJO>/component`) | Cluster Kafka, tópicos, usuarios **y los servicios del pipeline** |
| `workshop-demo-dev` (namespace de CI en el hub — adaptar nombre) | Gobierno de namespaces (GitOps) | Etiquetas de gobierno del ambiente | Pipeline de CI, Tasks, `ServiceAccount builder`, CRs `Repository` de Pipelines as Code |
| `openshift-gitops` | Operador GitOps | — | Argo CD del hub, ApplicationSets, AppProject |

**Decisión de diseño que el cliente debe conocer:** los servicios del pipeline se
despliegan **en el mismo namespace `kafka`**, no en namespaces propios. Motivo: consumen
los `Secret` que genera el operador (certificado del `KafkaUser` y CA del cluster), que
son locales a ese namespace; separarlos obligaría a replicar secretos entre namespaces.

### 1.4 Recursos de cómputo y almacenamiento del cluster Kafka en dev

En dev prima el costo sobre la capacidad: **1 broker + 1 controller** (KRaft, sin
ZooKeeper; los roles viven en `KafkaNodePool` dedicados). Cruise Control se elimina en
dev (no hay entre qué rebalancear).

| Pool | Réplicas | CPU (request/limit) | Memoria (request/limit) | JVM heap | Disco (PVC) |
|---|---|---|---|---|---|
| `broker` | 1 | 250m / 1 | 1Gi / 2Gi | 512m fijo (Xms=Xmx) | 5Gi (JBOD, persistent-claim, `deleteClaim: false`) |
| `controller` | 1 | 250m / 500m | 512Mi / 1Gi | — | 5Gi (JBOD, persistent-claim, `deleteClaim: false`) |

**Almacenamiento:** los `KafkaNodePool` no fijan `storageClassName`: usan la
**StorageClass por defecto** del cluster, que **debe ser de bloque (RWO)** — Kafka no
opera sobre NFS. Confirmar cuál es la StorageClass por defecto en dev: `<STORAGE_CLASS_DEFAULT>`.

**Configuración del cluster (CR `Kafka`, nombre `demo-kafka`):**

- Kafka `4.2.0`, `metadataVersion: 4.2-IV1` (versión pineada; se sube por PR).
- `auto.create.topics.enable: false` — los tópicos solo se crean por Git.
- `authorization: type: simple` (ACLs) y **sin `superUsers`** a propósito.
- `message.max.bytes: 2500000` y `replica.fetch.max.bytes: 2500000` (2,5 MB): los
  clientes Java y .NET declaran el mismo límite; ambos lados deben coincidir.
- En dev, un patch baja la replicación del cluster: `default.replication.factor: 1`,
  `min.insync.replicas: 1`, y lo mismo para los tópicos internos de offsets y transacciones.
- Métricas JMX en formato Prometheus (`ConfigMap kafka-metrics`) + `kafkaExporter` (lag
  de grupos de consumo) + 3 `PodMonitor` (`kafka-resources`, `cruise-control` — no aplica
  en dev —, `kafka-exporter`). Requiere **User Workload Monitoring habilitado**
  (`enableUserWorkloadMonitoring`) en el cluster.
- `rack.topologyKey: topology.kubernetes.io/zone` (inofensivo en dev de una sola zona).

---

## 2. Tópicos

Nombres **exactos** (convención del dominio de observabilidad, prefijo `tp.observability.*`).
Los valores de la tabla son los del `base`; ver la advertencia de dev debajo.

| Tópico | Particiones | Réplicas (base) | Retención | Tamaño máx. de mensaje | `min.insync.replicas` (base) | Propósito |
|---|---|---|---|---|---|---|
| `tp.observability.logs.encrypted` | 3 | 3 | 24 h (`retention.ms: 86400000`) | 2,5 MB (`max.message.bytes: 2500000`) | 2 | Eventos de auditoría **cifrados** que publican los productores |
| `tp.observability.logs.encrypted.dlq` | 3 | 3 | 72 h (`retention.ms: 259200000`) | 2,5 MB | 2 | Cola de descarte de eventos cifrados no procesables (retención mayor para triage) |
| `tp.observability.logs.masked` | 3 | 3 | 24 h | 2,5 MB | 2 | Eventos **descifrados y enmascarados** que publica el processor |
| `tp.observability.logs.masked.dlq` | 3 | 3 | 72 h | 2,5 MB | 2 | Cola de descarte del sink (fallos de entrega al destino final) |

Configuración común: `segment.bytes: 268435456`, `cleanup.policy: delete`,
`compression.type: producer` (el broker no recomprime).

> **ADVERTENCIA — dev con un solo broker.** El overlay de dev aplica un patch por
> selector de `kind` que baja **todos** los tópicos a `replicas: 1` y
> `min.insync.replicas: 1`: con un único broker no hay dónde colocar tres réplicas y el
> tópico ni siquiera llegaría a crearse. Esta reducción es exclusiva de dev; test, prod y
> contingencia conservan 3 réplicas / 2 en sincronía. **En dev no hay tolerancia a fallos
> del broker: no usarlo como referencia de durabilidad.**

---

## 3. Usuarios y permisos (ACLs)

Una identidad **por servicio**, declarada como `KafkaUser` con `authentication: type: tls`
(el User Operator genera el certificado de cliente) y `authorization: type: simple`.

### 3.1 `log-processor`

| Recurso | Tipo | Operaciones |
|---|---|---|
| `tp.observability.logs.encrypted` | topic (literal) | Describe, Read |
| `tp.observability.logs.masked` | topic (literal) | Describe, Write |
| `tp.observability.logs.encrypted.dlq` | topic (literal) | Describe, Write |
| `log-processor-group` | group (literal) | Read |

### 3.2 `log-sink`

| Recurso | Tipo | Operaciones |
|---|---|---|
| `tp.observability.logs.masked` | topic (literal) | Describe, Read |
| `tp.observability.logs.masked.dlq` | topic (literal) | Describe, Write |
| `log-sink-group` | group (literal) | Read |

### 3.3 `dummy-data-producer` (compartido por los emisores Java y .NET; solo dev/test)

| Recurso | Tipo | Operaciones |
|---|---|---|
| `tp.observability.logs.encrypted` | topic (literal) | Describe, Write |

### 3.4 Cuotas por cliente

Los tres usuarios llevan cuotas para que un cliente defectuoso no sature el broker:
`producerByteRate: 2097152` (2 MiB/s), `consumerByteRate: 5242880` (5 MiB/s, solo
processor y sink), `requestPercentage: 30`, `controllerMutationRate: 5` (processor y sink).

### 3.5 Principio de mínimo privilegio

- Cada servicio tiene su **propia identidad**: no hay usuarios compartidos ni comodines
  (`patternType: literal` en todas las ACLs).
- El emisor de datos ficticios **solo escribe** en el tópico cifrado: nunca puede leer lo
  que el pipeline procesa.
- El sink **no puede leer el tópico cifrado** ni monta la llave de cifrado: aunque su pod
  se comprometa, no hay forma de descifrar.
- El cluster no define `superUsers`: nadie bypasea la autorización.
- `auto.create.topics.enable: false`: un cliente no puede crear tópicos por accidente.

---

## 4. Conexiones y red

### 4.1 Listeners de Kafka

| Listener | Puerto | Tipo | TLS | Autenticación | Uso |
|---|---|---|---|---|---|
| `tls` | 9093 | `internal` | Sí | mTLS (`type: tls`) | Clientes dentro del cluster (los 4 servicios del pipeline) |
| `external` | 9094 | `route` (passthrough) | Sí | mTLS (`type: tls`) | Clientes fuera del cluster (si aplica; portable a cloud sin MetalLB) |

No existe ningún listener en claro. Todo cliente se autentica con certificado.

### 4.2 Cómo se conectan los clientes

- Bootstrap **interno** (DNS del Service): `demo-kafka-kafka-bootstrap:9093`
  (dentro del namespace `kafka`; desde otro namespace sería
  `demo-kafka-kafka-bootstrap.kafka.svc:9093`).
- Protocolo `SSL` con almacenes **PKCS12**: keystore del usuario en
  `/opt/user/user.p12`, truststore de la CA del cluster en `/opt/ca/ca.p12`
  (rutas montadas desde los Secrets de la sección 5). El cliente .NET usa el
  directorio de certificados (`CERT_DIR=/opt/user`) y la CA en PEM (`CA_FILE=/opt/ca/ca.crt`).
- Garantías del productor: `acks=all` + idempotencia habilitada; el consumidor confirma
  offsets **después** de procesar (`enable.auto.commit=false`).

### 4.3 Certificados: quién los genera

**Todo lo genera el operador de Streams for Apache Kafka** — no hay que emitir ni
importar certificados manualmente:

- La **Cluster CA** y los certificados de brokers: los crea y **rota** el operador
  (Secret `demo-kafka-cluster-ca-cert`).
- El certificado de **cada cliente**: lo emite el User Operator al reconciliar cada
  `KafkaUser` (Secret homónimo al usuario).

### 4.4 Tráfico que sale del cluster

En dev, **ninguno propio del pipeline**: productores, processor y sink hablan solo con el
bootstrap interno por 9093. El listener 9094 (Route passthrough) queda disponible para
clientes externos si el cliente decide usarlos; en ese caso el firewall corporativo debe
permitir TLS 443 hacia `<DOMINIO_APPS_DEV>`. El CI (hub) sí necesita salida hacia el
registro de imágenes y el repositorio Git (sección 8).

---

## 5. Secretos

| Secret (namespace `kafka`) | Quién lo crea | Claves | Quién lo monta / consume |
|---|---|---|---|
| `demo-kafka-cluster-ca-cert` | **Operador** (Cluster Operator) | `ca.p12`, `ca.password`, `ca.crt` | Los 4 Deployments: truststore en `/opt/ca` + variable `CA_PASSWORD` por `secretKeyRef` |
| `log-processor` | **Operador** (User Operator, al reconciliar el `KafkaUser`) | `user.p12`, `user.password`, `user.crt`, `user.key` | `log-processor`: keystore en `/opt/user` + `USER_PASSWORD` |
| `log-sink` | **Operador** (User Operator) | ídem | `log-sink` |
| `dummy-data-producer` | **Operador** (User Operator) | ídem | `dummy-data-producer` y `dummy-data-producer-dotnet` |
| `kv-demo` | **Manual — fuera del flujo GitOps** (ver 5.1) | `aes-key` | `log-processor` y los dos emisores, en `/opt/kv`. **El sink NO lo monta** |
| `quay-pull-credentials` | Automatización de plataforma (playbook + Policy de ACM) | `.dockerconfigjson` | ServiceAccount que hace pull de las imágenes del registro corporativo (ver nota en 5.2) |

Todos los Deployments llevan la anotación `reloader.stakater.com/auto: "true"`: cuando un
Secret montado rota (llave AES, certificados), el pod se reinicia solo.

### 5.1 La llave de cifrado (`kv-demo`) — atención especial

- **No está en Git ni puede estarlo**: es la llave maestra de la que se derivan las claves
  AES-256 (derivación HKDF-SHA256, RFC 5869 / NIST SP 800-56C, con etiqueta de propósito
  `redhat-workshop/kafka-audit/aes256gcm/v2` — idéntica byte a byte en Java y .NET).
- Se crea **una vez por ambiente**, con una llave **distinta** en cada uno:

  ```bash
  oc create secret generic kv-demo -n kafka \
    --from-literal=aes-key="$(openssl rand -base64 32)"
  ```

- El formato del payload cifrado va **versionado** (`KEY_ID`) precisamente para poder
  rotar la llave: durante la rotación se montan además `PREVIOUS_KEY_FILE` /
  `PREVIOUS_KEY_ID` en modo solo-descifrado, hasta que la retención del tópico supera el
  momento de la rotación.
- **ADVERTENCIA para ambientes superiores:** este `oc create secret` manual es aceptable
  únicamente en desarrollo. En producción la llave debe vivir en un **gestor de secretos
  corporativo (vault)** y sincronizarse al cluster vía External Secrets Operator, que
  además habilita la rotación gobernada.

### 5.2 Nota sobre el pull secret en el namespace `kafka`

La Policy de ACM que replica `quay-pull-credentials` descubre los namespaces de negocio
por convención de nombre (`user*`, `*-demo-dev`, `workshop-demo-*`), y el namespace
`kafka` no encajaba en ninguno de esos patrones: sus cargas descargan del mismo registro
privado, pero allí el secreto no llegaba y los pods habrían quedado en `ImagePullBackOff`.

**Resuelto**: el patrón de la Policy se extendió para incluir `kafka`. La Policy crea el
Secret **y** lo enlaza al ServiceAccount `default` del namespace — hacen falta los dos: con
el secreto presente pero sin el enlace, el kubelet no lo usa.

No requiere acción del cliente más allá de verificar la casilla del checklist una vez
sincronizada la Policy.

---

## 6. Repositorios Git

| Repositorio | Contenido | Quién lo consume |
|---|---|---|
| `<ORG_GIT>/kafka-audit-pipeline` (código) | Fuente Java (Quarkus) del pipeline (processor/sink) y del emisor de referencia; `.tekton/` con sus PipelineRuns. De él salen **dos imágenes** | CI (Pipelines as Code). **Argo CD NO lo mira** |
| `<ORG_GIT>/kafka-audit-producer` (código) | Paquete .NET y host de ejemplo; `.tekton/` propio | CI. Argo CD NO lo mira |
| `<ORG_GIT>/kafka-audit-pipeline-config` (configuración) | Kustomize de despliegue: tópicos, usuarios, Deployments, overlays por ambiente; `.tekton/` con los PipelineRuns de promoción | **Argo CD** (ApplicationSet `kafka-services-dev`) |
| `<ORG_GIT>/platform-config` (plataforma) | Cluster Kafka (`kafka/gitops/`), ApplicationSets, AppProject, Policies de ACM, pipelines de CI | **Argo CD** (repo de administración de plataforma) |

### 6.1 Estructura obligatoria del repo de configuración

El ApplicationSet descubre servicios con el generador `git` de directorios sobre el
patrón `apps/*/overlays/dev`:

```
apps/
├── log-processor/        base/ + overlays/{dev,test,prod,contingencia}/
├── log-sink/             base/ + overlays/{dev,test,prod,contingencia}/
└── dummy-data-producer/  base/ + overlays/{dev,test}/   ← SIN overlay en prod
```

- Un servicio **entra en un ambiente creando su carpeta** `apps/<servicio>/overlays/<ambiente>`;
  la **ausencia de carpeta es lo que lo mantiene fuera** (así el generador de datos
  ficticios no puede desplegarse en producción).
- La imagen se fija **por digest en el overlay** de cada ambiente (bloque `images:`),
  nunca por tag en el `base`. El nombre lógico (`kafka-audit-pipeline`) debe coincidir
  con el parámetro `image-name` del PipelineRun de promoción.

### 6.2 Sincronización y permisos de Argo CD

- Sincroniza el **ApplicationSet `kafka-services-dev`** (generador `matrix` =
  `clusterDecisionResource` sobre el Placement `clusters-dev` de ACM × generador `git` de
  directorios), destino: namespace `kafka` del cluster de dev, proyecto Argo
  `workshop-platform`, con `automated` (prune + selfHeal), reintentos con backoff (hasta
  20, máx. 10 min) y `CreateNamespace=false` (el namespace lo crea la plataforma).
- El **AppProject** acota fuente, destinos y kinds permitidos con allow-list que **falla
  cerrado**: los kinds `Kafka`, `KafkaNodePool`, `KafkaTopic`, `KafkaUser` (grupo
  `kafka.strimzi.io`) y `PodMonitor` ya están permitidos; un kind nuevo se rechaza hasta
  listarlo conscientemente.
- **Permisos de Argo sobre los repos:** lectura (clone) de los repos de configuración y
  plataforma. En los repos actuales el acceso es HTTPS anónimo por ser públicos; en el
  entorno del cliente los repos serán privados y Argo necesitará una **credencial de solo
  lectura** (repo-creds con PAT/SSH o app de Git corporativa) — **valor pendiente de
  definir con el cliente**: `<CREDENCIAL_ARGO_GIT>`.
- La rama que sincroniza Argo es `main`; las ramas `test` y `prod` gobiernan la promoción
  (sección 8). La rama `main` del repo de **plataforma** debe estar **protegida con
  revisión obligatoria** (puede crear ClusterRoleBinding, Policies, etc.).

---

## 7. Registro de imágenes (Quay)

### 7.1 Organizaciones

Organizaciones por ambiente con prefijo corporativo (`org_prefix`, hoy `company` — el
cliente lo sustituye por el suyo): `<PREFIJO>-dev`, `<PREFIJO>-test`, `<PREFIJO>-prod`,
`<PREFIJO>-contingencia`, más `<PREFIJO>-tooling` (herramientas de CI espejadas: semgrep
1.79.0, syft v1.19.0, gitleaks v8.29.1 — únicas imágenes no-Red Hat, excepción documentada).

Gobierno por organización en dev: cuota 50 GiB (`quota_bytes: 53687091200`), auto-prune
por antigüedad conservando 4 semanas (`prune_keep_since: 4w`), repositorios **privados**
(sin lectura anónima, criterio de banca).

### 7.2 Repositorios de imagen del pipeline (nombres exactos, iguales en todas las organizaciones)

| Repositorio | Contenido |
|---|---|
| `kafka-audit-pipeline` | Pipeline de auditoría (processor y sink: mismo binario, distinto `ROLE`) |
| `kafka-audit-demo-producer` | Generador de datos ficticios (Java) — solo se despliega en dev y test |
| `kafka-audit-producer-dotnet` | Host de ejemplo del paquete .NET que cifra y publica |

### 7.3 Cuentas robot y permisos por ambiente

| Organización | Robot | Permiso | Uso |
|---|---|---|---|
| `<PREFIJO>-dev` / `-test` | `puller` | read | Pull de los workloads |
| `<PREFIJO>-dev` / `-test` | `pusher` | **write** en dev/test (`ci_push: true`) | El CI publica |
| `<PREFIJO>-prod` / `-contingencia` | `puller` | read | Pull de los workloads |
| `<PREFIJO>-prod` / `-contingencia` | `pusher` | **read** (`ci_push: false`) | **Nadie publica desde CI** |
| `<PREFIJO>-prod` / `-contingencia` | `promoter` | write | Única vía de escritura: la promoción, con credencial aparte |
| Todas + tooling | `acs-scanner` | read | Escaneo de imágenes por ACS |

### 7.4 Modelo de promoción

1. **CI → dev:** al hacer push al repo de código, el pipeline construye, firma (cosign),
   escanea y publica en `<PREFIJO>-dev`, y escribe el **digest** en `overlays/dev` del
   repo de configuración.
2. **dev → test → prod:** los PipelineRuns `promote-*` **copian la imagen entre
   organizaciones sin reconstruirla** y actualizan el digest del overlay destino. Se
   disparan **solo por Pull Request** contra las ramas `test` y `prod`: a un ambiente
   superior nunca se llega con push directo. La firma se verifica siempre; hacia
   producción se exige además commit etiquetado.

---

## 8. CI/CD (OpenShift Pipelines + Pipelines as Code)

Todo el CI corre en el namespace de desarrollo del hub (`workshop-demo-dev` en la
referencia — adaptar al naming corporativo), donde viven el `Pipeline`, las `Task`, el
`ServiceAccount` y los CRs `Repository`.

### 8.1 Pipelines as Code (PaC)

- Un CR `Repository` **por repo** que dispara CI. Para el pipeline de auditoría hacen
  falta tres: `kafka-audit-pipeline` (código Java), `kafka-audit-producer` (código .NET)
  y `kafka-audit-pipeline-config` (configuración/promoción). PaC ejecuta los PipelineRuns
  de la carpeta `.tekton/` **de cada repo** en el namespace del CR.
- **Webhook de Git** en cada repositorio: apuntando a la Route
  `pipelines-as-code-controller` del cluster, content-type JSON, con el secreto HMAC
  compartido.
- Dos Secrets, creados una sola vez en el namespace de CI:

  ```bash
  # PAT con permiso de leer el repo y escribir commit statuses
  oc create secret generic pac-git-token -n <NS_CI> --from-literal=token=<PAT>

  # Secreto HMAC del webhook: sin él, cualquiera podría falsificar un evento
  oc create secret generic pac-webhook-secret -n <NS_CI> \
    --from-literal=webhook.secret=$(openssl rand -hex 20)
  ```

### 8.2 ServiceAccount `builder`

Cuenta propia (no se reutiliza `pipeline` ni `default`) para acotar permisos:

- `RoleBinding builder-pipelines-scc` → ClusterRole `pipelines-scc-clusterrole` (SCC de
  OpenShift Pipelines; sin él, los pods de build fallan la validación de SCC).
- Pull secret del CI (`quay-pull-credentials`): fusión del robot **pusher del ambiente
  dev** + **puller de tooling**, generada por la automatización de plataforma.

### 8.3 Credenciales que consumen las tasks

| Secret | Contenido | Lo usan |
|---|---|---|
| `git-credentials` | basic-auth de Git (escritura del digest en el repo de configuración) | Tasks de actualización de overlay en CI y promoción |
| `quay-push-credentials` (workspace `registry-credentials`) | `config.json` del robot del registro | Build/push de imagen, firma y guarda de idempotencia |
| `cosign-signing-key` | `cosign.key`, `cosign.pub`, `password` (generado con `cosign generate-key-pair k8s://...`) | Firma de imagen y SBOM en CI; en promoción **solo la clave pública** para verificar |
| `acs-pipeline-credentials` | `rox-api-token` (rol Continuous Integration) + `ca.pem` de Central | Escaneo de imagen (`roxctl`) y chequeo de políticas DEPLOY sobre el overlay renderizado |

### 8.4 Puertas de calidad del pipeline de CI (informativas)

Tests unitarios por lenguaje (Java/.NET), detección de secretos en árbol e historial
(gitleaks, **falla cerrado**), SAST (semgrep), build, firma cosign, escaneo ACS, SBOM
(syft) y chequeo de políticas DEPLOY antes de promocionar el digest.

---

## 9. Seguimiento

El checklist accionable vive en **`prerrequisitos-kafka-dev.xlsx`**, que es el entregable
de seguimiento: una sola hoja, con lo que entrega el cliente separado de lo que ejecuta el
equipo de implementación, el valor de referencia que se aplicará si una decisión no se
confirma, y una columna de estado para reportar el avance.

Se mantiene en un único sitio a propósito: duplicar el checklist aquí llevaría a que las
dos copias dejaran de coincidir.

---

*Documento generado como parte del engagement de consultoría. Los valores entre `<...>`
deben sustituirse por los del entorno del cliente antes de la ejecución.*

# kafka — plataforma de mensajería

Configuración de **Streams for Apache Kafka** (AMQ Streams): el cluster, sus
tópicos y las identidades que lo usan. El operador lo instala ACM por política;
aquí vive solo el operando, como en el resto de productos del repositorio.

## Se despliega por ApplicationSet, como producto workload

Kafka corre junto a las aplicaciones que lo consumen, así que va a los spokes por
ambiente. Está en el `list` de los cuatro `workload-<ambiente>-applicationset`, y
cada uno apunta a `kafka/gitops/overlays/<ambiente>`. Un cluster nuevo del mismo
ambiente lo recibe solo, sin tocar estos manifiestos.

| Pieza | Dónde |
|---|---|
| Instalación del operador | `acm/gitops/base/policies/install-operators/workload-policy.yaml` (`OperatorPolicy` de ACM) |
| Configuración (los CR) | `kafka/gitops/base` + `overlays/<ambiente>` |

## Qué se despliega

| Manifiesto | Para qué |
|---|---|
| `kafka.yaml` | El cluster: modo KRaft, listeners con mTLS, autorización por ACL y métricas |
| `controller-kafkanodepool.yaml` | Controladores dedicados: sostienen el quórum de metadatos |
| `broker-kafkanodepool.yaml` | Brokers dedicados: reciben y sirven los mensajes |
| `kafka-metrics-configmap.yaml` | Reglas de exposición de métricas de los brokers |
| `kafka-podmonitor.yaml` | Recolección de esas métricas: brokers, Cruise Control y el exportador de retraso |
| `demo-events-kafkatopic.yaml` | Tópico de eventos de la aplicación de demostración |
| `demo-events-dlq-kafkatopic.yaml` | Cola de descarte de los mensajes no procesables |
| `demo-producer-kafkauser.yaml` | Identidad del productor: solo escribe |
| `demo-consumer-kafkauser.yaml` | Identidad del consumidor: lee y aparta a la cola de descarte |

> **Los cuatro recursos `demo.*` son un ejemplo de referencia, no una carga en uso.**
> Muestran el patrón mínimo —un tópico, su cola de descarte y una identidad por
> extremo con permisos de mínimo privilegio— para que un equipo lo copie al añadir su
> primer tópico. Hoy ninguna aplicación los usa.
>
> La carga real es el **pipeline de auditoría**, cuya configuración vive en
> [`workshop-demo-kafka-audit-pipeline-config`](https://github.com/rh-workshop/workshop-demo-kafka-audit-pipeline-config)
> y usa la convención de nombres del dominio: `tp.observability.logs.*`. Ese prefijo
> jerárquico (`tp` = tópico, luego dominio y flujo) es el que conviene adoptar como
> gobierno de nombres cuando los tópicos se cuentan por decenas; `demo.events` solo
> pretende ser legible en un ejemplo.

## Buenas prácticas aplicadas

**Roles separados (KRaft).** Controladores y brokers en `KafkaNodePool` distintos.
Un broker saturado por tráfico no arrastra al quórum de metadatos, y cada rol se
dimensiona por lo que realmente hace.

**Durabilidad antes que rendimiento.** Replicación de factor 3 con dos réplicas en
sincronía como mínimo: el cluster sigue aceptando escrituras si cae un broker, y
ningún mensaje confirmado se pierde. En dev baja a 1 porque solo hay un broker.

**mTLS y mínimo privilegio.** Todos los listeners exigen certificado de cliente y
la autorización es por ACL declarativas: el productor solo escribe, el consumidor
solo lee. **Sin superusuarios** — uno solo bypasearía toda la autorización.

**Cuotas por cliente.** Cada identidad lleva límites de ancho de banda y de
porcentaje de petición, para que un cliente descontrolado no agote el cluster.

**Cola de descarte.** Un mensaje que el consumidor no puede procesar se aparta en
lugar de bloquear su partición, y se conserva más tiempo que el original para dar
margen a analizar la causa.

**Tópicos declarados en Git.** `auto.create.topics.enable: false`: un cliente no
puede crear un tópico por accidente ni con un nombre mal escrito.

**Reparto entre nodos.** Anti-afinidad por `strimzi.io/pool-name`, de modo que
cada broker se separa de otros brokers y cada controlador de otros controladores.
Es preferente en la base y **obligatoria en producción**: dos brokers en el mismo
nodo anularían el efecto de la replicación, y tres controladores juntos harían que
la caída de un nodo se llevara el quórum entero.

> El selector debe ser `pool-name`, no `strimzi.io/cluster`: esa segunda etiqueta la
> llevan **todos** los pods del cluster (incluidos operador, Cruise Control y
> exportador), así que con `required` un broker rechazaría cualquier nodo que ya
> tuviera cualquier pod de Kafka y quedaría en `Pending`.

**Métricas recolectadas de verdad.** El CR solo las publica; los `PodMonitor` son
los que hacen que Prometheus las lea. Requiere `enableUserWorkload` en la
monitorización de la plataforma, que este repo ya activa en `monitoring/`.

**Almacenamiento de bloque.** Los volúmenes no fijan `StorageClass`: usan la
predeterminada del cluster, que debe ser de bloque (RWO). Kafka no opera sobre NFS.

## Diferencias por ambiente

| Ambiente | Brokers | Controladores | Réplicas | Disco por broker |
|---|---|---|---|---|
| dev | 1 | 1 | 1 | 5Gi |
| test | 3 | 3 | 3 | 10Gi |
| prod | 3 | 3 | 3 | 100Gi |
| contingencia | 3 | 3 | 3 | 100Gi |

Test replica la topología de producción a propósito: es la única forma de que una
prueba de resiliencia aquí signifique algo para producción. El disco de producción
es un punto de partida — hay que dimensionarlo con la volumetría real antes de
desplegar; el volumen admite expansión posterior.

**Prerrequisito de prod y contingencia:** la anti-afinidad obligatoria exige al
menos tres nodos de trabajo disponibles; con menos, los brokers quedan en `Pending`.

**Alcance de contingencia.** El overlay levanta un cluster gemelo, pero **no replica
los datos**: no hay `KafkaMirrorMaker2`. Es contingencia de plataforma, no de datos —
un failover arrancaría con los tópicos vacíos. Replicar datos y posiciones de consumo
es un trabajo aparte, fuera de este alcance.

**Dev sin Cruise Control.** Con un solo broker no hay entre qué nodos rebalancear, así
que el overlay lo retira para no gastar memoria en un pod sin función.

## La llave de cifrado

No es un manifiesto: es material sensible que no puede vivir en Git. Se deposita en el
almacen de la plataforma con

```bash
ansible-playbook kafka/ansible/llaves-cifrado.yml
```

**Una llave por ambiente**, en `platform/kafka-audit/<ambiente>`. Compartirla entre
ambientes significaria que quien accede al menos protegido puede descifrar los eventos de
produccion.

El playbook es idempotente y **no regenera una llave existente**: rehacerla dejaria
indescifrable todo lo ya publicado en ese ambiente. Quien materializa el Secret en el
cluster es el `ExternalSecret` del repo de configuracion, no este playbook.

## Verificar el despliegue

```bash
oc get kafka,kafkanodepool -n kafka
oc wait --for=condition=Ready kafka/demo-kafka -n kafka --timeout=600s
oc get kafkatopic,kafkauser -n kafka
```

El `KafkaUser` genera un Secret con el certificado de cliente; ese Secret es el
que monta la aplicación para conectarse por mTLS.

## Versiones

Verificado contra **Streams for Apache Kafka 3.2.1** (CSV `amqstreams.v3.2.1-10`,
canal `stable`). Esa versión sirve los CR en **`kafka.strimzi.io/v1`**; las ramas
anteriores usaban `v1beta2`, que aquí ya no aplica. Los manifiestos se validaron
con `oc apply --dry-run=server` sobre los cuatro overlays.

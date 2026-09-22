# Arquitectura a fondo

Cómo está armado el laboratorio y por qué cada pieza está donde está.

---

## 1. El mecanismo canary

**En AWS** se usa la estrategia de canary nativa de ECS
(`deployment_configuration` en `infra/terraform/ecs.tf`), lanzada en octubre de
2025. Un solo servicio ECS, un ALB con dos target groups —`primary` (la
revisión actual) y `alternate` (la revisión nueva)— y una *listener rule* de
producción que ECS reescribe él mismo durante el rollout:

```
aws_ecs_service.app
  deployment_configuration
    strategy               = CANARY
    canary_configuration { canary_percent = 10, canary_bake_time_in_minutes = 5 }
    bake_time_in_minutes   = 5
  alarms { enable = true, rollback = true, alarm_names = [...] }
  load_balancer
    advanced_configuration
      alternate_target_group_arn = target group alternate
      production_listener_rule   = listener rule de producción
      role_arn                   = rol que deja a ECS mover la regla
```

Un rollout (`./scripts/canary-deploy.sh --tag v2`) es una sola llamada:
`aws ecs update-service --task-definition ... --force-new-deployment`. De ahí en
más, **ECS orquesta todo solo**:

1. crea la revisión nueva ("green") y la registra en el target group `alternate`;
2. espera a que sus tareas estén sanas;
3. mueve `canary_percent`% del tráfico de producción a `alternate` y hornea
   `canary_bake_time_in_minutes` minutos, vigilando las alarmas de abajo;
4. si las alarmas siguen en `OK`, mueve el resto del tráfico de una vez;
5. hornea `bake_time_in_minutes` minutos más con ambas revisiones corriendo
   (rollback instantáneo, sin reiniciar nada) y termina la revisión vieja.

Si cualquier alarma pasa a `ALARM` en cualquier momento, ECS revierte el
tráfico a la revisión vieja y aborta el rollout — sin que ningún script tenga
que sondear nada. `scripts/canary-deploy.sh` y `scripts/status.sh` solo leen
`rolloutState` (`IN_PROGRESS` / `COMPLETED` / `FAILED`) para reportar el
progreso al operador.

**El laboratorio local** (`local/mini-alb`) sigue el diseño anterior a esta
migración, a propósito: dos contenedores (`stable`/`canary`) detrás de un
balanceador de juguete que reparte tráfico por **peso explícito**
(`./scripts/weights.sh --target local --canary 25`), como se hacía con un ALB
antes de que existiera la estrategia nativa. Es la forma más directa de
enseñar *qué* hace un canary (pesos relativos, sorteo por petición, rollback
como una escritura de dos números) antes de delegarlo a la orquestación de
ECS. Ver la sección 8 para el detalle del mini-ALB.

### Rutas forzadas (solo en el laboratorio local)

En `local/mini-alb`, cuatro reglas permiten mirar una versión concreta sin
tocar los pesos, vía `?track=` o el header `X-Canary`. En AWS esto ya no
existe: no hay un track "canary" fijo al que apuntar, solo la revisión que ECS
esté corriendo en cada target group en un momento dado.

---

## 2. Flujo de una petición

En el laboratorio local (dos contenedores, pesos explícitos):

```
navegador
  └─> mini-alb :8080
        └─> ¿coincide alguna regla forzada?
              sí -> target group indicado
              no  -> sorteo por pesos
                      └─> contenedor stable o canary
                            ├─ aplica la falla inyectada: latencia y/o 500
                            ├─ escribe el hit en DynamoDB (async)
                            ├─ suma al buffer EMF
                            └─ responde con X-Track, X-Version, X-Task-Id
```

Las cabeceras de identidad son el truco que hace todo observable: el navegador, el
generador de carga y CI cuentan el reparto leyendo `X-Track` (en local) o
`X-Version` (en AWS), sin necesitar acceso a AWS.

En AWS la tarea que responde no sabe si es la revisión `primary` o `alternate`:
`TRACK` no se setea, así que toda tarea se identifica como `stable` y `X-Track`
siempre vale `stable`. Lo que distingue a las revisiones es `X-Version`
(`APP_VERSION`), y por eso el reparto se cuenta por versión. El porcentaje
*configurado* lo lee la app aparte, de la *production listener rule* que ECS
reescribe (ver `/api/weights`).

---

## 3. La aplicación

Node 22 con Express, sin build step y sin dependencias de frontend.

### Endpoints

| Ruta | Para qué |
|---|---|
| `GET /` | dashboard |
| `GET /api/health` | health check del target group. Devuelve 503 si hay una falla `unhealthy` inyectada o si la tarea está drenando |
| `GET /api/hit` | la petición que se mide. Aplica la inyección de fallos activa, registra y responde quién atendió |
| `GET /api/stats` | vista global: contadores, serie por minuto, últimas peticiones, estado de inyección de fallos, pesos |
| `GET /api/config` | bootstrap del dashboard: paleta, identidad, capacidades |
| `GET /api/whoami` | identidad detallada de la tarea |
| `GET /api/weights` | pesos leídos del listener. En AWS lee la *production listener rule* que ECS reescribe (Terraform le pasa `LISTENER_ARN` + permiso `DescribeRules`); en local refleja el mini-ALB. Como los roles rotan, identifica la canary por el menor peso |
| `GET/POST/DELETE /api/chaos` | inyección de fallos |
| `POST /api/reset` | limpia los contadores |
| `GET /metrics` | texto estilo Prometheus, por tarea |

### Identidad de la tarea

Lee `ECS_CONTAINER_METADATA_URI_V4` para saber su task ID, familia, revisión y
zona. Reintenta unas veces porque el endpoint tarda un momento en estar listo al
arrancar, y si no existe cae al hostname. Así el dashboard puede decirte
literalmente **qué contenedor** te respondió.

### Apagado ordenado

Al recibir `SIGTERM`, la tarea marca `draining`: `/api/health` empieza a devolver
503 mientras **sigue atendiendo tráfico real** durante `SHUTDOWN_GRACE_MS` (12 s
por defecto). Eso le da tiempo al ALB a sacarla de rotación sin cortar peticiones
en vuelo. `stopTimeout` de la task definition es 20 s, holgado sobre esos 12.

---

## 4. Modelo de datos

Una sola tabla DynamoDB, compartida por **todas** las tareas de **ambas** versiones.
Es lo que convierte el dashboard en una vista global en lugar de los contadores
privados de un contenedor.

| pk | sk | Contenido |
|---|---|---|
| `AGG` | `<track>#<version>` | contadores acumulados: hits, errors, latencySum |
| `TS` | `<minuto>#<track>` | cubos por minuto para el gráfico (TTL 3 h) |
| `HIT` | `<epochMs>#<rand>` | últimas peticiones para el flujo en vivo (TTL 30 min) |
| `CHAOS` | `<track>` | estado de inyección de fallos |

Detalles de diseño:

- Las claves de orden van **rellenas con ceros** (`000029830906#canary`) para que el
  orden lexicográfico de DynamoDB coincida con el numérico. Así la serie temporal
  se lee con un `Query ... BETWEEN` en una sola llamada.
- Los contadores usan `ADD`, que es atómico: varias tareas suman sin pisarse.
- `TS` y `HIT` tienen **TTL**, así que la tabla no crece sin límite en una demo larga.
- Las escrituras son **fire and forget**: la respuesta no espera a DynamoDB.
- `CHAOS` se **consulta cada 3 segundos** por cada tarea y se cachea en memoria, de
  modo que la ruta caliente no toca la base de datos.

### Modo degradado

El store es un **compuesto**: escribe en DynamoDB y en una copia en memoria.
Si DynamoDB no responde (tabla borrada, permiso faltante, throttling), las lecturas
caen a los contadores locales y el dashboard muestra `dynamodb (degradado)` en vez
de quedarse en blanco a mitad de una charla.

---

## 5. Métricas y alarmas

### EMF, sin agente ni permisos extra

La app escribe en stdout líneas en formato **Embedded Metric Format**. CloudWatch
Logs las convierte en métricas sin agente y sin necesidad de
`cloudwatch:PutMetricData`:

```json
{
  "_aws": {
    "Timestamp": 1770000000000,
    "CloudWatchMetrics": [{
      "Namespace": "CanaryLab",
      "Dimensions": [["Track", "Version"], ["Track"]],
      "Metrics": [
        { "Name": "RequestCount", "Unit": "Count" },
        { "Name": "ErrorCount", "Unit": "Count" },
        { "Name": "LatencyMs", "Unit": "Milliseconds" }
      ]
    }]
  },
  "Track": "canary",
  "Version": "2.0.0",
  "RequestCount": 42,
  "ErrorCount": 3,
  "LatencyMs": [12, 15, 1203]
}
```

Se emite cada 10 segundos con los valores agregados, no una línea por petición.

### Las cuatro alarmas que deciden el rollback

Como ECS alterna en cada deploy cuál target group (`primary`/`alternate`) corre
la revisión nueva, no alcanza con vigilar uno solo. Cada señal se mide en
**ambos** target groups y se combina en una **alarma compuesta**
(`ALARM(primary) OR ALARM(alternate)`). Esas compuestas —más la de tasa de error
sobre EMF— son las que `aws_ecs_service.app.alarms.alarm_names` lista, así que
**ECS mismo las vigila** durante el rollout (`DescribeAlarms` interno) y revierte
el tráfico si alguna pasa a `ALARM`; no hay ningún script haciendo polling.

| Alarma (compuesta salvo la de EMF) | Métrica por target group | Dispara con |
|---|---|---|
| `<proyecto>-canary-5xx` | `HTTPCode_Target_5XX_Count` (Sum) | ≥ 3 en un periodo |
| `<proyecto>-canary-latency` | `TargetResponseTime` (p95) | > 1 s |
| `<proyecto>-canary-unhealthy` | `UnHealthyHostCount` (Max) | ≥ 1 |
| `<proyecto>-canary-error-rate` | math sobre EMF: `100 * errors / requests` | > 5% |

- Vigilar ambos target groups implica que una regresión en la revisión estable
  —no solo en la canary— también dispara el rollback, que de todos modos es
  deseable.
- `treatMissingData: notBreaching` en todas: **sin tráfico en un target group no
  hay fallo**, y al principio del rollout no hay datos.
- `evaluation_periods = 1` y `period = 60` para que una demo en vivo reaccione
  rápido. En producción querrás 2 o 3 periodos para no reaccionar al ruido.
- La de error rate viene de las métricas de la app, así que atrapa fallos que nunca
  llegan al ALB como 5xx.
- Importante: **si una alarma ya está en `ALARM` al arrancar el rollout, ECS la
  ignora** durante ese despliegue (para no bloquear un fix de un fallo previo).
  Por eso `canary-deploy.sh` limpia el estado de las alarmas antes de empezar.

### Por qué el contenedor no tiene health check propio

Deliberado. Si la task definition llevara un `healthCheck`, ECS mataría al
contenedor enfermo antes de que la alarma alcanzara a dispararse, y la demo del
rollback nunca ocurriría: verías tareas reciclándose en bucle. Aquí la salud la
juzga **el target group**, que es también quien alimenta las alarmas.

### El dashboard de CloudWatch

`infra/terraform/monitoring.tf` crea `<proyecto>-canary`. Un encabezado de texto
explica cómo leerlo, y arriba van las vistas *lógicas* (por versión), abajo las
*físicas* (por target group, cuyo rol de estable/canary rota entre deploys):

| Widget | Qué muestra |
|---|---|
| Canary traffic shift | el porcentaje de tráfico de la revisión canary, en vivo |
| Requests by APP_VERSION (EMF) | solicitudes por `APP_VERSION` — quién es cada revisión |
| Errors by APP_VERSION (EMF) | errores por `APP_VERSION` |
| 5xx rate per target group (%) | tasa de 5xx por target group, comparable con split desigual |
| 5xx counts: target + ALB-level | 5xx de target + `HTTPCode_ELB_5XX` + errores de conexión |
| Latency p50/p95/p99 | latencia por target group, con la línea del presupuesto |
| Healthy / unhealthy targets | targets sanos/enfermos (min/max por minuto) |
| Canary rollback triggers | estado de las alarmas, de un vistazo |

Los dos widgets por `APP_VERSION` usan `SEARCH` acotado con `SORT(..., MAX, DESC,
4)` para mostrar solo las versiones más activas, no todas las que alguna vez se
desplegaron.

El primero responde la pregunta que más se hace en una demo: *¿cuánto tráfico
está recibiendo la revisión canary ahora mismo?* Como `primary`/`alternate`
rotan de rol, no se puede asumir que la canary es siempre `alternate`; se la
identifica por el **menor tráfico** con **metric math** sobre el `RequestCount`
de cada target group:

```
primary_requests   = FILL(RequestCount(TargetGroup=primary), 0)     ; visible=false
alternate_requests = FILL(RequestCount(TargetGroup=alternate), 0)   ; visible=false
canary_requests    = MIN(primary_requests, alternate_requests)      ; el de menor tráfico
stable_requests    = MAX(primary_requests, alternate_requests)
canary_pct         = 100 * canary_requests / (stable_requests + canary_requests)
```

`FILL(..., 0)` evita huecos cuando un periodo no tiene datos, y el área apilada
capada a 0-100 hace que el relleno sea el % de la canary y el espacio de arriba,
el de la estable. Es el mismo criterio (por magnitud, no por ARN) que aplica
`app/src/alb-weights.js` para el dashboard de la app.

---

## 6. Seguridad y permisos

### Red: creada o referenciada

`infra/terraform/vpc.tf` decide con un único interruptor, `var.vpc_id`:

```
vpc_id vacío (por defecto)  -> crea aws_vpc + aws_subnet (una por AZ, hasta
                                vpc_az_count) + aws_internet_gateway +
                                aws_route_table con ruta 0.0.0.0/0 al IGW
vpc_id con un valor         -> data "aws_vpc" y data "aws_subnet" referencian
                                lo que ya existe; no se crea nada de red
```

El resto del stack no sabe ni le importa cuál de los dos caminos se tomó: todo
lee `local.vpc_id` y `local.public_subnet_ids`, resueltos en ese mismo archivo.

La VPC creada es deliberadamente mínima (sin NAT, sin subnets privadas), así
que las tareas necesitan IP pública para bajar la imagen; por eso
`assign_public_ip` queda forzado a `true` en ese camino sin importar lo que
digas en `tfvars`.

### Security groups

```
ALB SG      ingress  80        desde allowed_ingress_cidrs
            egress   8080      hacia el SG de las tareas
Task SG     ingress  8080      solo desde el SG del ALB
            egress   todo      ECR, CloudWatch Logs, DynamoDB, control plane de ECS
```

Las tareas no son alcanzables directamente desde internet aunque tengan IP pública:
el único ingress permitido viene del balanceador.

### Los tres roles de ECS

| Rol | Quién lo usa | Para qué |
|---|---|---|
| execution role | el agente de ECS | bajar la imagen de ECR y escribir logs |
| task role | la aplicación | DynamoDB sobre su tabla |
| ecs infrastructure role | ECS mismo (`ecs.amazonaws.com`) | crear/modificar el target group `alternate` y reescribir la *production listener rule* durante un rollout canary. Sin este rol, `deployment_configuration.strategy = "CANARY"` no puede mover tráfico |

Los dos primeros llevan una condición `aws:SourceAccount` en la política de
confianza, que cierra el problema del *confused deputy*. El tercero usa la
policy administrada de AWS `AmazonECSInfrastructureRolePolicyForLoadBalancers`
(no hace falta escribirla a mano).

El permiso de la tabla está limitado a **ese** ARN.

---

## 7. La imagen y su orden

El URI de la imagen se **compone**, nunca se busca:

```
<account>.dkr.ecr.<region>.amazonaws.com/<proyecto>-app:<tag>
```

Por eso `terraform plan` funciona en una cuenta limpia, sin que la imagen exista
todavía.

El orden recomendado es **registro, luego infraestructura**, porque un servicio de
ECS no arranca sin algo que correr:

```
build-push.sh --tag v1     crea el repositorio si falta y sube la imagen
terraform apply            crea el resto y las tareas arrancan sanas de primera
```

Si prefieres que Terraform sea dueño del repositorio, pon
`create_ecr_repository = true`. El URI se calcula igual, así que no aparece
ninguna dependencia circular.

**Arquitectura del binario.** `build-push.sh` construye con `docker buildx` para
`linux/amd64,linux/arm64` por defecto y sube un único manifest multi-arquitectura,
así el tag sirve tanto si `cpu_architecture` es `X86_64` (el default de Fargate)
como `ARM64`, sin que importe en qué máquina se construyó la imagen. Si pasás
`--platform` con una sola arquitectura para acelerar el build, esa arquitectura
tiene que coincidir con `cpu_architecture` en `terraform.tfvars`: si no
coinciden, la tarea muere con un error de formato de ejecutable.

---

## 8. El ALB de juguete

`local/mini-alb/server.js` son unas 250 líneas de Node sin dependencias que
imitan las partes de un ALB con pesos manuales. Es intencionalmente el modelo
*anterior* a la migración a la estrategia canary nativa de ECS
(sección 1): sigue siendo la forma más directa de enseñar el mecanismo de
pesos en sí, sin la orquestación de ECS por delante.

- reenvío ponderado en la regla por defecto,
- las mismas rutas forzadas (`?track=`, `X-Canary`),
- health checks activos con umbrales de 2 y 2,
- **saca de rotación los targets enfermos**, y devuelve 503 cuando no queda ninguno,
- un plano de control (`POST /_alb/weights`) que hace el papel de `modify-listener`.

Gracias a eso el flujo canary completo se ensaya con `docker compose up`, y CI lo
verifica en cada pull request sin tocar AWS. No es un ALB: no hay LCUs, ni
stickiness, ni WAF, ni TLS. Es suficiente para que el comportamiento que enseñas
sea el mismo.

---

## 9. El contrato entre Terraform y los scripts

Terraform expone una única salida, `canary_env`, con todo lo que los scripts
necesitan:

```
CANARY_REGION              CANARY_TG_PRIMARY        CANARY_ALARM_5XX
CANARY_PROJECT             CANARY_TG_ALTERNATE      CANARY_ALARM_LATENCY
CANARY_CLUSTER             CANARY_SERVICE           CANARY_ALARM_UNHEALTHY
CANARY_ALB_DNS             CANARY_TASKDEF_FAMILY     CANARY_ALARM_ERRORRATE
CANARY_ALB_ARN             CANARY_ECR_REPO          CANARY_CONTAINER_NAME
CANARY_LISTENER_ARN        CANARY_ECR_URI           CANARY_CONTAINER_PORT
CANARY_PRODUCTION_RULE_ARN CANARY_TABLE
                           CANARY_LOG_GROUP
```

`scripts/load-env.sh` la vuelca a `.canary.env`, que el resto de los scripts
sourcea. Esa indirección es la razón de que `canary-deploy.sh`, `rollback.sh`
y `status.sh` no necesiten saber nada de Terraform: solo leen variables de
entorno.

Un solo servicio (`CANARY_SERVICE`), una sola familia de task definitions
(`CANARY_TASKDEF_FAMILY`) — el diseño anterior a esta migración tenía un par de
cada uno (`_STABLE`/`_CANARY`). `CANARY_PRODUCTION_RULE_ARN` es nuevo: es la
listener rule que `deployment_configuration.load_balancer.advanced_configuration`
reescribe durante un rollout, y la que `weights.sh`/`status.sh` consultan de
solo lectura para saber a qué target group apunta la producción ahora mismo.

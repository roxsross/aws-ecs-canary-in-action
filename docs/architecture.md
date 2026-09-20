# Arquitectura a fondo

Cómo está armado el laboratorio y por qué cada pieza está donde está.

---

## 1. El mecanismo canary

Un listener de ALB puede reenviar a **varios target groups con pesos**. El reparto
se calcula por petición, de forma probabilística:

```
regla por defecto del listener :80
  forward
    ├── target group stable  weight 95
    └── target group canary  weight  5
```

Los pesos son **relativos**, no porcentajes: `95/5` y `19/1` producen el mismo
reparto. `scripts/weights.sh --canary 5` normaliza a 100 para que sea legible.

Mover tráfico es una sola llamada:

```bash
aws elbv2 modify-listener --listener-arn "$ARN" --default-actions '[{
  "Type": "forward",
  "ForwardConfig": {
    "TargetGroups": [
      { "TargetGroupArn": "...stable", "Weight": 75 },
      { "TargetGroupArn": "...canary", "Weight": 25 }
    ],
    "TargetGroupStickinessConfig": { "Enabled": false }
  }
}]'
```

Consecuencias que importan:

- **El rollback es instantáneo.** No baja imágenes ni arranca tareas: reescribe dos
  números. Tarda lo que tarda una llamada a la API.
- **Sin stickiness**, a propósito. Con sesiones pegajosas un usuario se quedaría
  atrapado en la canary rota. Para un laboratorio queremos que cada petición sea
  un sorteo nuevo.
- **Un peso mayor que cero sobre un target group vacío devuelve 503** para esa
  fracción del tráfico. Por eso `canary-deploy.sh` espera targets sanos *antes* de
  mover el primer peso, y `weights.sh` avisa si vas a disparar en el pie.

### Rutas forzadas

Cuatro reglas del listener permiten mirar una versión concreta sin tocar los pesos:

| Prioridad | Condición | Destino |
|---|---|---|
| 10 | query string `track=canary` | target group canary |
| 11 | query string `track=stable` | target group stable |
| 20 | header `X-Canary: always` | target group canary |
| 21 | header `X-Canary: never` | target group stable |

De esto viven los enlaces "ver solo esta versión" del dashboard, y también
`chaos.sh`: para que la escritura llegue a una tarea de la versión correcta, hace
la petición con `?track=`.

---

## 2. Flujo de una petición

```
navegador
  └─> ALB :80
        └─> ¿coincide alguna regla forzada?
              sí -> target group indicado
              no  -> sorteo por pesos
                      └─> tarea Fargate (:8080)
                            ├─ aplica chaos: latencia y/o 500
                            ├─ escribe el hit en DynamoDB (async)
                            ├─ suma al buffer EMF
                            └─ responde con X-Track, X-Version, X-Task-Id
```

Las cabeceras de identidad son el truco que hace todo observable: el navegador, el
generador de carga y CI cuentan el reparto leyendo `X-Track`, sin necesitar acceso
a AWS.

---

## 3. La aplicación

Node 22 con Express, sin build step y sin dependencias de frontend.

### Endpoints

| Ruta | Para qué |
|---|---|
| `GET /` | dashboard |
| `GET /api/health` | health check del target group. Devuelve 503 si hay chaos `unhealthy` o si la tarea está drenando |
| `GET /api/hit` | la petición que se mide. Aplica el chaos, registra y responde quién atendió |
| `GET /api/stats` | vista global: contadores, serie por minuto, últimas peticiones, chaos, pesos |
| `GET /api/config` | bootstrap del dashboard: paleta, identidad, capacidades |
| `GET /api/whoami` | identidad detallada de la tarea |
| `GET /api/weights` | pesos reales leídos del listener |
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

El store real es un **compuesto**: escribe en DynamoDB y en una copia en memoria.
Si DynamoDB no responde (tabla borrada, permiso faltante, throttling), las lecturas
caen a los contadores locales y el dashboard muestra `dynamodb (degradado)` en vez
de quedarse en blanco a mitad de una charla.

---

## 5. Métricas y alarmas

### EMF, sin agente ni permisos extra

La app escribe en stdout líneas en formato **Embedded Metric Format**. CloudWatch
Logs las convierte en métricas reales sin agente y sin necesidad de
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

Todas apuntan **solo al target group de la canary**.

| Alarma | Métrica | Dispara con |
|---|---|---|
| `<proyecto>-canary-5xx` | `HTTPCode_Target_5XX_Count` (Sum) | ≥ 3 en un periodo |
| `<proyecto>-canary-latency` | `TargetResponseTime` (p95) | > 1 s |
| `<proyecto>-canary-unhealthy` | `UnHealthyHostCount` (Max) | ≥ 1 |
| `<proyecto>-canary-error-rate` | math sobre EMF: `100 * errors / requests` | > 5% |

- `treatMissingData: notBreaching` en las cuatro: **sin tráfico en la canary no hay
  fallo**, y al principio del rollout no hay datos.
- `evaluation_periods = 1` y `period = 60` para que una demo en vivo reaccione
  rápido. En producción querrás 2 o 3 periodos para no reaccionar al ruido.
- La de error rate viene de las métricas de la app, así que atrapa fallos que nunca
  llegan al ALB como 5xx.

### Por qué el contenedor no tiene health check propio

Deliberado. Si la task definition llevara un `healthCheck`, ECS mataría al
contenedor enfermo antes de que la alarma alcanzara a dispararse, y la demo del
rollback nunca ocurriría: verías tareas reciclándose en bucle. Aquí la salud la
juzga **el target group**, que es también quien alimenta las alarmas.

### El dashboard de CloudWatch

`infra/terraform/monitoring.tf` crea `<proyecto>-canary`, con siete widgets:

| Widget | Qué muestra |
|---|---|
| Traffic distribution | el porcentaje de tráfico de cada track, en vivo |
| Requests per target group | volumen absoluto (`RequestCount`) por track |
| 5xx per target group | errores del servidor por track, con la línea de la alarma |
| p95 latency per target group | latencia por track, con la línea del presupuesto |
| Healthy targets | targets sanos/enfermos por track |
| Application metrics (EMF) | `RequestCount`/`ErrorCount` desde las métricas propias de la app |
| Canary rollback triggers | estado de las cuatro alarmas, de un vistazo |

El primero es el que responde la pregunta que más se hace en una demo: *¿cuánto
tráfico está recibiendo la canary ahora mismo?* Se calcula con **metric math**,
no leyendo el peso del listener (que vive en el ALB, no en CloudWatch), sino a
partir del `RequestCount` real de cada target group:

```
stable_requests = RequestCount(TargetGroup=stable)   ; visible=false, es la métrica base
canary_requests = RequestCount(TargetGroup=canary)   ; visible=false, es la métrica base
canary_pct = 100 * canary_requests / (stable_requests + canary_requests)
stable_pct = 100 * stable_requests / (stable_requests + canary_requests)
```

Las métricas base van con `visible: false` porque solo existen para alimentar la
expresión; lo único que se dibuja son las dos líneas de porcentaje. Mismo patrón
que ya usa la alarma `canary-error-rate`, solo que aquí el resultado es para
mirar, no para disparar un rollback.

---

## 6. Seguridad y permisos

### Red: creada o referenciada (solo Terraform)

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
CloudFormation y CDK todavía no tienen este modo: siempre esperan una VPC
existente, la que se pasa por parámetro o contexto.

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

### Los dos roles de ECS

| Rol | Quién lo usa | Para qué |
|---|---|---|
| execution role | el agente de ECS | bajar la imagen de ECR y escribir logs |
| task role | la aplicación | DynamoDB sobre su tabla, y leer las reglas del listener |

Ambos llevan una condición `aws:SourceAccount` en la política de confianza, que
cierra el problema del *confused deputy*.

El permiso de la tabla está limitado a **ese** ARN. El de
`elasticloadbalancing:DescribeRules` va con `Resource: "*"` porque esa acción no
admite permisos por recurso; es solo lectura y es opcional
(`grant_listener_read = false` lo quita, y el dashboard pasa a estimar el reparto).

---

## 7. La imagen y su orden

El URI de la imagen se **compone**, nunca se busca:

```
<account>.dkr.ecr.<region>.amazonaws.com/<proyecto>-app:<tag>
```

Por eso `terraform plan`, `cdk synth` y la validación de CloudFormation funcionan
en una cuenta limpia, sin que la imagen exista todavía.

El orden recomendado es **registro, luego infraestructura**, porque un servicio de
ECS no arranca sin algo que correr:

```
build-push.sh --tag v1     crea el repositorio si falta y sube la imagen
terraform apply            crea el resto y las tareas arrancan sanas de primera
```

Si prefieres que la IaC sea dueña del repositorio, pon `create_ecr_repository = true`
(o `CreateEcrRepository=true`, o `-c createEcrRepository=true`). El URI se calcula
igual, así que no aparece ninguna dependencia circular.

**Arquitectura del binario.** Fargate espera por defecto `X86_64`. Como mucha gente
construye en Apple silicon, `build-push.sh` fuerza `--platform linux/amd64`. Si
quieres tareas ARM, cambia `cpu_architecture` a `ARM64` **y** construye con
`--platform linux/arm64`. Si los dos no coinciden, la tarea muere con un error de
formato de ejecutable.

---

## 8. El ALB de juguete

`local/mini-alb/server.js` son unas 250 líneas de Node sin dependencias que imitan
las partes del ALB que este laboratorio usa:

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

## 9. El contrato entre IaC y scripts

Los tres sabores exponen las mismas salidas, y `scripts/load-env.sh` las traduce a
un único conjunto de variables:

```
CANARY_REGION           CANARY_TG_STABLE        CANARY_ALARM_5XX
CANARY_PROJECT          CANARY_TG_CANARY        CANARY_ALARM_LATENCY
CANARY_CLUSTER          CANARY_SVC_STABLE       CANARY_ALARM_UNHEALTHY
CANARY_ALB_DNS          CANARY_SVC_CANARY       CANARY_ALARM_ERRORRATE
CANARY_ALB_ARN          CANARY_TASKDEF_STABLE   CANARY_ECR_REPO
CANARY_LISTENER_ARN     CANARY_TASKDEF_CANARY   CANARY_ECR_URI
CANARY_TABLE            CANARY_LOG_GROUP        CANARY_CONTAINER_NAME
                                                CANARY_CONTAINER_PORT
```

Terraform los entrega en la salida `canary_env`; CloudFormation y CDK como salidas
individuales en CamelCase (CloudFormation no admite guiones bajos en los IDs
lógicos), y el script las mapea con una tabla explícita.

Esa indirección es la razón de que `canary-deploy.sh`, `rollback.sh` y `status.sh`
no sepan ni les importe con qué herramienta desplegaste.

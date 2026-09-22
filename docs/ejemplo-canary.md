# Ejemplo guiado: estable → canary → latencia

Un recorrido completo del flujo, primero **en local** (sin cuenta de AWS, para
ensayar) y después **en AWS real** con Terraform. En los tres pasos hacemos lo
mismo: levantar una versión estable, meter una canary, y luego inyectarle
latencia para ver qué pasa.

La diferencia de fondo entre los dos entornos:

| | Local (`local/`, docker compose) | AWS real (`infra/terraform`) |
|---|---|---|
| Quién reparte el tráfico | vos, a mano, con `weights.sh` | ECS, solo, con su estrategia canary nativa |
| Estable vs canary | dos servicios separados (`TRACK`) | una sola versión nueva (`APP_VERSION`) por rollout |
| Rollback ante latencia alta | manual (volvés el peso a 0) | **automático** (alarma de CloudWatch → ECS revierte) |
| Dónde ves el reparto real | dashboard de la app (`:8080`) | dashboard de CloudWatch |

> Requisitos: `docker` para local; `terraform`, `aws` y `jq` para AWS. Casi
> todo tiene su atajo en `make help`.

---

## Parte 1 — Local (ensayo, sin AWS)

Acá el "estable" y el "canary" son dos contenedores distintos que ya arrancan a
la vez. Vos movés el peso del mini-ALB para simular el rollout.

### 1.1 Levantar la versión estable al 100%

```bash
make local
```

Esto sube: mini-ALB en `http://localhost:8080`, estable `v1.0.0` (`:8081`),
canary `v2.0.0` (`:8082`) y un DynamoDB local. El mini-ALB arranca en
`stable=100 canary=0`, así que todo el tráfico va a la estable.

Comprobalo:

```bash
./scripts/weights.sh --target local
./scripts/traffic-gen.sh --url http://localhost:8080 --requests 100 --concurrency 8
```

Esperado: `stable 100% / canary 0%`. Abrí `http://localhost:8080` para verlo en
vivo.

### 1.2 Meter la canary (mover 10% del tráfico)

```bash
./scripts/weights.sh --target local --canary 10
./scripts/traffic-gen.sh --url http://localhost:8080 --requests 200 --concurrency 8
```

Esperado: cerca de `stable 90% / canary 10%` (con 200 requests el número real
baila un poco). En el dashboard la barra "distribución configurada (ALB)" ahora
muestra 90/10.

### 1.3 Inyectar latencia en la canary

```bash
./scripts/chaos.sh --url http://localhost:8080 --track canary --latency 800
./scripts/traffic-gen.sh --url http://localhost:8080 --requests 200 --concurrency 8
```

Esperado: la latencia media sube, pero **solo** en las respuestas de la canary
(la estable sigue rápida). En el dashboard, la tarjeta de la versión canary
muestra la latencia alta.

En local **no hay rollback automático** (el mini-ALB no tiene alarmas). El
rollback lo hacés vos:

```bash
./scripts/chaos.sh --url http://localhost:8080 --clear
./scripts/weights.sh --target local --canary 0
```

### 1.4 Bajar el laboratorio

```bash
make local-down
```

---

## Parte 2 — AWS real (con Terraform)

Acá ECS orquesta el canary. No movés pesos a mano: disparás el rollout y ECS
desplaza el tráfico, hace bake, vigila las alarmas y revierte solo si algo se
rompe.

> El ALB y las tareas de Fargate cobran por hora. Al final está el
> `terraform destroy`.

### 2.1 Publicar la imagen y lanzar la versión estable

La primera imagen tiene que existir antes de crear el servicio:

```bash
make push TAG=v1
```

Después, creá la infraestructura. El primer `apply` deja corriendo la versión
estable inicial (`image_tag=v1`, `app_version=1.0.0`, `desired_count=2`):

```bash
cd infra/terraform && terraform apply    # o: make tf-apply
```

`make tf-apply` además corre `load-env.sh` y deja `.canary.env` listo para los
scripts. Si corriste `terraform apply` a mano, generalo vos:

```bash
./scripts/load-env.sh          # o: make env
./scripts/status.sh            # o: make status
```

`status.sh` muestra `rolloutState=COMPLETED`, `primary 100% / alternate 0%` y
las 4 alarmas en `OK`. Abrí los dos dashboards:

```bash
terraform output app_url                    # dashboard de la app
terraform output cloudwatch_dashboard_url   # dashboard de CloudWatch
```

### 2.2 Meter la canary (rollout nativo de ECS)

Disparás un rollout a una versión nueva. Reusamos la misma imagen y solo
subimos el `APP_VERSION` reportado (para un cambio de código real sería
`make push TAG=v2` y `--tag v2`):

```bash
./scripts/canary-deploy.sh --tag v1 --version 1.1.0
```

A partir de acá ECS maneja todo, en este orden:

1. crea la revisión nueva ("green") y espera a que esté sana,
2. desplaza el `canary_percent` (10%) del tráfico hacia ella,
3. hace bake `canary_bake_time_in_minutes` (5 min) vigilando las alarmas,
4. si todo sigue en `OK`, manda el 100% del tráfico,
5. hace bake `bake_time_in_minutes` (5 min) más y termina el rollout.

Miralo en vivo (en otra terminal):

```bash
./scripts/status.sh --watch
```

Durante el paso 2-3 vas a ver `alternate 10%` (o `primary 10%`: el rol físico
se alterna en cada deploy, por eso el dashboard identifica la canary por el
**menor tráfico**, no por el nombre del target group). En el dashboard de
CloudWatch, el widget "Canary traffic shift" muestra el ~10%, y "Requests by
APP_VERSION" muestra `v1.1.0` apareciendo junto a `v1.0.0`.

Si no la rompés, en ~10-13 min el rollout llega a `COMPLETED` y `v1.1.0` queda
sirviendo el 100%. Esa es la ruta feliz.

### 2.3 Inyectar latencia y ver el rollback automático

Para ver el rollback, lanzá un rollout y metele latencia mientras está en la
fase de bake:

```bash
# terminal 1: arrancá el rollout
./scripts/canary-deploy.sh --tag v1 --version 1.1.0 --yes

# terminal 2: en cuanto veas alternate/primary en 10%, inyectá latencia
./scripts/chaos.sh --latency 1500
./scripts/traffic-gen.sh --rps 15 --duration 120
```

`alarm_latency_threshold_seconds` es 1 s, así que 1500 ms lo supera. En AWS la
inyección aplica a **todas** las tareas (todas reportan `track=stable`), pero
alcanza con que el target group de la revisión nueva supere el umbral: la
alarma `canary-lab-canary-latency` pasa a `ALARM` y **ECS revierte solo** — el
tráfico vuelve a la revisión anterior y la nueva se descarta.

Confirmá el rollback:

```bash
./scripts/status.sh
```

Vas a ver la alarma que disparó y el `rolloutState` terminando con el tráfico
de vuelta en la versión previa. Limpiá el fallo:

```bash
./scripts/chaos.sh --clear
```

> Si preferís cortar un rollout sano por tu cuenta, o revertir uno que ya llegó
> a `COMPLETED`, usá `./scripts/rollback.sh` (redeploya la revisión anterior
> por la misma estrategia canary).

### 2.4 Limpiar

```bash
cd infra/terraform && terraform destroy    # o: make tf-destroy
```

Si `build-push.sh` creó el repositorio de ECR (el flujo por defecto), borralo
aparte:

```bash
aws ecr delete-repository --repository-name canary-lab-app --force
```

---

## Qué mirar en cada dashboard

- **Dashboard de la app** (`app_url`): tráfico de prueba en vivo desde tu
  navegador. La sección "reparto de tráfico" lee los pesos reales del listener;
  las tarjetas de abajo muestran la versión estable y la canary con sus
  solicitudes, errores y latencia.
- **Dashboard de CloudWatch** (`cloudwatch_dashboard_url`): la fuente de verdad
  para decidir. El widget "Canary traffic shift" da el % del canary; "Requests
  by APP_VERSION" dice qué versión es cuál; los widgets de tasa (%) y de
  latencia p50/p95/p99 muestran si la canary está sana. El widget de alarmas al
  final es el que dispara el rollback.

## Ver también

- [operations.md](operations.md) — referencia de todos los comandos y pruebas.
- [canary-playbook.md](canary-playbook.md) — runbook paso a paso y qué hacer
  cuando algo va mal.
- [architecture.md](architecture.md) — el diseño y por qué es así.

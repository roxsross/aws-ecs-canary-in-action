# Runbook: operar un despliegue canary

Guion para ejecutar un rollout, decidir si sigue o se corta, y qué hacer cuando se
corta. Usa la estrategia de canary nativa de Amazon ECS: un solo servicio, y
ECS mismo mueve el tráfico, hornea y revierte según las alarmas de
`infra/terraform/ecs.tf`. Los scripts de este repo solo disparan el rollout y
leen su estado; no hay pasos manuales que ejecutar.

---

## Antes de empezar

```bash
./scripts/status.sh
```

Cuatro cosas que deben estar en orden:

- [ ] **`rolloutState` está en `COMPLETED`.** Si dice `IN_PROGRESS`, ya hay un
      despliegue en marcha.
- [ ] **El servicio tiene todas sus tareas sanas.** `running=2/2`, no `1/2`.
- [ ] **Ninguna alarma en `ALARM`.** Si alguna quedó así de una demo anterior, ECS
      la ignora al arrancar el próximo rollout — el sistema entero pierde su red
      de seguridad sin avisar.
- [ ] **Sin chaos activo.** `./scripts/chaos.sh --show` debe salir todo en cero.

Y ten a mano, en otra terminal:

```bash
make watch
```

---

## El rollout

```bash
./scripts/canary-deploy.sh --tag v2
```

### Qué pasa, todo dentro de ECS

| Fase | Qué hace | Cuánto tarda | Si falla |
|---|---|---|---|
| 1 | registra la task definition nueva y llama `update-service --force-new-deployment` | segundos | nada que revertir, el rollout ni arrancó |
| 2 | ECS crea la revisión nueva, la registra en el target group `alternate` y espera targets sanos | 1 a 3 min | ECS marca el deployment `FAILED`, nada tocó producción |
| 3 | ECS mueve `canary_percent`% del tráfico a la revisión nueva y hornea `canary_bake_time_in_minutes`, vigilando las alarmas | minutos, según `terraform.tfvars` | ECS revierte el tráfico a la revisión vieja solo |
| 4 | si las alarmas siguen `OK`, ECS mueve el resto del tráfico de una vez | segundos | igual que arriba |
| 5 | ECS hornea `bake_time_in_minutes` más con ambas revisiones corriendo, luego termina la vieja | minutos | rollback instantáneo posible hasta que termine |

Los tiempos exactos son `var.canary_percent`, `var.canary_bake_time_in_minutes` y
`var.bake_time_in_minutes` en `infra/terraform/terraform.tfvars` — no hay flags
de `--steps`/`--bake` en el script, porque ya no hay pasos que este repo
controle: son parte de la infraestructura, y cambiarlos implica un
`terraform apply`.

### Qué mirar mientras hornea

En el dashboard, comparando **`primary` contra `alternate`**:

| Señal | Bien | Sospechoso | Corta |
|---|---|---|---|
| Tasa de error de `alternate` | igual que `primary` | el doble | > 5%, o cualquier 5xx que `primary` no tenga |
| Latencia media de `alternate` | ±20% de `primary` | 2× | > 1 s p95, el presupuesto de la alarma |
| Targets sanos de `alternate` | estables | oscilan | bajan a 0 |
| Reparto observado | avanza hacia `canary_percent` y después a 100% | se queda corto | `alternate` no recibe nada estando en la fase canary |

La regla que de verdad importa: **comparar contra la revisión vieja en el mismo
momento**, no contra el histórico. Si las dos empeoran a la vez, el problema no
es tu release.

### Decidir

- **Dejalo seguir** si ECS ya está avanzando solo y las métricas de `alternate`
  son indistinguibles de las de `primary`.
- **Cortalo a mano** si ves algo que las alarmas configuradas no van a atrapar
  (por ejemplo, una métrica de negocio). `./scripts/rollback.sh` en cualquier
  momento.
- El horneado normalmente no hace falta alargarlo a mano: si un pico aislado te
  preocupa, subí `canary_bake_time_in_minutes`/`bake_time_in_minutes` en
  `terraform.tfvars` y volvé a aplicar antes del próximo rollout.

---

## Cuando algo va mal

### ECS ya revirtió solo

Es el caso normal: alguna alarma pasó a `ALARM` y ECS movió el tráfico de
vuelta a la revisión vieja y marcó el deployment `FAILED`. **La revisión vieja
nunca dejó de correr**, así que los usuarios están en la última versión buena.

Averigua qué pasó:

```bash
./scripts/status.sh
aws logs tail /ecs/canary-lab --since 20m
aws cloudwatch describe-alarms --alarm-names canary-lab-canary-5xx \
  --query 'MetricAlarms[0].StateReason' --output text
```

### Revertir a mano, ya

```bash
./scripts/rollback.sh
```

Redeploya la task definition anterior a través de la misma estrategia canary
(así el propio rollback también se puede observar, con su propio target group
`alternate`), y espera a que ECS lo complete. Es seguro correrlo en cualquier
momento, incluso con un rollout en marcha (y desde CI, con
`gh workflow run rollback.yml`).

### La versión mala ya está en producción al 100%

Ocurre si el rollout llegó a `COMPLETED` y el problema apareció después.

```bash
./scripts/rollback.sh
# o, apuntando a una revisión específica:
./scripts/rollback.sh --to canary-lab-app:7
```

Sin `--to`, busca automáticamente la revisión anterior de la familia. Pide
confirmación antes de redeployar.

### El rollout se quedó a medias

Un runner de CI que muere, una terminal cerrada, la red que se cae:

```bash
./scripts/status.sh    # ¿qué dice rolloutState?
./scripts/rollback.sh  # si no está en COMPLETED, devuélvelo a un estado conocido
```

---

## La demo en vivo

Guion de unos 10 minutos.

**1. Presenta el estado (1 min)**

```bash
make status
```

Abre el dashboard. Señala las dos barras (`primary`/`alternate`) y que
`alternate` está en cero: no hay rollout en curso.

**2. Sube el ritmo de solicitudes de prueba (30 s)**

Lleva el slider a 15 por segundo. La distribución observada se estabiliza en
100% `primary`.

**3. Arranca un rollout (1 min)**

```bash
make push TAG=v2
./scripts/canary-deploy.sh --tag v2
```

En el dashboard aparece `alternate` con tráfico apenas ECS termina de sanar sus
tareas. Ahí se explica que **`canary_percent`% es lo que ECS decidió por
Terraform**, no algo que el operador mueva a mano — la variable está en
`terraform.tfvars`.

**4. Simula un incidente (3 min)**

En otra terminal, mientras el rollout está horneando:

```bash
./scripts/chaos.sh --break
```

La tira de solicitudes de prueba se llena de rojo. La tarjeta de `alternate` se
pone en rojo; la de `primary` sigue limpia. En un par de minutos las alarmas
pasan a `ALARM` y **ECS revierte el tráfico solo**, sin que nadie haya tocado
nada.

**5. Muestra el estado después (1 min)**

```bash
./scripts/status.sh
```

`rolloutState=FAILED`, tráfico de vuelta al 100% en `primary`. Aquí va la
frase: *el rollback lo hizo ECS solo, mirando las mismas alarmas de CloudWatch
que ves en el dashboard*.

**Para dejarlo limpio**

```bash
./scripts/chaos.sh --clear
```

---

## Ajustar para producción

Los valores por defecto están pensados para que una demo quepa en una charla.
Todos viven en `infra/terraform/terraform.tfvars` — cambiarlos implica
`terraform apply`, no un flag de script:

| Variable | Laboratorio | Producción | Por qué |
|---|---|---|---|
| `canary_percent` | 10% | 1-5% | arrancar chico donde el riesgo es mayor |
| `canary_bake_time_in_minutes` | 5 | 15-60 | ver un ciclo de tráfico real, no un pico |
| `bake_time_in_minutes` | 5 | 15-30 | ventana de rollback instantáneo tras el 100% |
| `alarm_evaluation_periods` | 1 | 2 o 3 | un periodo suelto es ruido |
| `deregistration_delay` | 10 s | 30 a 60 s | drenar de verdad las conexiones en vuelo |
| `alarm_latency_threshold_seconds` | 1 | tu SLO real | el presupuesto debe ser el tuyo |
| Notificaciones | ninguna | `alarm_sns_topic_arns` | que alguien se entere sin mirar |

Y lo que este laboratorio deliberadamente no hace, y producción sí necesita:

- **HTTPS** con ACM y redirección desde el 80.
- **Autenticación** delante de cualquier endpoint que modifique estado.
- **Subnets privadas** con NAT o VPC endpoints para las tareas.
- **Autoescalado** en el servicio.
- **Backend remoto** de Terraform con bloqueo de estado.
- **Lifecycle hooks** (`deployment_configuration.lifecycle_hook`, soportados por
  ECS) para correr pruebas automáticas contra `alternate` antes de que reciba
  tráfico real, si tu caso lo necesita.
- Métricas de negocio en el criterio de corte, no solo errores y latencia: una
  versión puede responder 200 a todo y estar rompiendo conversiones.

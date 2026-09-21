# Runbook: operar un despliegue canary

Guion para ejecutar un rollout, decidir si sigue o se corta, y qué hacer cuando se
corta. Sirve igual para la demo en vivo y para la versión adaptada a producción.

---

## Antes de empezar

```bash
./scripts/status.sh
```

Cinco cosas que deben estar en orden:

- [ ] **El reparto está en 100/0.** Si la canary ya tiene peso, alguien dejó un
      rollout a medias.
- [ ] **El servicio estable tiene todas sus tareas sanas.** `healthy=2/2`, no `1/2`.
- [ ] **Ninguna alarma en ALARM.** Una alarma vieja aborta el rollout en el primer paso.
- [ ] **Sin chaos activo.** `./scripts/chaos.sh --show` debe salir todo en cero.
- [ ] **La imagen existe.** `./scripts/canary-deploy.sh --tag vX --dry-run` lo comprueba.

Y ten a mano, en otra terminal:

```bash
make watch
```

---

## El rollout

```bash
./scripts/canary-deploy.sh --tag v2
```

### Qué pasa en cada fase

| Fase | Qué hace | Cuánto tarda | Si falla |
|---|---|---|---|
| 1 | registra la task definition de la canary | segundos | nada que revertir |
| 2 | escala la canary y espera targets sanos | 1 a 3 min | rollback: escala a 0. El tráfico nunca se movió |
| 3 | limpia el estado de las alarmas | segundos | continúa con un aviso |
| 4 | mueve los pesos paso a paso, horneando entre cada uno | `pasos × bake` | rollback: 100/0 y canary a 0 |
| 5 | promueve la estable a la imagen nueva | 1 a 3 min | rollback, con la canary todavía sirviendo |

Con los valores por defecto (`5,25,50,100` y 90 s de horneado) el rollout completo
son unos **8 a 12 minutos**.

### Qué mirar mientras hornea

En el dashboard, comparando **las dos versiones lado a lado**:

| Señal | Bien | Sospechoso | Corta |
|---|---|---|---|
| Tasa de error de la canary | igual que la estable | el doble | > 5%, o cualquier 5xx que la estable no tenga |
| Latencia media de la canary | ±20% de la estable | 2× | > 1 s p95, el presupuesto de la alarma |
| Targets sanos de la canary | estables | oscilan | bajan a 0 |
| Reparto observado | converge al peso configurado | se queda corto | la canary no recibe nada estando con peso |

La regla que de verdad importa: **comparar contra la estable en el mismo momento**,
no contra el histórico. Si las dos versiones empeoran a la vez, el problema no es
tu release.

### Decidir

- **Sigue** si las métricas de la canary son indistinguibles de las de la estable.
- **Alarga el horneado** si la canary solo se ve peor en un pico aislado. Vuelve a
  correr con `--bake 300` y menos pasos.
- **Corta** ante cualquier error que la estable no tenga. Un rollback cuesta
  segundos; una incidencia cuesta bastante más.

---

## Cuando algo va mal

### El script ya revirtió solo

Es el caso normal: alguna alarma pasó a ALARM y `canary-deploy.sh` movió el tráfico
a 100% estable y bajó la canary a cero. **La versión estable nunca se tocó**, así que
los usuarios están en la última versión buena.

Averigua qué pasó:

```bash
./scripts/status.sh
aws logs tail /ecs/canary-lab --since 20m --filter-pattern canary
aws cloudwatch describe-alarms --alarm-names canary-lab-canary-5xx \
  --query 'MetricAlarms[0].StateReason' --output text
```

Para hacer autopsia con la canary viva pero sin tráfico:

```bash
./scripts/rollback.sh --keep-canary
curl -s "http://$ALB/api/whoami?track=canary" | jq
```

### Revertir a mano, ya

```bash
./scripts/rollback.sh
```

Solo mueve pesos, así que tarda segundos. Es seguro correrlo en cualquier momento,
incluso con un rollout en marcha (y desde CI, con `gh workflow run rollback.yml`).

### La versión mala ya está en estable

Ocurre si el rollout promovió y el problema apareció después.

```bash
./scripts/rollback.sh --previous
```

Busca la revisión anterior de la familia, te dice qué imagen trae y pide
confirmación antes de redeployar. Esto sí es un despliegue, así que tarda un par de
minutos.

### El rollout se quedó a medias

Un runner de CI que muere, una terminal cerrada, la red que se cae:

```bash
./scripts/status.sh    # ¿qué peso tiene la canary?
./scripts/rollback.sh  # devuélvelo a un estado conocido
```

`canary-deploy.sh` atrapa `Ctrl-C` y revierte antes de salir, precisamente para no
dejar el reparto a medio camino.

---

## Promoción diferida

Cuando quieres que la versión nueva aguante tráfico completo un rato antes de
volverla oficial:

```bash
./scripts/canary-deploy.sh --tag v2 --no-promote
# la canary sirve el 100% del tráfico, la estable sigue en v1 sin recibir nada

# horas después, si todo bien:
./scripts/promote.sh --from-canary

# o si no:
./scripts/rollback.sh
```

Es la opción más segura, porque el camino de vuelta sigue siendo un cambio de pesos.
Cuesta el doble de tareas mientras dure.

---

## La demo en vivo

Guion de unos 10 minutos.

**1. Presenta el estado (1 min)**

```bash
make status
```

Abre el dashboard. Señala las tres barras y que la canary está en cero.

**2. Sube el ritmo de solicitudes de prueba (30 s)**

Lleva el slider a 15 por segundo. La distribución observada se estabiliza en 100/0.

**3. Mueve el tráfico a mano (2 min)**

```bash
./scripts/weights.sh --canary 5
```

La barra del ALB salta al instante; la observada tarda unas peticiones en seguirla.
Ahí se explica que **los pesos son probabilidad**. Sube a 25 y 50 y aparece la
segunda tarjeta con su propia latencia.

**4. Simula un incidente (3 min)**

```bash
./scripts/chaos.sh --break
```

La tira de solicitudes de prueba se llena de rojo solo en las marcas rosas. La
tarjeta de la canary se pone en rojo; la de la estable sigue limpia. Dos minutos
después las alarmas están en ALARM.

**5. Revierte (1 min)**

```bash
./scripts/rollback.sh
```

El rojo desaparece de inmediato. Aquí va la frase: *el rollback fueron dos números
en el listener, no un despliegue*.

**6. Ahora automático (3 min)**

```bash
./scripts/chaos.sh --clear
./scripts/canary-deploy.sh --tag v2 --steps 10,50,100 --bake 60
```

Déjalo llegar al 10% y en otra terminal:

```bash
./scripts/chaos.sh --break
```

El rollout detecta la alarma, revierte solo y sale con error. Nadie tocó nada.

**Para dejarlo limpio**

```bash
./scripts/chaos.sh --clear
./scripts/rollback.sh --yes
./scripts/weights.sh
```

---

## Ajustar para producción

Los valores por defecto están pensados para que una demo quepa en una charla. Para
uso real:

| Ajuste | Laboratorio | Producción | Por qué |
|---|---|---|---|
| `alarm_evaluation_periods` | 1 | 2 o 3 | un periodo suelto es ruido |
| `--bake` | 90 s | 10 a 30 min | ver un ciclo de tráfico real, no un pico |
| `--steps` | 5,25,50,100 | 1,5,10,25,50,100 | pasos pequeños al principio, donde el riesgo es mayor |
| `--canary-tasks` | 1 | proporcional al peso | una sola tarea al 50% se satura y falsea la latencia |
| `deregistration_delay` | 10 s | 30 a 60 s | drenar de verdad las conexiones en vuelo |
| `alarm_latency_threshold_seconds` | 1 | tu SLO real | el presupuesto debe ser el tuyo |
| Stickiness | apagada | según la app | si hay sesión en servidor, piénsalo |
| Notificaciones | ninguna | `alarm_sns_topic_arns` | que alguien se entere sin mirar |

Y lo que este laboratorio deliberadamente no hace, y producción sí necesita:

- **HTTPS** con ACM y redirección desde el 80.
- **Autenticación** delante de cualquier endpoint que modifique estado.
- **Subnets privadas** con NAT o VPC endpoints para las tareas.
- **Autoescalado** en el servicio estable.
- **Backend remoto** de Terraform con bloqueo de estado.
- Métricas de negocio en el criterio de corte, no solo errores y latencia: una
  versión puede responder 200 a todo y estar rompiendo conversiones.

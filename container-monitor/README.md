# Container Monitor

Script Bash para monitorear métricas básicas de rendimiento de contenedores Docker y guardarlas en archivos CSV.

Está pensado para debugging local, pruebas de performance simples, seguimiento de ejecuciones puntuales y análisis posterior con herramientas como `awk`, `python`, `pandas`, `polars`, `duckdb`, Excel, etc.

El script permite seleccionar contenedores interactivamente usando `fzf`, escribir logs en una carpeta configurable y mostrar las métricas en pantalla mientras corre.

---

## Features

* Selección interactiva de contenedores con `fzf`.
* Logging automático en CSV.
* Carpeta de logs configurable.
* Modo verbose para ver métricas en vivo.
* Modo mínimo por default para evitar CSVs ruidosos.
* Modo extendido con métricas adicionales.
* Shutdown automático cuando el contenedor termina.
* Manejo de contenedores que arrancan y mueren rápidamente.
* Salida apta para análisis posterior.

---

## Requirements

### Required

* `bash`
* `docker`

### Optional

* `fzf`

`fzf` solo es necesario si querés seleccionar el contenedor interactivamente. Si pasás el contenedor con `-c`, no hace falta.

En Ubuntu / WSL:

```bash
sudo apt update
sudo apt install -y fzf
```

---

## Installation

Clonar o copiar el script en algún directorio incluido en tu `PATH`.

Ejemplo:

```bash
mkdir -p ~/.local/bin
cp container_monitor.sh ~/.local/bin/container_monitor.sh
chmod +x ~/.local/bin/container_monitor.sh
```

Si `~/.local/bin` no está en tu `PATH`, podés agregarlo:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

O, si usás `zsh`:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

---

## Basic usage

Seleccionar un contenedor interactivamente:

```bash
container_monitor.sh
```

Mostrar métricas en pantalla mientras también se escriben al CSV:

```bash
container_monitor.sh -v
```

Monitorear un contenedor específico:

```bash
container_monitor.sh -c my_container
```

Monitorear cada 2 segundos:

```bash
container_monitor.sh -i 2
```

Usar modo extendido:

```bash
container_monitor.sh -e
```

Usar modo extendido y mostrar métricas en pantalla:

```bash
container_monitor.sh -e -v
```

Cambiar la carpeta de salida:

```bash
container_monitor.sh -o ~/logs/docker-monitoring
```

Ver ayuda:

```bash
container_monitor.sh --help
```

---

## Output directory

Por defecto, los CSV se escriben en:

```bash
~/logs/docker-stats
```

La carpeta se crea automáticamente si no existe.

También se puede configurar usando la variable de entorno:

```bash
export DOCKER_MONITOR_LOG_DIR="$HOME/logs/docker-stats"
container_monitor.sh
```

O pasando el directorio explícitamente:

```bash
container_monitor.sh -o ~/logs/docker-monitoring
```

---

## Output filename

El nombre del archivo tiene este formato:

```text
<container_name>_stats_<timestamp>.csv
```

Ejemplo:

```text
competent_shockley_stats_2026-06-04_16-50-10.csv
```

---

## Default CSV columns

En modo normal, el CSV incluye solo las columnas más útiles para seguimiento rápido:

```csv
timestamp,container_name,cpu_pct,mem_mb,mem_pct,net_rx_mbps,net_tx_mbps,pids
```

### Column reference

#### `timestamp`

Fecha y hora de la muestra en formato ISO-8601.

Ejemplo:

```text
2026-06-04T16:56:31-03:00
```

#### `container_name`

Nombre del contenedor Docker monitoreado.

Ejemplo:

```text
competent_shockley
```

#### `cpu_pct`

Porcentaje de CPU reportado por Docker.

Valores superiores a `100` son normales si el contenedor usa más de un core.

Ejemplos:

```text
50.00
```

Aproximadamente medio core.

```text
250.00
```

Aproximadamente dos cores y medio.

#### `mem_mb`

Memoria usada actualmente por el contenedor, en MiB.

Ejemplo:

```text
493.10
```

Equivale aproximadamente a 493 MiB.

#### `mem_pct`

Porcentaje de memoria usada respecto del límite disponible para el contenedor.

Ejemplo:

```text
3.53
```

Significa que el contenedor está usando aproximadamente el 3.53% de su límite de memoria.

#### `net_rx_mbps`

Tasa aproximada de red recibida por el contenedor, en megabits por segundo.

Se calcula comparando el valor acumulado de red recibido entre una muestra y la siguiente.

Ejemplo:

```text
12.40
```

Significa que el contenedor está recibiendo aproximadamente 12.40 Mbps en ese intervalo.

#### `net_tx_mbps`

Tasa aproximada de red transmitida por el contenedor, en megabits por segundo.

Se calcula comparando el valor acumulado de red transmitido entre una muestra y la siguiente.

Ejemplo:

```text
3.80
```

Significa que el contenedor está transmitiendo aproximadamente 3.80 Mbps en ese intervalo.

#### `pids`

Cantidad de procesos o threads corriendo dentro del contenedor.

Un crecimiento inesperado de este valor puede indicar fuga de procesos, threads colgados o algún comportamiento anómalo.

---

## Example default CSV

```csv
timestamp,container_name,cpu_pct,mem_mb,mem_pct,net_rx_mbps,net_tx_mbps,pids
2026-06-04T16:56:31-03:00,competent_shockley,15.81,393.00,2.81,0.00,0.00,19
2026-06-04T16:56:34-03:00,competent_shockley,18.13,409.30,2.93,7.20,0.00,19
2026-06-04T16:56:36-03:00,competent_shockley,15.57,421.50,3.01,8.80,0.00,19
```

---

## Extended mode

El modo extendido se activa con:

```bash
container_monitor.sh -e
```

O:

```bash
container_monitor.sh --extended
```

En este modo se agregan columnas útiles para análisis más detallado.

Columnas:

```csv
timestamp,container_id,container_name,cpu_pct,mem_mb,mem_pct,mem_limit_mb,net_rx_mbps,net_tx_mbps,net_rx_mb,net_tx_mb,block_read_mb,block_write_mb,pids
```

### Extra columns in extended mode

#### `container_id`

ID corto del contenedor Docker.

#### `mem_limit_mb`

Límite de memoria disponible para el contenedor, en MiB.

#### `net_rx_mb`

Cantidad acumulada de datos recibidos por red desde que arrancó el contenedor, en MiB.

A diferencia de `net_rx_mbps`, este valor es acumulado.

#### `net_tx_mb`

Cantidad acumulada de datos transmitidos por red desde que arrancó el contenedor, en MiB.

A diferencia de `net_tx_mbps`, este valor es acumulado.

#### `block_read_mb`

Cantidad acumulada de datos leídos desde dispositivos de bloque, en MiB.

Puede servir para detectar actividad fuerte de lectura de disco.

#### `block_write_mb`

Cantidad acumulada de datos escritos a dispositivos de bloque, en MiB.

Puede servir para detectar actividad fuerte de escritura en disco.

---

## Verbose mode

El modo verbose se activa con:

```bash
container_monitor.sh -v
```

Este modo imprime las métricas en pantalla mientras también las guarda en el CSV.

Es útil cuando querés monitorear el contenedor en vivo sin hacer:

```bash
tail -f <archivo.csv>
```

Ejemplo:

```text
timestamp                 container                cpu%     mem_mb     mem%      rx_mbps      tx_mbps   pids
2026-06-04T16:56:31-03:00 competent_shockley       15.81     393.00     2.81         0.00         0.00     19
2026-06-04T16:56:34-03:00 competent_shockley       18.13     409.30     2.93         7.20         0.00     19
```

---

## Container lifecycle handling

El script monitorea el ciclo de vida del contenedor.

Si el contenedor termina, el script corta automáticamente y guarda el CSV.

Ejemplo:

```text
Container stopped. docker_exit_code=0

CSV saved at: /home/user/logs/docker-stats/my_container_stats_2026-06-04_16-50-10.csv
```

Esto evita que el script quede corriendo indefinidamente cuando Docker ya no devuelve métricas.

También cubre casos donde el contenedor arranca y muere rápidamente.

---

## Common use cases

### Debug rápido de un contenedor

```bash
container_monitor.sh -v
```

### Monitorear un contenedor específico

```bash
container_monitor.sh -c api_backend -v
```

### Comparar consumo entre ejecuciones

```bash
container_monitor.sh -c batch_job -i 1
```

Después comparar los CSV generados en `~/logs/docker-stats`.

### Guardar métricas más detalladas

```bash
container_monitor.sh -c batch_job -e
```

### Usar otra carpeta para los logs

```bash
container_monitor.sh -c batch_job -o ~/logs/batch-runs
```

---

## Analyzing the CSV

### Ver últimas muestras

```bash
tail -n 10 ~/logs/docker-stats/*.csv
```

### Ver el CSV mientras se escribe

Aunque normalmente conviene usar `-v`, también podés hacer:

```bash
tail -f ~/logs/docker-stats/<file>.csv
```

### Ordenar por mayor CPU

```bash
column -s, -t < file.csv | sort -k3 -nr | head
```

### Ver memoria máxima

```bash
awk -F, 'NR > 1 { if ($4 > max) max = $4 } END { print max " MiB" }' file.csv
```

### Ver CPU promedio

```bash
awk -F, 'NR > 1 { sum += $3; count++ } END { print sum / count }' file.csv
```

---

## Notes

### CPU above 100%

Docker reporta CPU respecto de un core.

Por eso, si un contenedor usa más de un core, el valor puede superar `100`.

Ejemplo:

```text
275.00
```

Significa aproximadamente 2.75 cores.

### Network metrics

Docker entrega valores acumulados para red.

El script calcula `net_rx_mbps` y `net_tx_mbps` usando la diferencia entre una muestra y la siguiente.

Por eso, en la primera muestra estos valores suelen aparecer como `0.00`.

### Memory units

El script guarda memoria en MiB para que sea más fácil de leer y analizar.

Internamente Docker puede reportar memoria como `B`, `KiB`, `MiB`, `GiB`, etc. El script normaliza estos valores.

---

## Limitations

Este script es útil para debugging local y monitoreo puntual, pero no reemplaza una solución de observabilidad completa.

Para monitoreo persistente o productivo conviene usar herramientas como:

* Prometheus
* cAdvisor
* Grafana
* Docker metrics exporters
* OpenTelemetry

Este script prioriza simplicidad, portabilidad y facilidad de uso desde terminal.

---

## Exit behavior

El script termina cuando:

* El usuario presiona `Ctrl+C`.
* El contenedor termina.
* Docker deja de devolver estadísticas y el contenedor ya no está corriendo.
* Docker deja de devolver estadísticas repetidamente aunque el contenedor figure como corriendo.

En todos los casos intenta cerrar de forma ordenada e informar dónde quedó guardado el CSV.

---

## License

MIT

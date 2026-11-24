# ui — Inspector Unificado de Cuentas cPanel y Linux (`v2.0.0`)

Una CLI moderna e independiente en Bash + Python 3 para inspeccionar cuentas **cPanel/WHM** y **cuentas Linux**, reemplazando el legado en Perl `ui.pl` (2012) sin dependencias CPAN externas, con ejecución segura de subprocesos y salidas en `table` / `json` / `csv`.

## Características

- **Inspección Dual-Mode**: Inspecciona automáticamente cuentas cPanel (`/var/cpanel/users`, `/var/cpanel/userdata`, `/etc/userdomains`, `/etc/domainips`, `/etc/reservedips`, `/var/cpanel/accounting.log`) y realiza fallback limpio a cuentas Linux estándar (`/etc/passwd`, `ps`, `quota`/`df`).
- **Detección Automática por Directorio (`.`)**: Ejecute `./ui.sh` o `./ui.sh .` dentro de `/home/<usuario>` o `/var/www/vhosts/<dominio>`.
- **Lógica de IP Corregida**: Corrige el error invertido de `/etc/reservedips` de `ui.pl` para reportar correctamente IPs `SHARED` vs `DEDICATED`.
- **SSL y Exports Seguros**: Inspecciona certificados X.509 (`--ssl`) y exporta variables protegidas con `shlex.quote` (`--env`).
- **Diagnósticos (`-d`)**: Detecta umbrales altos de dominios, CPU, memoria, procesos, disco, inodos, catchalls y suspensión.

## Uso

```bash
./ui.sh [OBJETIVO] [OPCIONES]
```

## Ejemplo de Salida Real

```text
$ ./ui.sh sr00t3d --no-color
=== Account Inspector (LINUX) ===
  Username      : sr00t3d (UID: 1000, GID: 1000)
  Status        : ACTIVE
  Main Domain   : hackerpc
  Owner / Plan  : local / system
  Email         : -
  IP Address    : 127.0.1.1 (HOST)
  Home / Shell  : /home/sr00t3d (/bin/fish)
  DocumentRoot  : /home/sr00t3d
  Created       : -
  Resources     : Procs: 186 | CPU: 200.9% | MEM: 75.5%
  Disk / Inodes : 375364.0 MiB / -

--- Diagnostics ---
  [!] High CPU usage: 200.9% (> 25.0%)
  [!] High Memory usage: 75.5% (> 5.0%)
  [!] High process count: 186 (>= 25)
  [!] High disk usage: 375364.0 MiB (> 20480 MiB)
```

## Licencia

Apache-2.0 — ver [LICENSE](LICENSE).

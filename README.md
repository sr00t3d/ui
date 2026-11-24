# ui — Unified cPanel & Linux Account Inspector (`v2.0.0`)

A modern, standalone Bash + Python 3 CLI for inspecting **cPanel/WHM** and **Linux system** accounts, replacing legacy Perl `ui.pl` (2012) with zero external CPAN dependencies, safe subprocess execution, and structured `table` / `json` / `csv` outputs.

## Features

- **Dual-Mode Inspection**: Automatically inspects cPanel accounts (`/var/cpanel/users`, `/var/cpanel/userdata`, `/etc/userdomains`, `/etc/domainips`, `/etc/reservedips`, `/var/cpanel/accounting.log`) and falls back cleanly to standard Linux accounts (`/etc/passwd`, `ps`, `quota`/`df`).
- **CWD Auto-Detection (`.`)**: Run `./ui.sh` or `./ui.sh .` inside `/home/<user>` or `/var/www/vhosts/<domain>` to auto-detect the target account.
- **Fixed IP Ownership Logic**: Resolves the inverted `/etc/reservedips` bug from legacy `ui.pl` so `SHARED` vs `DEDICATED` IPs are reported accurately.
- **Safe SSL & Shell Env Exports**: Inspects X.509 certificates via `openssl x509` with safe argument lists (`--ssl`) and exports `shlex.quote`-escaped shell variables (`--env`).
- **Diagnostics (`-d`)**: Flags high domain counts (`>100`), CPU (`>25%`), memory (`>5%`), process counts (`>=25`), disk usage (`>20 GiB`), inodes (`>100k`), catchall forwarders, and suspension status.
- **Multiple Output Formats**: `table` (default), `json`, `csv`, and `--env`.

## Usage

```bash
./ui.sh [TARGET] [OPTIONS]
```

| Flag | Description |
| :--- | :--- |
| `TARGET` | Username, domain name, or `.` for CWD auto-detection |
| `-l, --list` | List addon domains, subdomains, and parked domains |
| `-s, --ssl` | Inspect SSL certificate metadata |
| `-n, --ns` | Show configured nameservers |
| `-t, --tempurl` | Show temporary cPanel URL (`http://<ip>/~<user>`) |
| `-d, --debug` | Show diagnostic threshold warnings |
| `-e, --env` | Output safe Bash `export` statements |
| `-o, --output` | Output format: `table`, `json`, or `csv` |
| `--cpanel-root` | Custom `/var/cpanel` root for testing/sandboxes |
| `--etc-root` | Custom `/etc` root for testing/sandboxes |
| `-v, --version` | Show version (`2.0.0`) |

## Real Output Example

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

## License

Apache-2.0 — see [LICENSE](LICENSE).

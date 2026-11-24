# ui — Inspetor Unificado de Contas cPanel e Linux (`v2.0.0`)

Uma CLI moderna e independente em Bash + Python 3 para inspeção de contas **cPanel/WHM** e **contas Linux**, substituindo o legado em Perl `ui.pl` (2012) sem dependências CPAN externas, com execução segura de subprocessos e saídas estruturadas em `table` / `json` / `csv`.

## Recursos

- **Inspeção Dual-Mode**: Inspeciona automaticamente contas cPanel (`/var/cpanel/users`, `/var/cpanel/userdata`, `/etc/userdomains`, `/etc/domainips`, `/etc/reservedips`, `/var/cpanel/accounting.log`) e faz fallback limpo para contas Linux padrão (`/etc/passwd`, `ps`, `quota`/`df`).
- **Detecção Automática pelo Diretório Atual (`.`)**: Execute `./ui.sh` ou `./ui.sh .` dentro de `/home/<usuario>` ou `/var/www/vhosts/<dominio>` para detectar o alvo automaticamente.
- **Lógica de IP Corrigida**: Corrige o bug invertido de `/etc/reservedips` do `ui.pl` original para distinguir corretamente IPs `SHARED` e `DEDICATED`.
- **SSL e Variáveis de Ambiente Seguras**: Inspeciona certificados X.509 via `openssl x509` sem interpolação de shell (`--ssl`) e gera exports protegidos com `shlex.quote` (`--env`).
- **Diagnósticos (`-d`)**: Alerta sobre excesso de domínios (`>100`), CPU (`>25%`), memória (`>5%`), processos (`>=25`), disco (`>20 GiB`), inodes (`>100k`), catchalls e suspensão.

## Uso

```bash
./ui.sh [ALVO] [OPÇÕES]
```

## Exemplo de Saída Real

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

## Licença

Apache-2.0 — veja [LICENSE](LICENSE).

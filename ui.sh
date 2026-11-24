#!/usr/bin/env bash
# ==============================================================================
# ui.sh — Unified cPanel & Linux Account Inspector (v2.0.0)
# Modernized clean-room implementation inspired by legacy ui.pl (2012).
# Copyright (c) 2026 Percio Castelo — Apache-2.0 License
# ==============================================================================
set -euo pipefail

VERSION="2.0.0"

if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is required (3.6+)." >&2
    exit 1
fi

read -r -d '' PY_SCRIPT << 'EOF' || true
import argparse
import csv
import datetime
import io
import json
import os
import pwd
import re
import shlex
import shutil
import socket
import subprocess
import sys

VERSION = "2.0.0"

THRESHOLDS = {
    "domains": 100,
    "inodes": 100000,
    "disk_mb": 20480,
    "catchall": 1,
    "cpu_perc": 25.0,
    "mem_perc": 5.0,
    "no_procs": 25,
}


class Colors:
    def __init__(self, enabled=True):
        self.enabled = enabled
        self.RESET = "\033[0m" if enabled else ""
        self.BOLD = "\033[1m" if enabled else ""
        self.DIM = "\033[2m" if enabled else ""
        self.CYAN = "\033[36m" if enabled else ""
        self.GREEN = "\033[32m" if enabled else ""
        self.YELLOW = "\033[33m" if enabled else ""
        self.RED = "\033[31m" if enabled else ""
        self.MAGENTA = "\033[35m" if enabled else ""


def parse_kv_file(path):
    data = {}
    if not os.path.isfile(path):
        return data
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" in line:
                    k, v = line.split("=", 1)
                    data[k.strip()] = v.strip()
                elif ":" in line:
                    k, v = line.split(":", 1)
                    data[k.strip()] = v.strip().strip("'\"")
    except OSError:
        pass
    return data


def parse_userdata_main(path):
    """Lightweight stdlib parser for /var/cpanel/userdata/<user>/main (YAML-like or JSON)."""
    result = {
        "main_domain": "",
        "addon_domains": {},
        "sub_domains": [],
        "parked_domains": [],
    }
    if not os.path.isfile(path):
        return result
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            raw = fh.read()
    except OSError:
        return result

    stripped = raw.lstrip()
    if stripped.startswith("{"):
        try:
            obj = json.loads(raw)
            result["main_domain"] = obj.get("main_domain", "") or ""
            result["addon_domains"] = obj.get("addon_domains", {}) or {}
            result["sub_domains"] = obj.get("sub_domains", []) or []
            result["parked_domains"] = obj.get("parked_domains", []) or []
            return result
        except ValueError:
            pass

    section = None
    for line in raw.splitlines():
        if not line.strip() or line.strip().startswith("#") or line.strip() == "---":
            continue
        if not line[0].isspace():
            if ":" in line:
                k, v = line.split(":", 1)
                k = k.strip()
                v = v.strip().strip("'\"")
                if k == "main_domain":
                    result["main_domain"] = v
                    section = None
                elif k in ("addon_domains", "sub_domains", "parked_domains"):
                    section = k
                else:
                    section = None
        else:
            s = line.strip()
            if section == "addon_domains" and ":" in s:
                k, v = s.split(":", 1)
                result["addon_domains"][k.strip().strip("'\"")] = v.strip().strip("'\"")
            elif section in ("sub_domains", "parked_domains"):
                val = s.lstrip("-").strip().strip("'\"")
                if val and val != "[]":
                    result[section].append(val)
    return result


def parse_userdata_domain(path):
    data = {}
    if not os.path.isfile(path):
        return data
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            raw = fh.read()
    except OSError:
        return data
    if raw.lstrip().startswith("{"):
        try:
            return json.loads(raw)
        except ValueError:
            pass
    for line in raw.splitlines():
        s = line.strip()
        if not s or s.startswith("#") or s == "---":
            continue
        if ":" in s and not line[0].isspace():
            k, v = s.split(":", 1)
            data[k.strip()] = v.strip().strip("'\"")
    return data


def detect_target_from_cwd(cwd):
    m = re.match(r"^/home[0-9]?/([^/]+)", cwd)
    if m:
        return m.group(1)
    m = re.match(r"^/var/www/vhosts/([^/]+)", cwd)
    if m:
        return m.group(1)
    return None


def resolve_cpanel_user(target, etc_root, cpanel_root):
    users_dir = os.path.join(cpanel_root, "users")
    if os.path.isfile(os.path.join(users_dir, target)):
        return target, None

    userdomains = os.path.join(etc_root, "userdomains")
    if os.path.isfile(userdomains):
        try:
            with open(userdomains, "r", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if ":" not in line:
                        continue
                    dom, usr = line.split(":", 1)
                    dom = dom.strip().lower()
                    usr = usr.strip()
                    if dom == target.lower() and usr != "nobody":
                        return usr, dom
        except OSError:
            pass
    return None, None


def get_process_stats(username):
    procs = 0
    cpu_total = 0.0
    mem_total = 0.0
    if not username:
        return procs, cpu_total, mem_total
    try:
        res = subprocess.run(
            ["ps", "-u", username, "-o", "pid,%cpu,%mem", "--no-headers"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
        )
        if res.returncode == 0:
            for line in res.stdout.splitlines():
                parts = line.split()
                if len(parts) >= 3:
                    procs += 1
                    try:
                        cpu_total += float(parts[1])
                        mem_total += float(parts[2])
                    except ValueError:
                        pass
    except (OSError, subprocess.TimeoutExpired):
        pass
    return procs, round(cpu_total, 2), round(mem_total, 2)


def get_disk_usage(homedir, username):
    disk_mb = None
    inodes_used = None
    quota_bin = shutil.which("quota")
    if quota_bin and username:
        try:
            res = subprocess.run(
                [quota_bin, "-u", username, "-w"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=5,
            )
            for line in res.stdout.splitlines():
                parts = line.split()
                if len(parts) >= 5 and parts[1].rstrip("*").isdigit():
                    kb = int(parts[1].rstrip("*"))
                    disk_mb = round(kb / 1024.0, 2)
                    if len(parts) >= 6 and parts[4].rstrip("*").isdigit():
                        inodes_used = int(parts[4].rstrip("*"))
                    break
        except (OSError, subprocess.TimeoutExpired, ValueError):
            pass

    if disk_mb is None and homedir and os.path.isdir(homedir):
        df_bin = shutil.which("df")
        if df_bin:
            try:
                res = subprocess.run(
                    [df_bin, "-Pm", homedir],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    text=True,
                    timeout=5,
                )
                lines = res.stdout.strip().splitlines()
                if len(lines) >= 2:
                    parts = lines[-1].split()
                    if len(parts) >= 3 and parts[2].isdigit():
                        disk_mb = float(parts[2])
            except (OSError, subprocess.TimeoutExpired, ValueError):
                pass
    return disk_mb, inodes_used


def inspect_ssl_cert(cert_path):
    openssl_bin = shutil.which("openssl")
    if not openssl_bin or not cert_path or not os.path.isfile(cert_path):
        return None
    try:
        res = subprocess.run(
            [openssl_bin, "x509", "-in", cert_path, "-noout", "-subject", "-issuer", "-dates", "-nameopt", "RFC2253"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
        )
        if res.returncode != 0:
            return None
        info = {"path": cert_path, "subject": "", "issuer": "", "not_before": "", "not_after": ""}
        for line in res.stdout.splitlines():
            if line.startswith("subject="):
                info["subject"] = line[len("subject="):].strip()
            elif line.startswith("issuer="):
                info["issuer"] = line[len("issuer="):].strip()
            elif line.startswith("notBefore="):
                info["not_before"] = line[len("notBefore="):].strip()
            elif line.startswith("notAfter="):
                info["not_after"] = line[len("notAfter="):].strip()
        return info
    except (OSError, subprocess.TimeoutExpired):
        return None


def get_nameservers(etc_root):
    ns_list = []
    wwwacct = parse_kv_file(os.path.join(etc_root, "wwwacct.conf"))
    for k in ("NS", "NS2", "NS3", "NS4"):
        val = wwwacct.get(k) or ""
        if not val:
            # Handle space-delimited wwwacct.conf
            pass
    wwwacct_path = os.path.join(etc_root, "wwwacct.conf")
    if os.path.isfile(wwwacct_path):
        try:
            with open(wwwacct_path, "r", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    parts = line.strip().split()
                    if len(parts) >= 2 and parts[0] in ("NS", "NS2", "NS3", "NS4"):
                        ns_list.append(parts[1])
        except OSError:
            pass
    if not ns_list:
        resolv_path = os.path.join(etc_root, "resolv.conf")
        if os.path.isfile(resolv_path):
            try:
                with open(resolv_path, "r", encoding="utf-8", errors="replace") as fh:
                    for line in fh:
                        parts = line.strip().split()
                        if len(parts) >= 2 and parts[0] == "nameserver":
                            ns_list.append(parts[1])
            except OSError:
                pass
    return ns_list


def gather_cpanel_info(username, matched_domain, etc_root, cpanel_root, args):
    cp_user = parse_kv_file(os.path.join(cpanel_root, "users", username))
    main_ud = parse_userdata_main(os.path.join(cpanel_root, "userdata", username, "main"))

    main_domain = cp_user.get("DNS") or main_ud.get("main_domain") or matched_domain or ""
    target_domain = matched_domain or main_domain

    domain_ud = {}
    if target_domain:
        domain_ud = parse_userdata_domain(os.path.join(cpanel_root, "userdata", username, target_domain))
    if not domain_ud and main_domain:
        domain_ud = parse_userdata_domain(os.path.join(cpanel_root, "userdata", username, main_domain))

    try:
        pw = pwd.getpwnam(username)
        homedir = pw.pw_dir
        shell = pw.pw_shell
        uid = pw.pw_uid
        gid = pw.pw_gid
    except KeyError:
        homedir = f"/home/{username}"
        shell = "/bin/bash"
        uid = None
        gid = None

    docroot = domain_ud.get("documentroot") or f"{homedir}/public_html"
    ip = domain_ud.get("ip") or cp_user.get("IP") or ""

    # Fixed /etc/reservedips logic: reservedips lists shared/system IPs, not dedicated IPs
    reserved_ips = set()
    res_path = os.path.join(etc_root, "reservedips")
    if os.path.isfile(res_path):
        try:
            with open(res_path, "r", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    line = line.strip().split("#", 1)[0].strip()
                    if line:
                        reserved_ips.add(line)
        except OSError:
            pass

    domain_ips = {}
    dips_path = os.path.join(etc_root, "domainips")
    if os.path.isfile(dips_path):
        try:
            with open(dips_path, "r", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if ":" in line:
                        ip_k, dom_v = line.split(":", 1)
                        domain_ips[dom_v.strip()] = ip_k.strip()
        except OSError:
            pass

    if ip in reserved_ips:
        ip_type = "SHARED"
    elif main_domain in domain_ips and domain_ips[main_domain] == ip:
        ip_type = "DEDICATED"
    elif ip:
        ip_type = "SHARED"
    else:
        ip_type = "UNKNOWN"

    suspended_file = os.path.join(cpanel_root, "suspended", username)
    suspended = os.path.isfile(suspended_file)
    suspend_reason = ""
    if suspended:
        try:
            with open(suspended_file, "r", encoding="utf-8", errors="replace") as fh:
                suspend_reason = fh.read().strip()
        except OSError:
            pass

    created_at = ""
    acct_log = os.path.join(cpanel_root, "accounting.log")
    if os.path.isfile(acct_log):
        try:
            with open(acct_log, "r", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if line.startswith("CREATE:") and f":{username}:" in line:
                        parts = line.split(":")
                        if len(parts) >= 2 and parts[1].isdigit():
                            dt = datetime.datetime.fromtimestamp(int(parts[1]))
                            created_at = dt.strftime("%Y-%m-%d %H:%M:%S")
                        break
        except OSError:
            pass

    if not created_at and cp_user.get("STARTDATE", "").isdigit():
        dt = datetime.datetime.fromtimestamp(int(cp_user["STARTDATE"]))
        created_at = dt.strftime("%Y-%m-%d %H:%M:%S")

    procs, cpu_perc, mem_perc = get_process_stats(username)
    disk_mb, inodes_used = get_disk_usage(homedir, username)

    # Catchall check
    catchalls = []
    if args.debug or args.output == "json":
        all_doms = [main_domain] + list(main_ud.get("addon_domains", {}).keys()) + main_ud.get("parked_domains", [])
        for d in filter(None, set(all_doms)):
            valias = os.path.join(etc_root, "valiases", d)
            if os.path.isfile(valias):
                try:
                    with open(valias, "r", encoding="utf-8", errors="replace") as fh:
                        for line in fh:
                            if line.startswith("*:") and ":fail:" not in line and ":blackhole:" not in line:
                                catchalls.append(f"{d} -> {line.split(':', 1)[1].strip()}")
                except OSError:
                    pass

    ssl_info = None
    if args.ssl:
        ssl_ud = parse_userdata_domain(os.path.join(cpanel_root, "userdata", username, f"{target_domain}_SSL"))
        cert_file = ssl_ud.get("sslcertificatefile") or f"/var/cpanel/ssl/apache_tls/{target_domain}/combined"
        ssl_info = inspect_ssl_cert(cert_file)

    warnings = []
    total_domains = 1 + len(main_ud.get("addon_domains", {})) + len(main_ud.get("sub_domains", [])) + len(main_ud.get("parked_domains", []))
    if total_domains > THRESHOLDS["domains"]:
        warnings.append(f"High domain count: {total_domains} (> {THRESHOLDS['domains']})")
    if cpu_perc > THRESHOLDS["cpu_perc"]:
        warnings.append(f"High CPU usage: {cpu_perc}% (> {THRESHOLDS['cpu_perc']}%)")
    if mem_perc > THRESHOLDS["mem_perc"]:
        warnings.append(f"High Memory usage: {mem_perc}% (> {THRESHOLDS['mem_perc']}%)")
    if procs >= THRESHOLDS["no_procs"]:
        warnings.append(f"High process count: {procs} (>= {THRESHOLDS['no_procs']})")
    if disk_mb is not None and disk_mb > THRESHOLDS["disk_mb"]:
        warnings.append(f"High disk usage: {disk_mb} MiB (> {THRESHOLDS['disk_mb']} MiB)")
    if inodes_used is not None and inodes_used > THRESHOLDS["inodes"]:
        warnings.append(f"High inode count: {inodes_used} (> {THRESHOLDS['inodes']})")
    if len(catchalls) >= THRESHOLDS["catchall"]:
        warnings.append(f"Catchall forwarders detected: {len(catchalls)}")
    if suspended:
        warnings.append(f"Account is SUSPENDED ({suspend_reason or 'no reason recorded'})")

    return {
        "mode": "cpanel",
        "username": username,
        "uid": uid,
        "gid": gid,
        "shell": shell,
        "homedir": homedir,
        "main_domain": main_domain,
        "queried_domain": target_domain,
        "docroot": docroot,
        "ip": ip,
        "ip_type": ip_type,
        "owner": cp_user.get("OWNER") or "root",
        "plan": cp_user.get("PLAN") or "default",
        "email": cp_user.get("CONTACTEMAIL") or "",
        "created_at": created_at,
        "suspended": suspended,
        "suspend_reason": suspend_reason,
        "processes": procs,
        "cpu_perc": cpu_perc,
        "mem_perc": mem_perc,
        "disk_mb": disk_mb,
        "inodes_used": inodes_used,
        "addon_domains": main_ud.get("addon_domains", {}),
        "sub_domains": main_ud.get("sub_domains", []),
        "parked_domains": main_ud.get("parked_domains", []),
        "nameservers": get_nameservers(etc_root) if args.ns else [],
        "temp_url": f"http://{ip}/~{username}" if (args.tempurl and ip) else "",
        "ssl": ssl_info,
        "warnings": warnings,
    }


def gather_linux_info(target, etc_root, args):
    try:
        pw = pwd.getpwnam(target)
    except KeyError:
        return None

    procs, cpu_perc, mem_perc = get_process_stats(pw.pw_name)
    disk_mb, inodes_used = get_disk_usage(pw.pw_dir, pw.pw_name)
    hostname = socket.gethostname()
    try:
        ip = socket.gethostbyname(hostname)
    except OSError:
        ip = "127.0.0.1"

    docroot = os.path.join(pw.pw_dir, "public_html")
    if not os.path.isdir(docroot):
        docroot = pw.pw_dir

    warnings = []
    if cpu_perc > THRESHOLDS["cpu_perc"]:
        warnings.append(f"High CPU usage: {cpu_perc}% (> {THRESHOLDS['cpu_perc']}%)")
    if mem_perc > THRESHOLDS["mem_perc"]:
        warnings.append(f"High Memory usage: {mem_perc}% (> {THRESHOLDS['mem_perc']}%)")
    if procs >= THRESHOLDS["no_procs"]:
        warnings.append(f"High process count: {procs} (>= {THRESHOLDS['no_procs']})")
    if disk_mb is not None and disk_mb > THRESHOLDS["disk_mb"]:
        warnings.append(f"High disk usage: {disk_mb} MiB (> {THRESHOLDS['disk_mb']} MiB)")

    ssl_info = None
    if args.ssl:
        for candidate in (
            os.path.join(etc_root, "ssl", "certs", "ssl-cert-snakeoil.pem"),
            os.path.join(etc_root, "pki", "tls", "certs", "localhost.crt"),
        ):
            if os.path.isfile(candidate):
                ssl_info = inspect_ssl_cert(candidate)
                break

    return {
        "mode": "linux",
        "username": pw.pw_name,
        "uid": pw.pw_uid,
        "gid": pw.pw_gid,
        "shell": pw.pw_shell,
        "homedir": pw.pw_dir,
        "main_domain": hostname,
        "queried_domain": hostname,
        "docroot": docroot,
        "ip": ip,
        "ip_type": "HOST",
        "owner": "local",
        "plan": "system",
        "email": "",
        "created_at": "",
        "suspended": False,
        "suspend_reason": "",
        "processes": procs,
        "cpu_perc": cpu_perc,
        "mem_perc": mem_perc,
        "disk_mb": disk_mb,
        "inodes_used": inodes_used,
        "addon_domains": {},
        "sub_domains": [],
        "parked_domains": [],
        "nameservers": get_nameservers(etc_root) if args.ns else [],
        "temp_url": "",
        "ssl": ssl_info,
        "warnings": warnings,
    }


def render_table(info, args, c):
    status_str = f"{c.RED}SUSPENDED{c.RESET}" if info["suspended"] else f"{c.GREEN}ACTIVE{c.RESET}"
    print(f"{c.BOLD}{c.CYAN}=== Account Inspector ({info['mode'].upper()}) ==={c.RESET}")
    rows = [
        ("Username", f"{info['username']} (UID: {info['uid']}, GID: {info['gid']})"),
        ("Status", status_str),
        ("Main Domain", info["main_domain"] or "-"),
        ("Owner / Plan", f"{info['owner']} / {info['plan']}"),
        ("Email", info["email"] or "-"),
        ("IP Address", f"{info['ip']} ({info['ip_type']})" if info["ip"] else "-"),
        ("Home / Shell", f"{info['homedir']} ({info['shell']})"),
        ("DocumentRoot", info["docroot"]),
        ("Created", info["created_at"] or "-"),
        ("Resources", f"Procs: {info['processes']} | CPU: {info['cpu_perc']}% | MEM: {info['mem_perc']}%"),
        ("Disk / Inodes", f"{info['disk_mb'] if info['disk_mb'] is not None else '-'} MiB / {info['inodes_used'] if info['inodes_used'] is not None else '-'}"),
    ]
    for k, v in rows:
        print(f"  {c.BOLD}{k:<14}{c.RESET}: {v}")

    if args.tempurl and info["temp_url"]:
        print(f"  {c.BOLD}{'Temp URL':<14}{c.RESET}: {info['temp_url']}")

    if args.ns and info["nameservers"]:
        print(f"  {c.BOLD}{'Nameservers':<14}{c.RESET}: {', '.join(info['nameservers'])}")

    if args.list:
        print(f"\n{c.BOLD}{c.CYAN}--- Domains ---{c.RESET}")
        if info["addon_domains"]:
            print(f"  {c.BOLD}Addon Domains:{c.RESET}")
            for d, sub in info["addon_domains"].items():
                print(f"    - {d} ({sub})")
        if info["sub_domains"]:
            print(f"  {c.BOLD}Subdomains:{c.RESET}")
            for d in info["sub_domains"]:
                print(f"    - {d}")
        if info["parked_domains"]:
            print(f"  {c.BOLD}Parked Domains:{c.RESET}")
            for d in info["parked_domains"]:
                print(f"    - {d}")
        if not (info["addon_domains"] or info["sub_domains"] or info["parked_domains"]):
            print("  (no secondary domains)")

    if args.ssl:
        print(f"\n{c.BOLD}{c.CYAN}--- SSL Certificate ---{c.RESET}")
        if info["ssl"]:
            for k in ("path", "subject", "issuer", "not_before", "not_after"):
                print(f"  {c.BOLD}{k:<12}{c.RESET}: {info['ssl'][k]}")
        else:
            print("  (no SSL certificate found)")

    if args.debug or info["warnings"]:
        print(f"\n{c.BOLD}{c.YELLOW}--- Diagnostics ---{c.RESET}")
        if info["warnings"]:
            for w in info["warnings"]:
                print(f"  {c.RED}[!]{c.RESET} {w}")
        else:
            print(f"  {c.GREEN}[OK]{c.RESET} All thresholds within normal limits.")


def render_env(info):
    exports = {
        "UI_MY_USERNAME": info["username"],
        "UI_MY_DOMAIN": info["main_domain"],
        "UI_MY_OWNER": info["owner"],
        "UI_MY_EMAIL": info["email"],
        "UI_MY_DOCROOT": info["docroot"],
        "UI_MY_HOMEDIR": info["homedir"],
        "UI_MY_IP": info["ip"],
    }
    for k, v in exports.items():
        print(f"export {k}={shlex.quote(str(v or ''))}")


def render_csv(info):
    buf = io.StringIO()
    writer = csv.writer(buf)
    fields = [
        "mode", "username", "main_domain", "owner", "plan", "email",
        "ip", "ip_type", "homedir", "docroot", "suspended",
        "processes", "cpu_perc", "mem_perc", "disk_mb", "inodes_used",
    ]
    writer.writerow(fields)
    writer.writerow([info.get(f, "") for f in fields])
    sys.stdout.write(buf.getvalue())


def main():
    parser = argparse.ArgumentParser(
        prog="ui.sh",
        description="Unified cPanel & Linux Account Inspector (v2.0.0)",
    )
    parser.add_argument("target", nargs="?", default=".", help="Username, domain, or '.' for CWD auto-detection")
    parser.add_argument("-l", "--list", action="store_true", help="List addon, sub, and parked domains")
    parser.add_argument("-s", "--ssl", action="store_true", help="Inspect SSL certificate metadata")
    parser.add_argument("-n", "--ns", action="store_true", help="Show configured nameservers")
    parser.add_argument("-t", "--tempurl", action="store_true", help="Show temporary cPanel URL")
    parser.add_argument("-d", "--debug", action="store_true", help="Show threshold diagnostics and warnings")
    parser.add_argument("-e", "--env", action="store_true", help="Print safe Bash export variables")
    parser.add_argument("-o", "--output", choices=["table", "json", "csv"], default="table", help="Output format")
    parser.add_argument("-q", "--quiet", action="store_true", help="Minimal output")
    parser.add_argument("--no-color", action="store_true", help="Disable ANSI colors")
    parser.add_argument("--cpanel-root", default="/var/cpanel", help="Custom cPanel state root (default: /var/cpanel)")
    parser.add_argument("--etc-root", default="/etc", help="Custom /etc root (default: /etc)")
    parser.add_argument("-v", "--version", action="version", version=f"ui.sh {VERSION}")
    args = parser.parse_args()

    target = args.target
    if target == ".":
        detected = detect_target_from_cwd(os.getcwd())
        if detected:
            target = detected
        else:
            target = pwd.getpwuid(os.getuid()).pw_name

    cp_user, matched_dom = resolve_cpanel_user(target, args.etc_root, args.cpanel_root)
    if cp_user:
        info = gather_cpanel_info(cp_user, matched_dom, args.etc_root, args.cpanel_root, args)
    else:
        info = gather_linux_info(target, args.etc_root, args)

    if not info:
        sys.stderr.write(f"Error: account or domain '{target}' not found.\n")
        sys.exit(1)

    if args.env:
        render_env(info)
        return

    if args.output == "json":
        print(json.dumps(info, indent=2))
    elif args.output == "csv":
        render_csv(info)
    else:
        use_color = sys.stdout.isatty() and not args.no_color
        render_table(info, args, Colors(enabled=use_color))


if __name__ == "__main__":
    main()
EOF

python3 -c "$PY_SCRIPT" "$@"

import subprocess
import platform
import sys
import os
import re
import argparse
import threading
import time
import shutil
import datetime

# Global summary for partial report generation on abort
results_summary = []


def safe_run(cmd_list, shell=False):
    """Executes a command safely, catching errors and returning output."""
    try:
        if not shell and not shutil.which(cmd_list[0]):
            return None

        result = subprocess.run(
            cmd_list,
            shell=shell,
            capture_output=True,
            text=True,
            timeout=5
        )
        return result.stdout.strip()
    except Exception:
        return None


def get_detailed_os():
    """Returns OS in the format: OS: Name (Version)."""
    # 1. Android / Termux
    if os.path.exists('/data/data/com.termux'):
        android_ver = safe_run(["getprop", "ro.build.version.release"]) or "?"
        ui_ver = safe_run(["getprop", "ro.build.version.ota"]) or ""
        name = "Android"
        if "RMX" in ui_ver: name = "Realme UI"
        return f"OS: {name} (Android {android_ver})"

    # 2. Linux (WSL vs Native)
    if platform.system() == "Linux":
        uname = safe_run(["uname", "-r"]) or ""
        if "microsoft" in uname.lower():
            distro = "Linux"
            if os.path.exists("/etc/os-release"):
                try:
                    with open("/etc/os-release") as f:
                        content = f.read()
                        name_match = re.search(r'PRETTY_NAME="([^"]+)"', content)
                        if name_match: distro = name_match.group(1).replace('"', '')
                except:
                    pass
            return f"OS: WSL ({distro})"

        # Native Linux
        distro = "Linux"
        if os.path.exists("/etc/os-release"):
            try:
                with open("/etc/os-release") as f:
                    content = f.read()
                    name_match = re.search(r'PRETTY_NAME="([^"]+)"', content)
                    if name_match: distro = name_match.group(1).replace('"', '')
            except:
                pass
        return f"OS: {distro}"

    # 3. Windows
    if platform.system() == "Windows":
        return f"OS: Windows (Windows {platform.release()})"

    return f"OS: {platform.system()} ({platform.release()})"


def get_active_network_mode(sys_os_str):
    """Determines network mode. Forces 'Wireless' for Android to fix Termux detection issues."""

    # --- FIX FOR ANDROID/REALME ---
    if "Android" in sys_os_str or "Realme" in sys_os_str:
        return "Wireless"
    # ------------------------------

    # 1. Windows & WSL
    if "Windows" in sys_os_str or "WSL" in sys_os_str:
        ps_script = (
            '$h = Get-NetAdapter | Where-Object { $_.HardwareInterface -and $_.Status -eq "Up" } | '
            'Sort-Object InterfaceMetric | Select-Object -First 1; '
            'if (!$h) { "Disconnected" } '
            'elseif ($h.Name -match "Wi-Fi|Wireless") { "Wireless" } '
            'else { "Wired" }'
        )
        try:
            res = subprocess.run(
                ["powershell.exe", "-NoProfile", "-Command", ps_script],
                capture_output=True, text=True
            )
            mode = res.stdout.strip()
            return mode if mode else "Unknown"
        except (FileNotFoundError, subprocess.CalledProcessError):
            return "Unknown (PS Failed)"

    # 2. Native Linux
    try:
        route_out = safe_run(["ip", "route", "get", "8.8.8.8"])
        if route_out and "dev" in route_out:
            iface = re.search(r"dev (\w+)", route_out).group(1)
            if any(x in iface for x in ["wlan", "wifi", "mlan", "wlp"]):
                return "Wireless"
            return "Wired"
        else:
            return "Disconnected"
    except:
        return "Disconnected"


def parse_ping_stats(output, target_name):
    """Analyses raw output for Min/Max/Avg and Jitter."""
    stats = {"name": target_name, "min": "X", "max": "X", "avg": "X", "jitter": "X", "status": "Fail", "sent": 10,
             "recv": 0}

    if not output: return stats

    sent_m = re.search(r"Sent = (\d+)|(\d+) packets transmitted", output)
    recv_m = re.search(r"Received = (\d+)|(\d+) received", output)
    if sent_m: stats["sent"] = sent_m.group(1) or sent_m.group(2)
    if recv_m: stats["recv"] = recv_m.group(1) or recv_m.group(2)

    unix_m = re.search(r"rtt min/avg/max/mdev = ([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+)", output)
    win_m = re.search(r"Minimum = (\d+)ms, Maximum = (\d+)ms, Average = (\d+)ms", output)

    if unix_m:
        stats.update({"min": unix_m.group(1), "avg": unix_m.group(2), "max": unix_m.group(3), "jitter": unix_m.group(4),
                      "status": "Pass"})
    elif win_m:
        jit = int(win_m.group(2)) - int(win_m.group(1))
        stats.update(
            {"min": win_m.group(1), "max": win_m.group(2), "avg": win_m.group(3), "jitter": str(jit), "status": "Pass"})

    return stats


def run_trace(target_ip="8.8.8.8"):
    """
    Runs the appropriate trace tool based on OS availability.
    Windows: tracert
    Linux/Android: mtr -> traceroute -> tracepath
    """
    system = platform.system()
    tool_cmd = None
    tool_name = "Unknown"

    if system == "Windows":
        if shutil.which("tracert"):
            tool_name = "tracert (Windows)"
            # -d: Do not resolve addresses to hostnames (faster)
            # -h 15: Max 15 hops
            tool_cmd = ["tracert", "-d", "-h", "15", target_ip]
    else:
        # Linux / Android Logic
        # Priority 1: mtr (Best for analysis)
        if shutil.which("mtr"):
            tool_name = "mtr (Linux)"
            # --report: Text mode output
            # --report-cycles=1: Fast single pass
            # -n: No DNS lookup
            tool_cmd = ["mtr", "--report", "--report-cycles=1", "-n", target_ip]

        # Priority 2: traceroute (Standard)
        elif shutil.which("traceroute"):
            tool_name = "traceroute"
            # -n: No DNS
            # -m 15: Max 15 hops
            tool_cmd = ["traceroute", "-n", "-m", "15", target_ip]

        # Priority 3: tracepath (Common non-root fallback)
        elif shutil.which("tracepath"):
            tool_name = "tracepath"
            # -n: No DNS
            tool_cmd = ["tracepath", "-n", target_ip]

    if not tool_cmd:
        return "Trace tool not found (install mtr, traceroute, or tracepath)", "None"

    try:
        # Increase timeout for trace as it takes longer than ping
        result = subprocess.run(tool_cmd, capture_output=True, text=True, timeout=45)
        return result.stdout.strip(), tool_name
    except subprocess.TimeoutExpired:
        return "Trace timed out.", tool_name
    except Exception as e:
        return f"Trace failed: {str(e)}", tool_name


def print_final_report(net_mode, start_time_str, trace_output=None, trace_tool=None):
    """Renders the statistical report table and trace data."""
    print(f"\n\n--- STATISTICAL SUMMARY ({start_time_str} | Mode: {net_mode}) ---")
    header = f"{'Target':<12} | {'Status':<6} | {'Sent/Recv':<10} | {'Min':<8} | {'Max':<8} | {'Avg':<8} | {'Jitter'}"
    print(header)
    print("-" * len(header))
    for res in results_summary:
        sr = f"{res['sent']}/{res['recv']}"
        print(
            f"{res['name']:<12} | {res['status']:<6} | {sr:<10} | {res['min']:>6}ms | {res['max']:>6}ms | {res['avg']:>6}ms | {res['jitter']}ms")

    if trace_output:
        print(f"\n--- PATH ANALYSIS (Tool: {trace_tool}) ---")
        print(trace_output)
        print("-" * 60)


def spinner_animation(stop_event, msg="Probing"):
    """Termux-safe spinner."""
    chars = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    idx = 0
    while not stop_event.is_set():
        sys.stdout.write(f"\033[2K\r{chars[idx % len(chars)]} {msg}... (Ctrl+C to stop)")
        sys.stdout.flush()
        idx += 1
        time.sleep(0.08)


def run_diagnostic(verbose=False):
    targets = {"Router": "192.168.0.1", "Indinet": "10.36.84.1", "Google": "8.8.8.8", "Cloudflare": "1.1.1.1"}

    now = datetime.datetime.now()
    ts_str = now.strftime("%Y-%m-%d %H:%M:%S")

    try:
        os_info = get_detailed_os()
    except Exception:
        os_info = "OS: Unknown"

    try:
        net_mode = get_active_network_mode(os_info)
    except Exception:
        net_mode = "Unknown"

    print(f"\n{'=' * 80}")
    print(f" TIME: {ts_str}")
    print(f" {os_info} | NET: {net_mode}")
    print(f"{'=' * 80}")

    if "Disconnected" in net_mode:
        print("\n[!] Error: Network is Disconnected.")
        return

    ping_cmd_base = "ping"
    if not shutil.which(ping_cmd_base):
        print("[!] Critical: 'ping' command not found.")
        return

    stop_spinner = threading.Event()

    # --- STEP 1: PING STATISTICS ---
    spinner_thread = threading.Thread(target=spinner_animation, args=(stop_spinner, "Pinging"))
    if not verbose: spinner_thread.start()

    try:
        for name, ip in targets.items():
            ping_args = [ping_cmd_base, "-n" if platform.system() == "Windows" else "-c", "10", ip]
            try:
                process = subprocess.Popen(ping_args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                full_output = ""
                for line in process.stdout:
                    full_output += line
                    if verbose: sys.stdout.write(line)
                process.wait()
                results_summary.append(parse_ping_stats(full_output, name))
            except Exception:
                results_summary.append(
                    {"name": name, "min": "X", "max": "X", "avg": "ERR", "jitter": "X", "status": "Fail", "sent": 10,
                     "recv": 0})
    finally:
        if not verbose:
            stop_spinner.set()
            spinner_thread.join()

    # --- STEP 2: TRACE ANALYSIS ---
    # We restart the spinner with a new message because trace takes time
    print("\n")  # Newline for clean output
    stop_spinner = threading.Event()
    spinner_thread = threading.Thread(target=spinner_animation, args=(stop_spinner, "Tracing Path"))
    if not verbose: spinner_thread.start()

    trace_out, trace_tool = run_trace("8.8.8.8")

    if not verbose:
        stop_spinner.set()
        spinner_thread.join()

    print_final_report(net_mode, ts_str, trace_out, trace_tool)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()
    try:
        run_diagnostic(args.verbose)
    except KeyboardInterrupt:
        print("\n\n[!] Interrupt detected. Compiling partial report...")
# Ping Test

Part of the **[Nexus](../../README.md)** toolkit — `python/ping-test/`.

Multi-target connectivity checker: probes a list of hosts **in parallel threads**, classifies
each failure (DNS, no route, timeout, filter), and prints a summary report that survives a
`Ctrl+C`.

## Usage

```bat
python net_check.py
python net_check.py --verbose
```

`Ctrl+C` aborts the run but still compiles the partial report, so an interrupted sweep is
useful rather than lost.

## What it reports

| Field | Meaning |
| --- | --- |
| target | hostname or IP tested |
| DNS | resolution result / failure |
| latency | probe round-trip |
| status | reachable / timeout / unreachable |
| diagnosis | the likely cause, phrased for a human |

## Requirements

- Python 3.7+, no third-party packages.
- Uses the platform ping (`ping -n` / `ping -c`) via `subprocess`, so it honours system routing
  and firewall policy exactly like the shell would.
- `--verbose` adds per-probe command output.

## Notes

- Each probe has a 5 s subprocess timeout; the thread pool keeps a long target list quick.
- ICMP may be blocked while the host is still up — a timeout is not the same as "offline".

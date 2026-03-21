#!/usr/bin/env bash
set -euo pipefail

hdr(){ printf '\n=== %s ===\n' "$*"; }

hdr "CPU / Topology"
lscpu || true
lscpu --extended=CPU,CORE,SOCKET,NODE,ONLINE 2>/dev/null || true

hdr "NUMA"
numactl --hardware 2>/dev/null || echo "numactl not installed"

hdr "Memory (capacity & speed)"
free -h || true
sudo dmidecode -t memory 2>/dev/null | egrep -i 'Size:|Speed:|Type:|Locator|Configured Memory Speed' || echo "dmidecode needs sudo"

hdr "OS / Kernel"
uname -a
cat /etc/os-release || true

hdr "Freq governor / Turbo"
echo "driver: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo NA)"
echo "governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo NA)"
echo "intel_pstate.no_turbo: $(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo NA)"
echo "cpufreq.boost: $(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || echo NA)"

hdr "Toolchain"
(gcc --version || true) | head -n1
(clang --version || true) | head -n1
(ld --version || true) | head -n1
(ldd --version || true) | head -n1
(ghc --version || true)

hdr "Storage"
lsblk -o NAME,MODEL,SIZE,TYPE,ROTA
(nvme list 2>/dev/null || true)

hdr "Repo versions (if inside repos)"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Current repo: $(basename "$(git rev-parse --show-toplevel)") @ $(git rev-parse --short HEAD)"
fi

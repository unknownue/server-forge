#!/bin/bash
# Hardware information collector for mac-mini-m4 (Apple Silicon / macOS).
#
# The shared scripts/lib/hardware-info.sh is Linux-only (lscpu, free, dmidecode,
# lsblk, lspci) and produces almost nothing on Darwin, so this node ships its own
# collector. It emits the same section headings as the shared script so reports
# stay comparable across the fleet.
#
# Usage: bash nodes/mac-mini-m4/provision/collect-hardware-info.sh

set -eu

collect_cpu() {
    echo "=== CPU ==="
    system_profiler SPHardwareDataType 2>/dev/null \
        | grep -E 'Model Name|Model Identifier|Chip|Total Number of Cores|Memory|Serial|Hardware UUID' \
        | sed 's/^ *//'
    echo ""
    echo "SoC topology:"
    sysctl -n hw.perflevel0.physicalcpu 2>/dev/null \
        | awk '{print "  Performance cores: " $1}'
    sysctl -n hw.perflevel1.physicalcpu 2>/dev/null \
        | awk '{print "  Efficiency cores:  " $1}'
    sysctl -n hw.ncpu 2>/dev/null | awk '{print "  Logical CPUs:      " $1}'
    echo "  Architecture:      $(uname -m)"
}

collect_ram() {
    echo "=== RAM ==="
    local bytes
    bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
    echo "Total: $(echo "$bytes" | awk '{printf "%.0f GB\n", $1/1024/1024/1024}') (${bytes} bytes)"
    echo ""
    echo "NOTE: Apple Silicon uses unified memory soldered to the SoC package."
    echo "      No DIMM slots — memory is NOT upgradeable after purchase."
    echo "      The GPU shares this same 16 GB pool (no dedicated VRAM)."
}

collect_motherboard() {
    echo "=== Motherboard (Logic Board) ==="
    # Apple Silicon exposes no DMI/sysfs; SMBIOS data comes from ioreg.
    ioreg -c IOPlatformExpertDevice 2>/dev/null \
        | grep -E 'board-id|model|manufacturer|IOPlatformSerialNumber' \
        | sed 's/^ *//' || echo "Logic board info not available."
    echo ""
    echo "=== Boot / Firmware ==="
    system_profiler SPHardwareDataType 2>/dev/null \
        | grep -E 'System Firmware Version|OS Loader Version|Provisioning UDID' \
        | sed 's/^ *//'
    echo ""
    echo "Secure Enclave / boot policy:"
    # bputil requires sudo; report only whether the tool is present.
    if command -v bputil &>/dev/null; then
        echo "  bputil available — run 'sudo bputil -d' manually to inspect boot policy."
    else
        echo "  bputil not available."
    fi
}

collect_gpus() {
    echo "=== GPU Devices ==="
    system_profiler SPDisplaysDataType 2>/dev/null \
        | grep -E 'Chipset Model|Type:|Bus:|Total Number of Cores|Vendor|Metal Support|Resolution|Main Display' \
        | sed 's/^ *//'
    echo ""
    echo "NOTE: Integrated Apple GPU — no discrete GPU, no NVIDIA/CUDA, no ROCm."
    echo "      Accelerators available: Metal 3 / MPS (PyTorch 'mps' device), CoreML, MLX."
}

collect_storage() {
    echo "=== Storage (diskutil) ==="
    diskutil list 2>/dev/null
    echo ""
    echo "=== APFS Containers ==="
    diskutil apfs list 2>/dev/null | grep -E 'APFS Container Reference|Size \(Capacity|Capacity In Use|Capacity Not Allocated|Name:|Capacity Consumed|Mount Point|FileVault' \
        | sed 's/^ *//'
    echo ""
    echo "=== Filesystem Usage ==="
    df -h
    echo ""
    echo "NOTE: The internal SSD is soldered — capacity cannot be expanded internally."
    echo "      Use external Thunderbolt/USB storage for bulk data."
}

collect_os() {
    echo "=== OS ==="
    echo "ProductName:    $(sw_vers -productName)"
    echo "ProductVersion: $(sw_vers -productVersion)"
    echo "BuildVersion:   $(sw_vers -buildVersion)"
    echo ""
    echo "=== Kernel ==="
    uname -a
}

collect_network() {
    echo "=== Network ==="
    system_profiler SPNetworkDataType 2>/dev/null \
        | grep -E '^ {4}[A-Za-z].*:$|BSD Device Name|MAC Address|Configuration Method|Media Subtype' \
        | sed 's/^ *//'
    echo ""
    echo "=== Active IPv4 Addresses ==="
    for iface in $(ifconfig -l 2>/dev/null); do
        addr=$(ipconfig getifaddr "$iface" 2>/dev/null || true)
        [[ -n "$addr" ]] && printf "  %-8s %s\n" "$iface" "$addr"
    done
    echo ""
    echo "=== Default Route ==="
    netstat -rn -f inet 2>/dev/null | awk 'NR<=5'
}

collect_all() {
    collect_cpu;      echo ""
    collect_ram;      echo ""
    collect_motherboard; echo ""
    collect_gpus;     echo ""
    collect_storage;  echo ""
    collect_network;  echo ""
    collect_os
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    collect_all
fi
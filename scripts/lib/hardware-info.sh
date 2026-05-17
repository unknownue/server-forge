#!/bin/bash
# Generic hardware information collector.
# Uses standard Linux tools only — no vendor-specific logic.
# Usage: bash scripts/lib/hardware-info.sh
# Source and call individual functions for programmatic use.

set -eu

collect_cpu() {
    echo "=== CPU ==="
    if command -v lscpu &>/dev/null; then
        lscpu | grep -E 'Architecture|Model name|Socket|Core|Thread|CPU\(s\)|NUMA' || true
    else
        echo "Model: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
        echo "Cores: $(grep -c '^processor' /proc/cpuinfo)"
    fi
}

collect_ram() {
    echo "=== RAM ==="
    free -h 2>/dev/null || cat /proc/meminfo 2>/dev/null | head -3

    if command -v dmidecode &>/dev/null; then
        echo ""
        echo "=== DIMM Slots ==="
        sudo dmidecode -t memory 2>/dev/null | grep -E '^\s*(Size|Locator|Type|Speed|Manufacturer):' || echo "dmidecode memory info not available (may need root)."
    else
        echo "dmidecode not installed."
    fi
}

collect_motherboard() {
    echo "=== Motherboard ==="
    local dmi="/sys/devices/virtual/dmi/id"
    if [[ -d "$dmi" ]]; then
        for field in sys_vendor product_name product_version board_vendor board_name board_version bios_version bios_date; do
            local file="${dmi}/${field}"
            if [[ -f "$file" ]]; then
                printf "%-20s %s\n" "${field}:" "$(cat "$file" 2>/dev/null || echo 'N/A')"
            fi
        done
    elif command -v dmidecode &>/dev/null; then
        sudo dmidecode -t baseboard 2>/dev/null || echo "dmidecode baseboard info not available."
        echo ""
        sudo dmidecode -t bios 2>/dev/null || true
    else
        echo "DMI info not available."
    fi
}

collect_gpus() {
    echo "=== GPU Devices (lspci) ==="
    if command -v lspci &>/dev/null; then
        lspci -nn -d '::03xx' 2>/dev/null || echo "No GPU-class devices found."
    else
        echo "lspci not available."
    fi

    if command -v nvidia-smi &>/dev/null; then
        echo ""
        echo "=== NVIDIA GPU Details ==="
        nvidia-smi --query-gpu=index,name,pci.bus_id,driver_version,memory.total --format=csv 2>/dev/null || echo "nvidia-smi query failed."
    fi
}

collect_storage() {
    echo "=== Storage (lsblk) ==="
    if command -v lsblk &>/dev/null; then
        lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE 2>/dev/null || echo "lsblk not available."
    else
        echo "lsblk not available."
    fi

    echo ""
    echo "=== LVM Volumes ==="
    if command -v lvs &>/dev/null; then
        lvs 2>/dev/null || echo "No LVM volumes."
    else
        echo "LVM tools not installed."
    fi
}

collect_os() {
    echo "=== OS ==="
    if [[ -f /etc/os-release ]]; then
        grep -E '^NAME=|^VERSION=' /etc/os-release || true
    else
        echo "/etc/os-release not found."
    fi

    echo ""
    echo "=== Kernel ==="
    uname -a
}

collect_all() {
    collect_cpu
    echo ""
    collect_ram
    echo ""
    collect_motherboard
    echo ""
    collect_gpus
    echo ""
    collect_storage
    echo ""
    collect_os
}

# Execute when run directly.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    collect_all
fi

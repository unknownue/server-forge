# Hardware info collector for Windows nodes (server-forge).
# Writes sections matching scripts/lib/hardware-info.sh output style.

Write-Output "=== CPU ==="
$cpu = Get-CimInstance Win32_Processor
foreach ($c in $cpu) {
    Write-Output ("Model name:            " + $c.Name)
    Write-Output ("Cores / Threads:       " + $c.NumberOfCores + " / " + $c.NumberOfLogicalProcessors)
    Write-Output ("Max clock:             " + $c.MaxClockSpeed + " MHz")
    Write-Output ("Socket:                " + $c.SocketDesignation)
}

Write-Output ""
Write-Output "=== RAM ==="
$os = Get-CimInstance Win32_OperatingSystem
Write-Output ("Total physical:        " + [math]::Round($os.TotalVisibleMemorySize/1MB, 1) + " GiB")
Write-Output ("Free physical:         " + [math]::Round($os.FreePhysicalMemory/1MB, 1) + " GiB")
$dimm = Get-CimInstance Win32_PhysicalMemory
foreach ($m in $dimm) {
    Write-Output ("DIMM " + $m.DeviceLocator + ": " + [math]::Round($m.Capacity/1GB) + " GB " + $m.Speed + " MT/s " + $m.Manufacturer + " " + $m.PartNumber)
}

Write-Output ""
Write-Output "=== Motherboard ==="
$mb = Get-CimInstance Win32_BaseBoard
Write-Output ("Board:                 " + $mb.Manufacturer + " " + $mb.Product)
$bios = Get-CimInstance Win32_BIOS
Write-Output ("BIOS:                  " + $bios.SMBIOSBIOSVersion + " (" + $bios.ReleaseDate + ")")
$cs = Get-CimInstance Win32_ComputerSystem
Write-Output ("System:                " + $cs.Manufacturer + " " + $cs.Model)

Write-Output ""
Write-Output "=== GPU Devices ==="
$gpu = Get-CimInstance Win32_VideoController
foreach ($g in $gpu) {
    Write-Output ($g.Name + "  [driver " + $g.DriverVersion + ", " + [math]::Round($g.AdapterRAM/1GB) + " GB reported]")
}
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    Write-Output ""
    Write-Output "=== NVIDIA GPU Details ==="
    nvidia-smi --query-gpu=index,name,pci.bus_id,driver_version,memory.total --format=csv
}

Write-Output ""
Write-Output "=== Storage ==="
Get-CimInstance Win32_DiskDrive | ForEach-Object {
    Write-Output ($_.DeviceID + "  " + [math]::Round($_.Size/1GB) + " GB  " + $_.Model + "  [" + $_.MediaType + "]")
}
Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
    Write-Output ("Volume " + $_.DeviceID + "  " + [math]::Round($_.Size/1GB) + " GB total, " + [math]::Round($_.FreeSpace/1GB) + " GB free  " + $_.VolumeName + "  [" + $_.FileSystem + "]")
}

Write-Output ""
Write-Output "=== OS ==="
Write-Output ("Name:                  " + $os.Caption)
Write-Output ("Version:               " + $os.Version + " (build " + $os.BuildNumber + ")")
Write-Output ("Install date:          " + $os.InstallDate)
Write-Output ("Hostname:              " + $env:COMPUTERNAME)
Write-Output ("PowerShell:            " + $PSVersionTable.PSVersion.ToString())

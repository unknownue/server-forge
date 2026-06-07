<script setup lang="ts">
import { ref, onMounted, onUnmounted } from 'vue'
import { api, type GPUStatus, type CurrentProfile, type ProfileDetail } from '../api'

const gpus = ref<GPUStatus[]>([])
const current = ref<CurrentProfile | null>(null)
const detail = ref<ProfileDetail | null>(null)
let timer: number

async function refresh() {
  try {
    const [gRes, cRes] = await Promise.all([api.getGpus(), api.getCurrent()])
    gpus.value = gRes.gpus
    current.value = cRes
    if (cRes.profile) {
      detail.value = await api.getProfile(cRes.profile)
    } else {
      detail.value = null
    }
  } catch {}
}

onMounted(() => {
  refresh()
  timer = window.setInterval(refresh, 5000)
})
onUnmounted(() => clearInterval(timer))

interface SlotInfo {
  gpuId: number
  gpuName: string
  model: string
  role: string
  port: string
  tp: number
  occupied: boolean
  multiGpu: boolean
}

function buildSlots(): SlotInfo[] {
  if (!detail.value) {
    return gpus.value.map(g => ({
      gpuId: g.id,
      gpuName: g.name,
      model: '',
      role: 'free',
      port: '',
      tp: 0,
      occupied: false,
      multiGpu: false,
    }))
  }

  const slotMap = new Map<number, SlotInfo>()
  for (const g of gpus.value) {
    slotMap.set(g.id, {
      gpuId: g.id,
      gpuName: g.name,
      model: '',
      role: 'free',
      port: '',
      tp: 0,
      occupied: false,
      multiGpu: false,
    })
  }

  for (const alloc of detail.value.gpu_allocation) {
    const gpuIds: number[] = alloc.gpu || []
    if (gpuIds.length === 0) continue
    const model = alloc.model_short || alloc.model || ''
    const role = alloc.role || ''
    const port = alloc.port ? `:${alloc.port}` : ''
    const tp = alloc.tp || gpuIds.length
    const multiGpu = gpuIds.length > 1

    for (const id of gpuIds) {
      const slot = slotMap.get(id)
      if (slot) {
        slot.model = model
        slot.role = role
        slot.port = port
        slot.tp = tp
        slot.occupied = true
        slot.multiGpu = multiGpu
      }
    }
  }

  return Array.from(slotMap.values()).sort((a, b) => a.gpuId - b.gpuId)
}

const slots = ref<SlotInfo[]>([])
let slotTimer: number

onMounted(() => {
  const update = () => { slots.value = buildSlots() }
  update()
  slotTimer = window.setInterval(update, 5000)
})
onUnmounted(() => clearInterval(slotTimer))
</script>

<template>
  <div class="section-title">
    GPU Topology
    <span v-if="current?.profile" style="font-size: 14px; color: var(--text2); font-weight: 400;">
      — {{ current.profile }}
    </span>
    <span v-else style="font-size: 14px; color: var(--text2); font-weight: 400;">
      — no active profile
    </span>
  </div>

  <div class="topology">
    <template v-for="(slot, i) in slots" :key="slot.gpuId">
      <div v-if="i > 0 && slot.multiGpu && slots[i-1]?.multiGpu && slots[i-1]?.model === slot.model" class="tp-bond">
        <div class="line"></div>
        <span>TP={{ slot.tp }}</span>
        <div class="line"></div>
      </div>
      <div class="topo-slot" :class="slot.occupied ? 'occupied' : 'free'">
        <div class="slot-gpu">GPU {{ slot.gpuId }}</div>
        <div class="slot-model">{{ slot.occupied ? slot.model : 'Idle' }}</div>
        <div class="slot-role">{{ slot.occupied ? slot.role : '' }}</div>
        <div v-if="slot.port" class="slot-port">{{ slot.port }}</div>
      </div>
    </template>
  </div>

  <div v-if="slots.length === 0" class="empty">
    No GPU data available
  </div>
</template>

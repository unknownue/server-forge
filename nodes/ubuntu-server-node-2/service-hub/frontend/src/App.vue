<script setup lang="ts">
import { onMounted, onUnmounted, ref } from 'vue'
import { api } from './api'
import type { GPUStatus, P2PStatus, ProfileDetail, ProfileInfo } from './api'
import GpuCard from './components/GpuCard.vue'
import ProfileList from './components/ProfileList.vue'

const gpus = ref<GPUStatus[]>([])
const profiles = ref<ProfileInfo[]>([])
const details = ref<Record<string, ProfileDetail>>({})
const current = ref<string | null>(null)
const p2p = ref<P2PStatus | null>(null)
const history = ref<any[]>([])
const logs = ref<Array<{ t: string; msg: string; kind: string }>>([])
const busy = ref<string | null>(null)
const error = ref<string | null>(null)
let timer: number | undefined

function log(msg: string, kind = '') {
  const t = new Date().toLocaleTimeString()
  logs.value.unshift({ t, msg, kind })
  if (logs.value.length > 100) logs.value.pop()
}

async function refresh() {
  try {
    const [g, c, p] = await Promise.all([api.gpus(), api.current(), api.profiles()])
    gpus.value = g.gpus
    current.value = c.profile
    profiles.value = p.profiles

    // Fetch per-profile detail (includes live service state) in parallel.
    const entries = await Promise.all(
      p.profiles.map(async (x) => [x.name, await api.profile(x.name)] as const),
    )
    details.value = Object.fromEntries(entries)
    error.value = null
  } catch (e: any) {
    error.value = e.message ?? String(e)
  }
}

async function loadStatic() {
  try {
    p2p.value = await api.p2p()
    history.value = (await api.history()).history
  } catch { /* non-fatal */ }
}

async function doSwitch(name: string) {
  busy.value = name
  log(`Starting profile "${name}" — this can take a few minutes…`)
  try {
    const r = await api.switch(name)
    log(
      `Profile "${r.profile}" started in ${r.elapsed_seconds}s` +
        (r.stopped_containers.length ? ` (stopped: ${r.stopped_containers.join(', ')})` : ''),
      'ok',
    )
  } catch (e: any) {
    log(`Switch failed: ${e.message ?? e}`, 'err')
  } finally {
    busy.value = null
    await refresh()
    await loadStatic()
  }
}

async function doStop() {
  busy.value = '__stop__'
  log('Stopping all managed containers…')
  try {
    const r = await api.stop()
    log(`Stopped ${r.stopped_containers.length} container(s) in ${r.elapsed_seconds}s`, 'ok')
  } catch (e: any) {
    log(`Stop failed: ${e.message ?? e}`, 'err')
  } finally {
    busy.value = null
    await refresh()
    await loadStatic()
  }
}

onMounted(async () => {
  await refresh()
  await loadStatic()
  timer = window.setInterval(refresh, 10000)
})
onUnmounted(() => { if (timer) clearInterval(timer) })
</script>

<template>
  <div class="app">
    <header class="top">
      <h1>Service Hub</h1>
      <span class="sub">ubuntu-server-node-2 · 2× Radeon RX 7900 XTX</span>
    </header>

    <!-- P2P status is surfaced because multi-GPU profiles silently degrade to
         host-staged collectives without the patched kernel + RCCL. -->
    <div v-if="p2p" class="banner" :class="p2p.kernel_patched && p2p.peer_access !== false ? '' : 'warn'">
      <span class="dot" :style="{ background: p2p.kernel_patched && p2p.peer_access !== false ? 'var(--good)' : 'var(--warn)' }" />
      <span>
        <b>P2P:</b> kernel <code>{{ p2p.kernel }}</code>
        <template v-if="p2p.peer_access === true"> · peer access <b>available</b></template>
        <template v-else-if="p2p.peer_access === false"> · peer access <b>UNAVAILABLE</b></template>
        — {{ p2p.detail }}
      </span>
    </div>

    <div v-if="error" class="banner bad">
      <span class="dot" style="background: var(--bad)" />
      <span>Backend error: {{ error }}</span>
    </div>

    <div class="toolbar">
      <button :disabled="!!busy" @click="refresh">Refresh</button>
      <button class="danger" :disabled="!!busy" @click="doStop">
        <span v-if="busy === '__stop__'" class="spin">◌</span>
        {{ busy === '__stop__' ? 'stopping…' : 'Stop all' }}
      </button>
      <span class="muted" v-if="busy">operation in progress — controls disabled</span>
    </div>

    <div class="grid" style="margin-bottom: 22px">
      <GpuCard v-for="g in gpus" :key="g.id" :gpu="g" />
    </div>

    <div class="grid" style="grid-template-columns: minmax(0, 2fr) minmax(0, 1fr)">
      <div class="card">
        <h2>Profiles</h2>
        <ProfileList
          :profiles="profiles"
          :details="details"
          :current="current"
          :busy="busy"
          @switch="doSwitch"
        />
      </div>

      <div class="card">
        <h2>Recent activity</h2>
        <div v-if="!logs.length" class="muted">No actions yet this session.</div>
        <div v-else class="log">
          <div v-for="(l, i) in logs" :key="i" :class="l.kind">
            [{{ l.t }}] {{ l.msg }}
          </div>
        </div>

        <h2 style="margin-top: 18px">Switch history</h2>
        <div v-if="!history.length" class="muted">No recorded switches.</div>
        <div v-else class="history">
          <div v-for="(h, i) in history.slice(0, 12)" :key="i" class="h">
            <span>{{ new Date(h.at).toLocaleString() }}</span>
            <span>{{ h.action }}</span>
            <span>{{ h.profile ?? '—' }}</span>
            <span :style="{ color: h.ok ? 'var(--good)' : 'var(--bad)' }">{{ h.ok ? 'ok' : 'failed' }}</span>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>
<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { api, type CurrentProfile } from './api'
import GpuCards from './components/GpuCards.vue'
import ProfileList from './components/ProfileList.vue'
import TopologyView from './components/TopologyView.vue'
import SwitchHistory from './components/SwitchHistory.vue'
import ClaspPanel from './components/ClaspPanel.vue'

const tab = ref<'gpus' | 'profiles' | 'clasp' | 'topology' | 'history'>('gpus')
const current = ref<CurrentProfile | null>(null)
const switching = ref(false)
const toast = ref<{ text: string; type: string } | null>(null)

let toastTimer: number

function showToast(text: string, type = 'info') {
  toast.value = { text, type }
  clearTimeout(toastTimer)
  toastTimer = window.setTimeout(() => { toast.value = null }, 4000)
}

async function refresh() {
  try {
    current.value = await api.getCurrent()
  } catch {}
}

async function handleSwitch(name: string) {
  switching.value = true
  try {
    const res = await api.switchProfile(name)
    showToast(
      `Switched to ${res.new_profile} (${res.elapsed_seconds}s, stopped ${res.stopped_containers.length} containers)`,
      'success'
    )
    await refresh()
  } catch (e: any) {
    showToast(`Switch failed: ${e.message}`, 'error')
  } finally {
    switching.value = false
  }
}

async function handleStop() {
  try {
    const res = await api.stopAll()
    showToast(`Stopped ${res.stopped_containers.length} containers (${res.elapsed_seconds}s)`, 'success')
    await refresh()
  } catch (e: any) {
    showToast(`Stop failed: ${e.message}`, 'error')
  }
}

onMounted(refresh)

const tabs = [
  { key: 'gpus', label: 'GPU Status' },
  { key: 'profiles', label: 'Profiles' },
  { key: 'clasp', label: 'CLASP' },
  { key: 'topology', label: 'Topology' },
  { key: 'history', label: 'History' },
] as const
</script>

<template>
  <header>
    <h1>Service Hub</h1>
    <div style="display: flex; align-items: center; gap: 12px;">
      <span v-if="current?.profile" class="status-badge active">
        {{ current.profile }}
      </span>
      <span v-else class="status-badge idle">idle</span>
      <button class="btn btn-danger" @click="handleStop" :disabled="switching">Stop All</button>
    </div>
  </header>

  <div class="tabs">
    <button
      v-for="t in tabs"
      :key="t.key"
      class="tab"
      :class="{ active: tab === t.key }"
      @click="tab = t.key"
    >
      {{ t.label }}
    </button>
  </div>

  <div class="container">
    <GpuCards v-if="tab === 'gpus'" />
    <ProfileList
      v-if="tab === 'profiles'"
      :current-profile="current?.profile ?? null"
      :switching="switching"
      @switch="handleSwitch"
    />
    <ClaspPanel v-if="tab === 'clasp'" />
    <TopologyView v-if="tab === 'topology'" />
    <SwitchHistory v-if="tab === 'history'" />
  </div>

  <div v-if="toast" class="toast" :class="toast.type">
    {{ toast.text }}
  </div>
</template>

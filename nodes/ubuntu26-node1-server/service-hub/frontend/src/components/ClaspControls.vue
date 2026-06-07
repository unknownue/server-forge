<script setup lang="ts">
import { ref, onMounted, onUnmounted } from 'vue'
import { api, type ClaspStatus } from '../api'

const status = ref<ClaspStatus | null>(null)
const loading = ref(false)
let timer: number

async function refresh() {
  try {
    status.value = await api.getClaspStatus()
  } catch {}
}

async function handleStart() {
  loading.value = true
  try {
    await api.startClasp()
    await refresh()
  } catch (e: any) {
    console.error('CLASP start failed:', e)
  } finally {
    loading.value = false
  }
}

async function handleStop() {
  loading.value = true
  try {
    await api.stopClasp()
    await refresh()
  } catch (e: any) {
    console.error('CLASP stop failed:', e)
  } finally {
    loading.value = false
  }
}

onMounted(() => {
  refresh()
  timer = window.setInterval(refresh, 10000)
})
onUnmounted(() => clearInterval(timer))
</script>

<template>
  <div class="clasp-controls" v-if="status">
    <div class="clasp-status">
      <span
        class="clasp-indicator"
        :class="status.running && status.healthy ? 'healthy' : status.running ? 'unhealthy' : 'stopped'"
      ></span>
      <span class="clasp-label">CLASP</span>
    </div>
    <button
      v-if="!status.running"
      class="btn btn-primary btn-sm"
      :disabled="loading"
      @click="handleStart"
    >
      <span v-if="loading" class="spinner"></span>
      {{ loading ? 'Starting...' : 'Start' }}
    </button>
    <button
      v-else
      class="btn btn-danger btn-sm"
      :disabled="loading"
      @click="handleStop"
    >
      <span v-if="loading" class="spinner"></span>
      {{ loading ? 'Stopping...' : 'Stop' }}
    </button>
  </div>
</template>

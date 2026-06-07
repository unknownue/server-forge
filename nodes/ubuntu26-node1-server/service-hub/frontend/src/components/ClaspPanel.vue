<script setup lang="ts">
import { ref, onMounted, onUnmounted } from 'vue'
import { api, type ClaspStatus } from '../api'

const status = ref<ClaspStatus | null>(null)
const loading = ref(false)
const vllmPort = ref(8000)
const claspPort = ref(8080)
let timer: number

async function refresh() {
  try {
    status.value = await api.getClaspStatus(claspPort.value)
  } catch {}
}

onMounted(() => {
  refresh()
  timer = window.setInterval(refresh, 10000)
})
onUnmounted(() => clearInterval(timer))

async function handleStart() {
  loading.value = true
  try {
    await api.startClasp(vllmPort.value, claspPort.value)
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
    await api.stopClasp(claspPort.value)
    await refresh()
  } catch (e: any) {
    console.error('CLASP stop failed:', e)
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <div class="clasp-panel">
    <div class="clasp-header">
      <div class="clasp-title-row">
        <div class="clasp-id-badge" :class="status?.running ? 'running' : 'stopped'">
          <span class="clasp-icon">🔗</span>
        </div>
        <div class="clasp-info">
          <div class="clasp-name">CLASP Proxy</div>
          <div class="clasp-status-tag" :class="status?.running ? 'running' : 'stopped'">
            {{ status?.running ? (status?.healthy ? '● Healthy' : '● Running') : '○ Stopped' }}
          </div>
        </div>
      </div>

      <div class="clasp-config">
        <div class="config-field">
          <label>vLLM Port</label>
          <input
            type="number"
            v-model.number="vllmPort"
            :disabled="status?.running"
            min="1"
            max="65535"
          />
        </div>
        <div class="config-field">
          <label>CLASP Port</label>
          <input
            type="number"
            v-model.number="claspPort"
            :disabled="status?.running"
            min="1"
            max="65535"
          />
        </div>
        <div class="clasp-actions">
          <button
            v-if="!status?.running"
            class="btn btn-primary"
            :disabled="loading"
            @click="handleStart"
          >
            <span v-if="loading" class="spinner"></span>
            {{ loading ? 'Starting...' : 'Start CLASP' }}
          </button>
          <button
            v-else
            class="btn btn-danger"
            :disabled="loading"
            @click="handleStop"
          >
            <span v-if="loading" class="spinner"></span>
            {{ loading ? 'Stopping...' : 'Stop CLASP' }}
          </button>
        </div>
      </div>
    </div>

    <div v-if="status?.running" class="clasp-endpoints">
      <div class="endpoint-section">
        <h3>Endpoints</h3>
        <div class="endpoint-item">
          <span class="endpoint-label">Anthropic API:</span>
          <code>http://localhost:{{ claspPort }}/v1/messages</code>
        </div>
        <div class="endpoint-item">
          <span class="endpoint-label">Health:</span>
          <code>http://localhost:{{ claspPort }}/health</code>
        </div>
      </div>

      <div class="endpoint-section">
        <h3>Claude Code Configuration</h3>
        <div class="endpoint-item">
          <code>export ANTHROPIC_BASE_URL=http://localhost:{{ claspPort }}</code>
        </div>
        <div class="endpoint-item">
          <code>export ANTHROPIC_API_KEY=dummy</code>
        </div>
      </div>

      <div class="endpoint-section">
        <h3>Backend</h3>
        <div class="endpoint-item">
          <span class="endpoint-label">vLLM:</span>
          <code>http://localhost:{{ vllmPort }}/v1</code>
        </div>
        <div class="endpoint-item">
          <span class="endpoint-label">Container:</span>
          <code>{{ status.container }}</code>
        </div>
      </div>
    </div>

    <div v-else class="clasp-empty">
      CLASP proxy is not running. Configure ports and click "Start CLASP" to begin.
    </div>
  </div>
</template>

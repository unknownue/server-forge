<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { api, type HistoryEntry } from '../api'

const history = ref<HistoryEntry[]>([])

async function refresh() {
  try {
    const res = await api.getHistory()
    history.value = res.history.slice().reverse()
  } catch {}
}

onMounted(refresh)

function fmtTime(iso: string) {
  try {
    const d = new Date(iso)
    return d.toLocaleString()
  } catch {
    return iso
  }
}
</script>

<template>
  <div class="section-title">Switch History</div>

  <div v-if="history.length === 0" class="card empty">
    No switch history yet
  </div>

  <div v-else class="card" style="padding: 0; overflow-x: auto;">
    <table class="history-table">
      <thead>
        <tr>
          <th>Time</th>
          <th>From</th>
          <th>To</th>
          <th>Status</th>
          <th>Duration</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="(h, i) in history" :key="i">
          <td>{{ fmtTime(h.at) }}</td>
          <td>{{ h.from_profile || '—' }}</td>
          <td>{{ h.to_profile }}</td>
          <td :class="h.status">{{ h.status }}</td>
          <td>{{ h.elapsed_seconds }}s</td>
        </tr>
      </tbody>
    </table>
  </div>
</template>

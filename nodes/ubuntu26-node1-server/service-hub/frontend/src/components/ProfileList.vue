<script setup lang="ts">
import { ref, onMounted, computed } from 'vue'
import { api, type ProfileInfo, type ProfileDetail } from '../api'

const props = defineProps<{
  currentProfile: string | null
  switching: boolean
}>()

const emit = defineEmits<{
  switch: [name: string]
}>()

const profiles = ref<ProfileInfo[]>([])
const confirmName = ref<string | null>(null)
const expandedName = ref<string | null>(null)
const expandedDetail = ref<ProfileDetail | null>(null)

async function refresh() {
  try {
    const res = await api.getProfiles()
    profiles.value = res.profiles
  } catch {}
}

onMounted(refresh)

async function toggleExpand(name: string) {
  if (expandedName.value === name) {
    expandedName.value = null
    expandedDetail.value = null
    return
  }
  expandedName.value = name
  try {
    expandedDetail.value = await api.getProfile(name)
  } catch {
    expandedDetail.value = null
  }
}

function category(name: string) {
  if (name.startsWith('game-')) return 'Game Studio'
  if (name.startsWith('web-')) return 'Web Studio'
  if (name.startsWith('dsv4-')) return 'DeepSeek-V4'
  if (name === 'unsloth') return 'Training'
  return 'Other'
}

const grouped = computed(() => {
  const map = new Map<string, ProfileInfo[]>()
  for (const p of profiles.value) {
    const cat = category(p.name)
    if (!map.has(cat)) map.set(cat, [])
    map.get(cat)!.push(p)
  }
  return map
})

function doSwitch(name: string) {
  confirmName.value = null
  emit('switch', name)
}
</script>

<template>
  <div class="section-title">Service Profiles</div>

  <div v-for="[cat, items] in grouped" :key="cat" style="margin-bottom: 24px;">
    <h3 style="font-size: 14px; color: var(--text2); margin-bottom: 8px;">{{ cat }}</h3>
    <div class="profile-list">
      <div
        v-for="p in items"
        :key="p.name"
        class="profile-item"
        :class="{ current: p.name === currentProfile }"
      >
        <div class="info">
          <h3>
            {{ p.name }}
            <span v-if="p.name === currentProfile" style="color: var(--green); font-size: 12px;">● active</span>
          </h3>
          <p>{{ p.description }}</p>
        </div>
        <div class="meta">
          <button class="btn btn-ghost btn-sm" @click="toggleExpand(p.name)">
            {{ expandedName === p.name ? 'Less' : 'Details' }}
          </button>
          <span class="tag gpu">{{ p.gpu_count }} GPUs</span>
          <span v-for="r in p.roles" :key="r" class="tag">{{ r }}</span>
          <button
            class="btn btn-primary"
            :disabled="switching || p.name === currentProfile"
            @click="confirmName = p.name"
          >
            {{ p.name === currentProfile ? 'Active' : 'Switch' }}
          </button>
        </div>

        <!-- Expanded detail -->
        <div v-if="expandedName === p.name && expandedDetail" class="profile-detail">
          <div v-for="(alloc, i) in expandedDetail.gpu_allocation" :key="i" class="alloc-row">
            <div class="alloc-header">
              <span class="tag gpu" v-if="alloc.gpu && alloc.gpu.length">GPU {{ alloc.gpu.join(', ') }}</span>
              <span class="tag" v-if="alloc.role">{{ alloc.role }}</span>
              <span class="alloc-model">{{ alloc.model_short || alloc.model }}</span>
              <span v-if="alloc.port" class="alloc-port">:{{ alloc.port }}</span>
              <span v-if="alloc.container_name" class="alloc-container">{{ alloc.container_name }}</span>
            </div>
            <div v-if="alloc.serve && alloc.serve.args && alloc.serve.args.length" class="alloc-args">
              <span class="args-label">serve.args:</span>
              <code>{{ alloc.serve.args.join(' ') }}</code>
            </div>
            <div v-if="alloc.serve && alloc.serve.script" class="alloc-args">
              <span class="args-label">script:</span>
              <code>{{ alloc.serve.script }}</code>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>

  <!-- Confirm modal -->
  <div v-if="confirmName" class="modal-overlay" @click.self="confirmName = null">
    <div class="modal">
      <h2>Switch Profile</h2>
      <p>
        Switch to <strong>{{ confirmName }}</strong>?
        <br>This will stop all running containers and start the new profile.
      </p>
      <div class="actions">
        <button class="btn btn-ghost" @click="confirmName = null">Cancel</button>
        <button class="btn btn-primary" :disabled="switching" @click="doSwitch(confirmName!)">
          <span v-if="switching" class="spinner"></span>
          {{ switching ? 'Switching...' : 'Confirm' }}
        </button>
      </div>
    </div>
  </div>
</template>

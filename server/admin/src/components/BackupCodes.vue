<script setup lang="ts">
import { computed } from 'vue'
import AppIcon from './AppIcon.vue'
import CopyButton from './CopyButton.vue'
import { backupCodesFile } from '../twofactor'

const props = defineProps<{ codes: string[] }>()

const text = computed(() => props.codes.join('\n'))

function download(): void {
  const blob = new Blob([backupCodesFile(props.codes, window.location.host)], { type: 'text/plain' })
  const url = URL.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = url
  link.download = 'simpastil-admin-backup-codes.txt'
  document.body.appendChild(link)
  link.click()
  link.remove()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}
</script>

<template>
  <div class="backup-codes">
    <ul class="backup-code-grid" aria-label="Backup codes">
      <li v-for="code in codes" :key="code"><code>{{ code }}</code></li>
    </ul>
    <div class="backup-code-actions">
      <CopyButton class="btn-secondary btn-sm" :value="text" label="Copy all" />
      <button class="btn-secondary btn-sm" type="button" @click="download">
        <AppIcon name="download" :size="16" />Download .txt
      </button>
    </div>
  </div>
</template>

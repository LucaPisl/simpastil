<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { initial, relativeDay } from '../dashboard'
import { loadPerson, morphName, personById, type Person } from '../people'
import AppIcon from './AppIcon.vue'

const props = defineProps<{ id: string; tab: 'keys' | 'devices' }>()

const person = ref<Person | undefined>(personById(props.id))
const tabs = [
  { value: 'keys', label: 'Keys', icon: 'key' },
  { value: 'devices', label: 'Devices', icon: 'device' },
] as const
const active = computed(() => tabs.findIndex((t) => t.value === props.tab))
// A long address wraps at its @ rather than mid-word on a phone.
const local = computed(() => person.value?.email.split('@')[0] ?? '')
const domain = computed(() => {
  const email = person.value?.email ?? ''
  const at = email.indexOf('@')
  return at < 0 ? '' : email.slice(at)
})

onMounted(async () => {
  if (person.value) return
  try {
    person.value = await loadPerson(props.id)
  } catch {
    /* the header keeps its placeholder; the page shows its own error */
  }
})
</script>

<template>
  <div class="person-header">
    <RouterLink class="back-link" to="/users"><AppIcon name="back" :size="18" />People</RouterLink>
    <div class="person-plate">
      <span
        class="avatar person-avatar"
        aria-hidden="true"
        :style="{ viewTransitionName: morphName('avatar', id) }"
      >{{ person ? initial(person.email) : '' }}</span>
      <div class="person-words">
        <h1 class="person-name" :style="{ viewTransitionName: morphName('name', id) }">
          <template v-if="person">{{ local }}<wbr />{{ domain }}</template>
          <template v-else>This person</template>
        </h1>
        <p v-if="person" class="person-meta">Joined {{ relativeDay(person.createdAt) }}</p>
      </div>
    </div>
    <nav class="person-tabs" aria-label="This person" :style="{ '--active': active }">
      <span class="person-tab-capsule" aria-hidden="true"></span>
      <RouterLink
        v-for="t in tabs"
        :key="t.value"
        class="person-tab"
        :class="{ 'is-active': t.value === tab }"
        :to="`/users/${id}/${t.value}`"
        :aria-current="t.value === tab ? 'page' : undefined"
        :style="{ viewTransitionName: 'person-tab-' + t.value }"
        replace
      >
        <AppIcon :name="t.icon" :size="17" />
        <span>{{ t.label }}</span>
      </RouterLink>
    </nav>
  </div>
</template>

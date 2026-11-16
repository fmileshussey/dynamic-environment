// Turns http://dev-env.localhost/open?slot=<slot>[&all=1] into a tab group titled after the
// slot, holding a tab per app in the slot's list (written by ./env.sh hosts). Running it again
// reuses the group and only opens apps that don't have a tab in it yet.

const DEV_ENV = 'http://dev-env.localhost'
const OPEN_URL = `${DEV_ENV}/open`

// Servers and libraries have no page worth opening unless asked for with &all=1
const SKIPPED_CATEGORIES = ['servers', 'libraries']

const GROUP_COLORS = ['blue', 'green', 'purple', 'cyan', 'orange', 'pink', 'yellow', 'red']

/** The same slot always gets the same colour. */
function colorFor(slot) {
  let hash = 0
  for (const char of slot) {
    hash = (hash * 31 + char.charCodeAt(0)) >>> 0
  }
  return GROUP_COLORS[hash % GROUP_COLORS.length]
}

// onUpdated fires several times per navigation; handle each trigger tab once
const handling = new Set()

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  const url = changeInfo.url ?? tab.url
  if (!url?.startsWith(OPEN_URL) || handling.has(tabId)) {
    return
  }
  handling.add(tabId)
  openSlot(tab, new URL(url))
    .catch((error) => console.error('dev-env: could not open slot', error))
    .finally(() => handling.delete(tabId))
})

async function openSlot(trigger, url) {
  const slot = url.searchParams.get('slot')
  if (!slot) {
    return
  }
  const response = await fetch(`${DEV_ENV}/slots/${encodeURIComponent(slot)}.json`, {
    cache: 'no-store',
  })
  if (!response.ok) {
    // Leave the trigger page up: it explains how to give the slot hostnames
    return
  }
  const { apps } = await response.json()
  const includeAll = url.searchParams.has('all')
  const wanted = apps.filter((app) => includeAll || !SKIPPED_CATEGORIES.includes(app.category))
  if (wanted.length === 0) {
    return
  }

  const windowId = trigger.windowId
  const [group] = await chrome.tabGroups.query({ windowId, title: slot })
  const groupTabs = group ? await chrome.tabs.query({ groupId: group.id }) : []
  const tabIds = groupTabs.map((tab) => tab.id)

  let firstNew
  for (const app of wanted) {
    const origin = new URL(app.url).origin
    if (groupTabs.some((tab) => (tab.url ?? tab.pendingUrl ?? '').startsWith(origin))) {
      continue
    }
    const tab = await chrome.tabs.create({ windowId, url: app.url, active: false })
    tabIds.push(tab.id)
    firstNew ??= tab.id
  }

  const groupId = await chrome.tabs.group(
    group ? { tabIds, groupId: group.id } : { tabIds, createProperties: { windowId } },
  )
  await chrome.tabGroups.update(groupId, { title: slot, color: colorFor(slot), collapsed: false })
  await chrome.tabs.update(firstNew ?? tabIds[0], { active: true })
  await chrome.tabs.remove(trigger.id)
}

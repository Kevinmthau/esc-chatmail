import { getRouteApi, useNavigate } from '@tanstack/react-router'
import { isDemoMode } from '@/app/boot'
import { GlassBar } from '@/components/ui/GlassBar'
import { IconButton } from '@/components/ui/IconButton'
import { requestSync } from '@/data/actions'
import { Spinner } from '@/features/auth/Spinner'
import { useSyncStatus } from '@/live/hooks'
import { ConversationList } from './ConversationList'
import { FilterMenu } from './FilterMenu'
import { ComposeIcon, RefreshIcon } from './icons'
import { SearchField } from './SearchField'
import { SettingsMenu } from './SettingsMenu'
import { syncProgressDetail } from './syncState'

const chatsRoute = getRouteApi('/chats')

/**
 * The full left pane (iOS ConversationListView): header with title/status/
 * controls, virtualized list, and — on mobile — the bottom glass bar with the
 * filter menu, the search capsule, and compose. Desktop keeps the same capsule
 * under the header, where the bar does not exist.
 */
export function ConversationListPane() {
  const { filter, q } = chatsRoute.useSearch()
  const navigate = useNavigate()
  const demo = isDemoMode()

  const openCompose = () => {
    void navigate({
      to: '.',
      search: (prev) => ({ ...prev, compose: true }),
    })
  }

  return (
    <div className="flex h-full min-h-0 flex-1 flex-col">
      <header className="flex h-14 shrink-0 items-center gap-2 px-4">
        <h1 className="text-xl font-bold">Chats</h1>
        {demo && (
          <span className="bg-bg-elev text-fg-muted rounded-chip px-2 py-0.5 text-xs font-medium">
            Demo data
          </span>
        )}
        <div className="ml-auto flex items-center gap-1">
          <span className="hidden md:inline-flex">
            <FilterMenu filter={filter} />
          </span>
          <IconButton aria-label="Refresh" className="size-9" onClick={() => void requestSync()}>
            <RefreshIcon className="size-5" />
          </IconButton>
          <span className="hidden md:inline-flex">
            <IconButton aria-label="New message" className="size-9" onClick={openCompose}>
              <ComposeIcon className="size-5" />
            </IconButton>
          </span>
          <SettingsMenu />
        </div>
      </header>
      <div className="hidden shrink-0 px-4 pb-2 md:block">
        <SearchField />
      </div>
      <SyncStatusLine />

      <div className="min-h-0 flex-1">
        <ConversationList filter={filter} query={q} demo={demo} />
      </div>

      <GlassBar className="shrink-0 md:hidden">
        <div className="flex items-center gap-2 px-3 py-2">
          <FilterMenu filter={filter} />
          <SearchField className="min-w-0 flex-1" />
          <IconButton aria-label="New message" onClick={openCompose}>
            <ComposeIcon className="size-5" />
          </IconButton>
        </div>
      </GlassBar>
    </div>
  )
}

/** One-line sync status under the header: spinner while syncing, last error. */
function SyncStatusLine() {
  const status = useSyncStatus()
  if (status === undefined) return null
  if (status.phase !== 'idle') {
    const detail = syncProgressDetail(status)
    return (
      <div className="text-fg-muted flex items-center gap-1.5 px-4 pb-1 text-xs">
        <Spinner className="size-3" />
        <span>{detail !== undefined ? `Syncing… ${detail}` : 'Syncing…'}</span>
      </div>
    )
  }
  if (status.lastError !== undefined) {
    return (
      <div className="text-danger px-4 pb-1 text-xs" title={status.lastError}>
        Sync failed — will retry
      </div>
    )
  }
  return null
}

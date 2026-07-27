import { getRouteApi, useNavigate } from '@tanstack/react-router'
import { useEffect, useState } from 'react'
import { isDemoMode } from '@/app/boot'
import { GlassBar } from '@/components/ui/GlassBar'
import { IconButton } from '@/components/ui/IconButton'
import { archiveConversation, reportSpam, requestSync } from '@/data/actions'
import { Spinner } from '@/features/auth/Spinner'
import { useSyncStatus } from '@/live/hooks'
import { conversationCountLabel, runBatchAction } from './batchActions'
import { ConversationList } from './ConversationList'
import { FilterMenu } from './FilterMenu'
import { ArchiveIcon, ComposeIcon, RefreshIcon, SpamIcon } from './icons'
import {
  ConversationSelectionContext,
  useConversationSelection,
  useConversationSelectionState,
} from './selection'
import { SettingsMenu } from './SettingsMenu'
import { syncProgressDetail } from './syncState'

const chatsRoute = getRouteApi('/chats')

const TEXT_BUTTON =
  'text-accent focus-visible:outline-accent rounded-chip px-2 py-1 text-sm font-medium ' +
  'active:opacity-70 disabled:opacity-40 focus-visible:outline-2'

const CAPSULE_BUTTON =
  'border-border bg-bg-elev focus-visible:outline-accent flex items-center gap-2 rounded-chip ' +
  'border px-6 py-3 text-sm font-medium shadow-sm active:opacity-70 disabled:opacity-40 ' +
  'focus-visible:outline-2'

/** Which batch action is in flight (both capsules disable while one runs). */
type BatchKind = 'archive' | 'spam'

/**
 * The full left pane (iOS ConversationListView): header with title/status/
 * controls, virtualized list, and the bottom glass bar — the filter menu, the
 * (coming-soon) search capsule and compose on mobile, or the batch action bar
 * while the list is in multi-select mode.
 */
export function ConversationListPane() {
  const selection = useConversationSelectionState()
  return (
    <ConversationSelectionContext.Provider value={selection}>
      <ConversationListPaneContent />
    </ConversationSelectionContext.Provider>
  )
}

function ConversationListPaneContent() {
  const { filter } = chatsRoute.useSearch()
  const navigate = useNavigate()
  const demo = isDemoMode()
  const {
    selecting,
    selectedIds,
    selectedCount,
    selectableCount,
    allSelected,
    enterSelectMode,
    exitSelectMode,
    toggleSelectAll,
    setSelection,
  } = useConversationSelection()

  const [runningBatch, setRunningBatch] = useState<BatchKind | null>(null)
  const [batchError, setBatchError] = useState<string | null>(null)

  // Leaving select mode by any route (Cancel, Escape, a completed action)
  // clears a stale failure notice.
  useEffect(() => {
    if (!selecting) setBatchError(null)
  }, [selecting])

  const openCompose = () => {
    void navigate({
      to: '.',
      search: (prev) => ({ ...prev, compose: true }),
    })
  }

  const runSelectionAction = async (
    kind: BatchKind,
    apply: (conversationId: string) => Promise<void>,
    describeFailure: (count: number) => string,
  ): Promise<void> => {
    const ids = [...selectedIds]
    if (ids.length === 0 || runningBatch !== null) return
    setRunningBatch(kind)
    setBatchError(null)

    const { failed } = await runBatchAction(ids, apply)

    setRunningBatch(null)
    if (failed.length === 0) {
      exitSelectMode()
      return
    }
    // Partial failure: stay in select mode with exactly what did NOT land still
    // selected, so retrying cannot silently skip a conversation and the UI never
    // claims a success it did not get.
    setSelection(failed)
    setBatchError(describeFailure(failed.length))
  }

  const archiveSelected = () => {
    void runSelectionAction(
      'archive',
      archiveConversation,
      (count) => `Could not archive ${conversationCountLabel(count)}. Try again.`,
    )
  }

  const reportSpamSelected = () => {
    void runSelectionAction(
      'spam',
      reportSpam,
      (count) => `Could not report ${conversationCountLabel(count)} as spam. Try again.`,
    )
  }

  return (
    <div className="flex h-full min-h-0 flex-1 flex-col">
      <header className="flex h-14 shrink-0 items-center gap-2 px-4">
        {selecting ? (
          <>
            <button
              type="button"
              className={TEXT_BUTTON}
              disabled={selectableCount === 0}
              onClick={toggleSelectAll}
            >
              {allSelected ? 'Deselect All' : 'Select All'}
            </button>
            <h1 aria-live="polite" className="min-w-0 flex-1 truncate text-center font-semibold">
              {selectedCount} Selected
            </h1>
            <button type="button" className={TEXT_BUTTON} onClick={exitSelectMode}>
              Cancel
            </button>
          </>
        ) : (
          <>
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
              <button type="button" className={TEXT_BUTTON} onClick={enterSelectMode}>
                Select
              </button>
              <IconButton
                aria-label="Refresh"
                className="size-9"
                onClick={() => void requestSync()}
              >
                <RefreshIcon className="size-5" />
              </IconButton>
              <span className="hidden md:inline-flex">
                <IconButton aria-label="New message" className="size-9" onClick={openCompose}>
                  <ComposeIcon className="size-5" />
                </IconButton>
              </span>
              <SettingsMenu />
            </div>
          </>
        )}
      </header>
      <SyncStatusLine />

      <div className="min-h-0 flex-1">
        <ConversationList filter={filter} demo={demo} />
      </div>

      {selecting ? (
        // Unlike the normal bar this one shows at every breakpoint: on desktop
        // it is the only place the batch actions live.
        <SelectionActionBar
          count={selectedCount}
          busy={runningBatch !== null}
          error={batchError}
          onArchive={archiveSelected}
          onReportSpam={reportSpamSelected}
        />
      ) : (
        <GlassBar className="shrink-0 md:hidden">
          <div className="flex items-center gap-2 px-3 py-2">
            <FilterMenu filter={filter} />
            <button
              type="button"
              disabled
              title="Coming soon"
              className="bg-bg-elev text-fg-muted flex-1 rounded-chip px-4 py-2 text-left text-sm"
            >
              Search
            </button>
            <IconButton aria-label="New message" onClick={openCompose}>
              <ComposeIcon className="size-5" />
            </IconButton>
          </div>
        </GlassBar>
      )}
    </div>
  )
}

interface SelectionActionBarProps {
  count: number
  busy: boolean
  error: string | null
  onArchive: () => void
  onReportSpam: () => void
}

/** Batch action bar shown in select mode (iOS selectionActionBar). */
function SelectionActionBar({
  count,
  busy,
  error,
  onArchive,
  onReportSpam,
}: SelectionActionBarProps) {
  const disabled = count === 0 || busy
  return (
    <GlassBar className="shrink-0">
      {error !== null && (
        <p role="alert" className="text-danger px-4 pt-2 text-center text-xs">
          {error}
        </p>
      )}
      <div className="flex items-center justify-center gap-3 px-3 py-3">
        <button
          type="button"
          className={CAPSULE_BUTTON}
          disabled={disabled}
          aria-label={count === 0 ? 'Archive' : `Archive ${conversationCountLabel(count)}`}
          onClick={onArchive}
        >
          <ArchiveIcon className="size-5" />
          Archive
        </button>
        <button
          type="button"
          className={CAPSULE_BUTTON}
          disabled={disabled}
          aria-label={
            count === 0 ? 'Report spam' : `Report ${conversationCountLabel(count)} as spam`
          }
          onClick={onReportSpam}
        >
          <SpamIcon className="size-5" />
          Report Spam
        </button>
      </div>
    </GlassBar>
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

import { useLiveQuery } from 'dexie-react-hooks'
import { useId } from 'react'
import { getDB } from '@/db/schema'
import type { AccountRow } from '@/db/types'
import { defaultAlias, isAcceptedForSending } from '@/sync/aliases'

/**
 * "From:" alias select. Rendered only when the account has more than one
 * sendable alias (sendable rule = sync/aliases.isAcceptedForSending, the same
 * gate the reply-from resolver uses). `value === null` shows the default alias.
 */
export function AliasPicker({
  value,
  onChange,
}: {
  value: string | null
  onChange: (email: string) => void
}) {
  const selectId = useId()
  const account = useLiveQuery<AccountRow | null, null>(
    async () => {
      try {
        return (await getDB().accounts.toCollection().first()) ?? null
      } catch {
        return null // No account DB open yet.
      }
    },
    [],
    null,
  )

  const sendable = (account?.sendAsAliases ?? []).filter(isAcceptedForSending)
  if (sendable.length <= 1) return null

  const selected = value ?? defaultAlias(sendable)?.email ?? sendable[0]?.email ?? ''

  return (
    <div className="flex items-center gap-2 border-b border-border px-4 py-2">
      <label htmlFor={selectId} className="text-sm text-fg-muted">
        From:
      </label>
      <select
        id={selectId}
        value={selected}
        onChange={(event) => onChange(event.target.value)}
        className="min-w-0 flex-1 appearance-none bg-transparent py-1 text-sm text-fg outline-none"
      >
        {sendable.map((alias) => (
          <option key={alias.email} value={alias.email}>
            {alias.displayName !== '' ? `${alias.displayName} <${alias.email}>` : alias.email}
          </option>
        ))}
      </select>
    </div>
  )
}

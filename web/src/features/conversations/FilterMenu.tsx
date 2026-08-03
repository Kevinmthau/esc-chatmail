import { useNavigate } from '@tanstack/react-router'
import { Menu, MenuItem } from '@/components/ui/Menu'
import { ChevronDownIcon } from './icons'

interface FilterMenuProps {
  filter?: 'unread'
}

/** All / Unread list filter (iOS bottom-bar filter menu, MVP subset). */
export function FilterMenu({ filter }: FilterMenuProps) {
  const navigate = useNavigate()
  const setFilter = (next?: 'unread') => {
    void navigate({
      to: '.',
      search: (prev) => ({ ...prev, filter: next }),
    })
  }

  return (
    <Menu
      trigger={
        <button
          type="button"
          className="bg-bg-elev flex items-center gap-1 rounded-chip px-3 py-1.5 text-sm font-medium active:opacity-70"
        >
          {filter === 'unread' ? 'Unread' : 'All'}
          <ChevronDownIcon className="text-fg-muted size-3.5" />
        </button>
      }
    >
      <MenuItem onSelect={() => setFilter(undefined)}>All</MenuItem>
      <MenuItem onSelect={() => setFilter('unread')}>Unread</MenuItem>
    </Menu>
  )
}

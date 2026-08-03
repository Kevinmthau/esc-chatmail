import { useNavigate } from '@tanstack/react-router'
import { getAccountEmail, isDemoMode, signOut } from '@/app/boot'
import { IconButton } from '@/components/ui/IconButton'
import { Menu, MenuItem } from '@/components/ui/Menu'
import { GearIcon } from './icons'

/** Account menu: signed-in address + sign out (with confirm). */
export function SettingsMenu() {
  const navigate = useNavigate()
  const demo = isDemoMode()
  const label = demo ? 'Demo' : (getAccountEmail() ?? 'Signed in')

  const onSignOut = () => {
    const ok = window.confirm('Sign out? Mail data stored on this device will be deleted.')
    if (!ok) return
    void signOut().then(() => navigate({ to: '/signin' }))
  }

  return (
    <Menu
      trigger={
        <IconButton aria-label="Settings">
          <GearIcon className="size-5" />
        </IconButton>
      }
    >
      <div className="text-fg-muted max-w-60 truncate px-3 py-2 text-sm">{label}</div>
      {!demo && (
        <MenuItem destructive onSelect={onSignOut}>
          Sign out
        </MenuItem>
      )}
    </Menu>
  )
}

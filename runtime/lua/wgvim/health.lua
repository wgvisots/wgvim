-- wgvim: ":checkhealth wgvim" reports the sandbox (|wgvim-sandbox|).

local M = {}

-- Whether a file can be created in `dir`: tried for real, because access() does not see Landlock.
-- Created exclusively (O_EXCL), so that an existing file or symlink of that name in a shared
-- directory is never opened, let alone truncated.
local function can_create(dir)
  local probe = ('%s/.wgvim-health-%d-%08x'):format(
    dir,
    vim.uv.os_getpid(),
    math.random(0, 0x7fffffff)
  )
  local fd = vim.uv.fs_open(probe, 'wx', 384) -- O_WRONLY|O_CREAT|O_EXCL, mode 0600
  if not fd then
    return false
  end
  vim.uv.fs_close(fd)
  vim.uv.fs_unlink(probe)
  return true
end

--- Warns about directories in options that wgvim writes to which the sandbox does not allow.
local function check_option_dirs(health)
  local opts = {
    { 'undodir', vim.o.undofile, 'undo files (E828)' },
    { 'directory', vim.o.swapfile, 'swap files' },
    { 'backupdir', vim.o.backup or vim.o.writebackup, 'backup files' },
  }
  for _, o in ipairs(opts) do
    local name, used, what = o[1], o[2], o[3]
    if used then
      -- The first usable entry is used. "." (the file's directory) is left to the file rules.
      for entry in vim.gsplit(vim.o[name], ',', { plain = true }) do
        local dir = vim.fn.fnamemodify(vim.fn.expand((entry:gsub('//+$', ''))), ':p'):gsub('/$', '')
        if entry == '.' or entry:match('^%./') then
          break
        elseif vim.fn.isdirectory(dir) == 1 then
          if can_create(dir) then
            health.ok(("'%s' is writable: %s"):format(name, dir))
          else
            health.warn(
              ("'%s' is outside the sandbox, %s cannot be written: %s"):format(name, what, dir),
              {
                ("Remove the '%s' setting from your config: the default (%s) is in the sandbox"):format(
                  name,
                  vim.api.nvim_get_option_info2(name, {}).default
                ),
              }
            )
          end
          break
        end
      end
    end
  end
end

function M.check()
  local health = vim.health
  local i = vim.api.nvim__sandbox_info()

  health.start('Sandbox (:help wgvim-sandbox)')
  if i.status == 'active' then
    health.ok(('Active (Landlock ABI %d, %d rules)'):format(i.abi, #i.rules))
  elseif i.status == 'off' then
    health.warn(
      'Off: ' .. i.reason,
      { 'Start wgvim without "--sandbox off" or $WGVIM_SANDBOX=off' }
    )
    return
  else
    health.warn(('Not active (%s): %s'):format(i.status, i.reason), {
      'Landlock needs Linux 5.13 or later (RHEL 9.6 or later)',
      'Use "--sandbox require" to refuse to start without it',
    })
    return
  end

  if i.network then
    health.ok('TCP connections and listening are blocked')
  else
    health.info(
      ('TCP is not blocked by the sandbox: this kernel has Landlock ABI %d (needs 4)'):format(i.abi)
    )
  end
  if i.seccomp then
    health.ok(
      'System call filter: only Unix sockets, no connect() to existing sockets'
        .. (i.connect and ' (except wgvim\'s own, for :restart)' or '')
        .. ', no System V IPC, no io_uring'
    )
  else
    health.warn('No system call filter (only built for x86-64 and AArch64)', {
      'UDP and other protocols, connecting to existing Unix sockets (D-Bus, ssh-agent) '
        .. 'and System V IPC are not blocked',
    })
  end
  if i.clipboard ~= '' then
    health.ok('Clipboard helper: ' .. i.clipboard .. ' (runs outside the sandbox, copy/paste only)')
  elseif i.seccomp and not i.connect then
    health.info('No clipboard helper: copying uses OSC 52 when available (see :help wgvim-sandbox)')
  end
  if i.scoped then
    health.ok('Signals and abstract Unix sockets outside the sandbox are blocked')
  else
    health.info(
      ('Processes outside the sandbox can be signalled: Landlock ABI %d (needs 6)'):format(i.abi)
    )
  end
  for _, note in ipairs(i.notes) do
    health.warn(note)
  end
  check_option_dirs(health)

  local names = {
    ro = 'read-only',
    rx = 'read and execute',
    rw = 'read-write',
    rwx = 'read-write and execute',
    dev = 'device',
  }
  health.start('Sandbox rules')
  for _, r in ipairs(i.rules) do
    local line = ('%-24s %s'):format(names[r.access] or r.access, r.path)
    if r.ok then
      health.info(line)
    else
      health.warn(line .. ': ' .. r.error)
    end
  end
end

return M

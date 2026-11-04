-- wgvim: ":checkhealth wgvim" reports the sandbox (|wgvim-sandbox|).

local M = {}

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

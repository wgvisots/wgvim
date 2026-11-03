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
  if i.scoped then
    health.ok('Abstract Unix sockets outside the sandbox are blocked')
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

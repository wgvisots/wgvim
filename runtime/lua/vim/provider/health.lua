local health = vim.health
local iswin = vim.fn.has('win32') == 1

local M = {}

---@param cmd string[]
---@return boolean
---@return string
local function cmd_ok(cmd)
  local result = vim.system(cmd, { text = true }):wait()
  return result.code == 0, assert(result.stdout)
end

---@param cmd string[]
local function cli_version(cmd)
  local ok, out = cmd_ok(cmd)
  return ok, vim.version.parse(out, { strict = false })
end

-- Attempts to construct a shell command from an args list.
-- Only for display, to help users debug a failed command.
--- @param cmd string|string[]
local function shellify(cmd)
  if type(cmd) ~= 'table' then
    return cmd
  end
  local escaped = {} --- @type string[]
  for i, v in ipairs(cmd) do
    escaped[i] = v:match('[^A-Za-z_/.-]') and vim.fn.shellescape(v) or v
  end
  return table.concat(escaped, ' ')
end

-- Handler for s:system() function.
--- @param self {output: string, stderr: string, add_stderr_to_output: boolean}
--- @param data string[]
--- @param event 'stdout'|'stderr'
local function system_handler(self, _, data, event)
  if event == 'stderr' then
    if self.add_stderr_to_output then
      self.output = self.output .. table.concat(data, '\n')
    else
      self.stderr = self.stderr .. table.concat(data, '\n')
    end
  elseif event == 'stdout' then
    self.output = self.output .. table.concat(data, '\n')
  end
end

--- @param cmd string|string[] List of command arguments to execute
--- @param args? table Optional arguments:
---                   - stdin (string): Data to write to the job's stdin
---                   - stderr (boolean): Append stderr to stdout
---                   - ignore_error (boolean): If true, ignore error output
---                   - timeout (number): Number of seconds to wait before timing out (default 30)
local function system(cmd, args)
  args = args or {}
  local stdin = args.stdin or ''
  local stderr = args.stderr or false
  local ignore_error = args.ignore_error or false

  local shell_error_code = 0
  local opts = {
    add_stderr_to_output = stderr,
    output = '',
    stderr = '',
    on_exit = function(_, data)
      shell_error_code = data
    end,
  }
  opts.on_stdout = function(...)
    system_handler(opts, ...)
  end
  opts.on_stderr = opts.on_stdout
  local jobid = vim.fn.jobstart(cmd, opts)

  if jobid < 1 then
    local message =
      string.format('Command error (job=%d): %s (in %s)', jobid, shellify(cmd), vim.uv.cwd())
    error(message)
    return opts.output, 1
  end

  if stdin:find('^%s$') then
    vim.fn.chansend(jobid, stdin)
  end

  local res = vim.fn.jobwait({ jobid }, math.floor(vim.nonnil(args.timeout, 30) * 1000))
  if res[1] == -1 then
    vim.fn.jobstop(jobid)
    error('Command timed out: ' .. shellify(cmd))
  elseif shell_error_code ~= 0 and not ignore_error then
    local emsg = string.format(
      'Command error (job=%d, exit code %d): %s (in %s)',
      jobid,
      shell_error_code,
      shellify(cmd),
      vim.uv.cwd()
    )
    if opts.output:find('%S') then
      emsg = string.format('%s\noutput: %s', emsg, opts.output)
    end
    if opts.stderr:find('%S') then
      emsg = string.format('%s\nstderr: %s', emsg, opts.stderr)
    end
    error(emsg)
  end

  return vim.trim(opts.output), shell_error_code
end

---@param provider string
local function provider_disabled(provider)
  local loaded_var = 'loaded_' .. provider .. '_provider'
  local v = vim.g[loaded_var]
  if v == 0 then
    health.info('Disabled (' .. loaded_var .. '=' .. v .. ').')
    return true
  end
  return false
end

--- Checks the hygiene of a `g:loaded_xx_provider` variable.
--- @param var string
local function check_loaded_var(var)
  if vim.g[var] == 1 then
    health.error(('`g:%s=1` may have been set by mistake.'):format(var), {
      ('Remove `vim.g.%s=1` from your config.'):format(var),
      'To disable the provider, set this to 0, not 1.',
      'If you want to enable the provider but skip automatic detection, set the respective `g:…_host_prog` var. See :help provider',
    })
  end
end

local function clipboard()
  health.start('Clipboard (optional)')

  check_loaded_var('loaded_clipboard_provider')

  if
    os.getenv('TMUX')
    and vim.fn.executable('tmux') == 1
    and vim.fn.executable('pbpaste') == 1
    and not cmd_ok({ 'pbpaste' })
  then
    local _, tmux_version = cli_version({ 'tmux', '-V' })
    local advice = {
      'Install tmux 2.6+.  https://superuser.com/q/231130',
      'or use tmux with reattach-to-user-namespace.  https://superuser.com/a/413233',
    }
    health.error('pbcopy does not work with tmux version: ' .. tostring(tmux_version), advice)
  end

  local clipboard_tool = vim.fn['provider#clipboard#Executable']() ---@type string
  if vim.g.clipboard ~= nil and clipboard_tool == '' then
    local error_message = vim.fn['provider#clipboard#Error']() ---@type string
    health.error(
      error_message,
      "Use the example in :help g:clipboard as a template, or don't set g:clipboard at all."
    )
  elseif clipboard_tool:find('^%s*$') then
    health.warn(
      'No clipboard tool found. Clipboard registers (`"+` and `"*`) will not work.',
      ':help clipboard'
    )
  else
    health.ok('Clipboard tool found: ' .. clipboard_tool)
  end
end

-- wgvim: the Node.js, Perl, Python 3 and Ruby providers (and remote plugins) are removed; they
-- started external interpreters that load code from outside the editor. See SECURITY-AUDIT.md.

function M.check()
  clipboard()
end

return M

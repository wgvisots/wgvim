-- wgvim: the Landlock sandbox (|wgvim-sandbox|).
--
-- Each test starts a separate wgvim (not the RPC test instance, which runs with the sandbox
-- off), in a temporary "project" directory with a fake $HOME, and checks what it can reach.

local t = require('test.testutil')
local n = require('test.functional.testnvim')()

local describe, it, before_each, after_each = t.describe, t.it, t.before_each, t.after_each
local eq, matches, neq = t.eq, t.matches, t.neq

local root, home, proj, outside

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  t.write_file(path, text)
end

--- Runs wgvim headless on `script` (Lua, in a file in the working directory) and returns its
--- stdout, stderr and exit code. `opts.args` go before the script; `opts.clean = false` loads
--- the user config as a normal startup does.
local function run(script, opts)
  opts = opts or {}
  local cwd = opts.cwd or proj
  write(cwd .. '/_test.lua', script)
  local cmd = { n.nvim_prog }
  if not opts.tui then
    cmd[#cmd + 1] = '--headless'
  end
  if opts.clean ~= false then
    cmd[#cmd + 1] = '--clean'
  end
  vim.list_extend(cmd, opts.args or {})
  if t.paths.is_gcov then
    -- Coverage builds write .gcda files into build/src when the process exits.
    vim.list_extend(cmd, { '--sandbox-allow', t.paths.test_build_dir .. '/src' })
  end
  vim.list_extend(cmd, { '-c', 'luafile _test.lua' })
  if opts.then_script then
    -- A separate command: e.g. clipboard updates are batched until a command finishes.
    write(cwd .. '/_test2.lua', opts.then_script)
    vim.list_extend(cmd, { '-c', 'luafile _test2.lua' })
  end
  vim.list_extend(cmd, { '-c', 'qa!' })
  if opts.tui then
    -- The terminal UI, in a pseudo-terminal: a TUI process that starts the editor process.
    local quoted = vim.tbl_map(vim.fn.shellescape, cmd)
    cmd = { 'script', '-qec', table.concat(quoted, ' '), '/dev/null' }
  end
  local job = vim.system(cmd, {
    cwd = cwd,
    -- Kept open for script(1): some versions stop the session when their input ends.
    stdin = opts.tui or nil,
    env = {
      WGVIM_SANDBOX = opts.sandbox or 'on',
      HOME = home,
      XDG_CONFIG_HOME = home .. '/.config',
      XDG_DATA_HOME = home .. '/.local/share',
      XDG_STATE_HOME = home .. '/.local/state',
      XDG_CACHE_HOME = home .. '/.cache',
      TMPDIR = root .. '/tmp',
      VIMRUNTIME = t.paths.test_source_path .. '/runtime',
      PATH = opts.path_prefix and (opts.path_prefix .. ':' .. os.getenv('PATH')) or nil,
      WAYLAND_DISPLAY = opts.wayland,
      SSH_TTY = opts.ssh_tty,
      TERM = opts.tui and 'xterm' or nil,
      SHELL = opts.tui and '/bin/sh' or nil, -- script(1) runs the command with $SHELL
    },
    text = true,
  })
  local r = job:wait(60000)
  return r.stdout, r.stderr, r.code
end

local function info()
  local out = run([[io.stdout:write(vim.json.encode(vim.api.nvim__sandbox_info()))]])
  return vim.json.decode(out)
end

describe('sandbox', function()
  before_each(function()
    root = vim.fs.normalize(vim.fn.fnamemodify(t.tmpname(false), ':p'))
    home = root .. '/home'
    proj = root .. '/proj'
    outside = root .. '/outside'
    write(home .. '/.ssh/id_ed25519', 'secret key\n')
    write(home .. '/notes.txt', 'notes\n')
    write(proj .. '/a.txt', 'inside\n')
    write(outside .. '/named.txt', 'named\n')
    write(outside .. '/other.txt', 'other\n')
    vim.fn.mkdir(root .. '/tmp', 'p')
  end)

  after_each(function()
    vim.fn.delete(root, 'rf')
  end)

  local function skip_unless_active()
    local i = info()
    t.skip(i.status ~= 'active', 'sandbox not available here: ' .. (i.reason or ''))
    return i
  end

  it('is active by default and reports its rules', function()
    local i = skip_unless_active()
    eq('active', i.status)
    neq(0, i.abi)
    local paths = {}
    for _, r in ipairs(i.rules) do
      paths[r.path] = r.access
    end
    eq('rwx', paths[proj])
    eq('rx', paths['/usr'])
  end)

  it('blocks reads outside the allowed paths, before the user config runs', function()
    skip_unless_active()
    write(
      home .. '/.config/wgvim/init.lua',
      [[_G.init_read = pcall(vim.fn.readfile, vim.env.HOME .. '/.ssh/id_ed25519')]]
    )
    local out = run(
      [[
      io.stdout:write(vim.json.encode({
        init_read = _G.init_read,
        ssh = (pcall(vim.fn.readfile, vim.env.HOME .. '/.ssh/id_ed25519')),
        other = (pcall(vim.fn.readfile, ']] .. outside .. [[/other.txt')),
        inside = vim.fn.readfile('a.txt')[1],
      }))
    ]],
      { clean = false }
    )
    eq({ init_read = false, ssh = false, other = false, inside = 'inside' }, vim.json.decode(out))
  end)

  it('blocks writes outside the current directory, with a clear error', function()
    skip_unless_active()
    local out = run([[
      vim.fn.writefile({ 'new' }, 'sub/new.txt', 'p')
      local ok, err = pcall(vim.fn.writefile, { 'x' }, ']] .. outside .. [[/new.txt')
      io.stdout:write(vim.json.encode({ ok = ok, err = err, new = vim.fn.readfile('sub/new.txt') }))
    ]])
    local r = vim.json.decode(out)
    eq(false, r.ok)
    matches('outside the wgvim sandbox', r.err)
    eq({ 'new' }, r.new)
    eq(nil, vim.uv.fs_stat(outside .. '/new.txt'))
  end)

  it("an 'undodir' outside the sandbox: E828 says so, and :checkhealth warns", function()
    skip_unless_active()
    vim.fn.mkdir(home .. '/.vim/undodir', 'p')
    local out = run([[
      vim.o.undofile = true
      vim.o.undodir = vim.env.HOME .. '/.vim/undodir'
      vim.cmd.edit('a.txt')
      vim.cmd('normal! ix')
      local ok, err = pcall(vim.cmd.write)
      local report = {}
      for _, k in ipairs({ 'start', 'ok', 'info', 'warn', 'error' }) do
        vim.health[k] = function(msg)
          report[#report + 1] = k .. ': ' .. msg
        end
      end
      require('wgvim.health').check()
      io.stdout:write(vim.json.encode({ ok = ok, err = err, health = table.concat(report, '\n') }))
    ]])
    local r = vim.json.decode(out)
    eq(false, r.ok)
    matches("E828: .*outside the wgvim sandbox: leave 'undodir' at its default", r.err)
    matches("'undodir' is outside the sandbox", r.health)
    matches("'directory' is writable", r.health) -- the default, in stdpath('state')
  end)

  it('allows files named on the command line, and only those', function()
    skip_unless_active()
    run(
      [[
      local named = vim.fn.argv(0)
      local lines = vim.fn.readfile(named)
      vim.fn.writefile({ lines[1] .. ' and edited' }, named)
      local ok = pcall(vim.fn.readfile, ']] .. outside .. [[/other.txt')
      vim.fn.writefile({ tostring(ok) }, 'result.txt')
    ]],
      { args = { outside .. '/named.txt' } }
    )
    eq('named and edited\n', t.read_file(outside .. '/named.txt'))
    eq('false\n', t.read_file(proj .. '/result.txt'))
  end)

  it('confines programs started by wgvim', function()
    skip_unless_active()
    local out = run([[
      local r1 = vim.system({ 'cat', vim.env.HOME .. '/.ssh/id_ed25519' }):wait()
      local r2 = vim.system({ 'sh', '-c', 'echo x > ]] .. outside .. [[/child.txt' }):wait()
      local r3 = vim.system({ 'sh', '-c', 'echo ok > child.txt && cat child.txt' }):wait()
      io.stdout:write(vim.json.encode({ r1.code, r2.code, r3.stdout }))
    ]])
    local r = vim.json.decode(out)
    neq(0, r[1])
    neq(0, r[2])
    eq('ok\n', r[3])
    eq(nil, vim.uv.fs_stat(outside .. '/child.txt'))
  end)

  it('gives programs a writable $TMPDIR', function()
    skip_unless_active()
    local out = run([[
      local sh = 'f="$TMPDIR/child-tmp" && echo ok > "$f" && cat "$f"'
      local r = vim.system({ 'sh', '-c', sh }):wait()
      io.stdout:write(r.stdout)
    ]])
    eq('ok\n', out)
  end)

  it('blocks TCP connections', function()
    local i = skip_unless_active()
    t.skip(not i.network and not i.seccomp, 'neither Landlock ABI 4 nor a system call filter')
    t.skip(vim.fn.executable('bash') == 0, 'needs bash')
    -- No server listens on port 9: without the sandbox this is "Connection refused". The system
    -- call filter refuses the socket itself; Landlock (ABI 4+) would refuse the connect().
    local out = run([[
      local r = vim.system({ 'bash', '-c', 'echo > /dev/tcp/127.0.0.1/9' }):wait()
      io.stdout:write(r.stderr)
    ]])
    eq(nil, out:find('Connection refused', 1, true))
    matches('Address family not supported', out)
  end)

  it('allows only Unix sockets: no UDP or other protocols', function()
    local i = skip_unless_active()
    t.skip(not i.seccomp, 'no system call filter on this platform')
    t.skip(vim.fn.executable('bash') == 0, 'needs bash')
    local out = run([[
      local r = vim.system({ 'bash', '-c', 'echo x > /dev/udp/127.0.0.1/9' }):wait()
      io.stdout:write(r.stderr)
    ]])
    matches('Address family not supported', out)
  end)

  it('refuses to connect to Unix sockets (D-Bus, ssh-agent, ...)', function()
    local i = skip_unless_active()
    t.skip(not i.seccomp, 'no system call filter on this platform')
    -- A listening socket outside the sandbox, like ~/.ssh/agent or /run/user/<uid>/bus.
    local sock = root .. '/agent.sock'
    local server = assert(vim.uv.new_pipe(false))
    assert(server:bind(sock))
    server:listen(1, function() end)
    local out = run([[
      local p = assert(vim.uv.new_pipe(false))
      local result
      p:connect(']] .. sock .. [[', function(err) result = err or 'connected' end)
      vim.wait(5000, function() return result ~= nil end)
      local ok, err = pcall(vim.fn.sockconnect, 'pipe', ']] .. sock .. [[')
      io.stdout:write(vim.json.encode({ result, err }))
    ]])
    server:close()
    local r = vim.json.decode(out)
    eq('EACCES', r[1])
    matches('E5435: sockconnect%(%) is not available', r[2])
  end)

  it('refuses System V IPC and io_uring', function()
    local i = skip_unless_active()
    t.skip(not i.seccomp, 'no system call filter on this platform')
    t.skip(vim.fn.executable('ipcmk') == 0, 'needs ipcmk')
    local out = run([[
      local r = vim.system({ 'ipcmk', '-M', '4096' }):wait()
      local rings = 0
      for _, fd in ipairs(vim.fn.readdir('/proc/self/fd')) do
        local target = vim.uv.fs_readlink('/proc/self/fd/' .. fd) or ''
        rings = rings + (target:find('io_uring', 1, true) and 1 or 0)
      end
      io.stdout:write(vim.json.encode({ r.code, rings }))
    ]])
    local r = vim.json.decode(out)
    neq(0, r[1])
    eq(0, r[2]) -- libuv uses epoll: no io_uring ring was opened before the filter
  end)

  it('cannot signal processes outside the sandbox', function()
    local i = skip_unless_active()
    t.skip(not i.scoped, 'Landlock ABI ' .. i.abi .. ' has no signal scoping (needs 6)')
    local outside_pid = vim.uv.os_getpid() -- the test runner, outside the sandbox
    local out = run([[
      local ok_out, err_out = vim.uv.kill(]] .. outside_pid .. [[, 0)
      local child = vim.system({ 'sleep', '30' })
      local ok_in = vim.uv.kill(child.pid, 'sigterm')
      child:wait()
      io.stdout:write(vim.json.encode({ ok_out or err_out, ok_in }))
    ]])
    local r = vim.json.decode(out)
    matches('EPERM', r[1])
    eq(0, r[2]) -- its own children can still be signalled
  end)

  it('--remote and --server are not available', function()
    local _, err, code = run('', { args = { '--remote', 'x' } })
    neq(0, code)
    matches('Not available in wgvim', err)
  end)

  it('clipboard: uses the helper for wl-copy/wl-paste on a local desktop', function()
    local i = skip_unless_active()
    t.skip(not i.seccomp, 'no system call filter on this platform')
    -- Stand-ins for wl-copy and wl-paste that keep the clipboard in a file outside the sandbox:
    -- only the helper, which runs outside, can reach it.
    local store = root .. '/clipboard'
    write(root .. '/bin/wl-copy', '#!/bin/sh\ncat > ' .. store .. '\n')
    write(root .. '/bin/wl-paste', '#!/bin/sh\ncat ' .. store .. '\n')
    vim.uv.fs_chmod(root .. '/bin/wl-copy', 493)
    vim.uv.fs_chmod(root .. '/bin/wl-paste', 493)
    write(store, 'from the desktop')
    local out = run(
      [[
      vim.o.clipboard = 'unnamedplus'
      _G.before = vim.fn.getreg('+', 1, true)
      vim.fn.setline(1, { 'yanked', 'in wgvim' })
      vim.cmd('normal! yj')
    ]],
      {
        path_prefix = root .. '/bin',
        wayland = 'wayland-test',
        then_script = [[
          io.stdout:write(vim.json.encode({
            vim.api.nvim__sandbox_info().clipboard,
            vim.fn['provider#clipboard#Executable'](),
            _G.before,
            vim.fn.getreg('+', 1, true),
          }))
        ]],
      }
    )
    local r = vim.json.decode(out)
    eq('wl-clipboard', r[1])
    eq('wl-clipboard (sandbox helper)', r[2])
    eq({ 'from the desktop' }, r[3])
    eq({ 'yanked', 'in wgvim', '' }, r[4])
    matches('^yanked\nin wgvim', t.read_file(store))
  end)

  it('clipboard: never runs a clipboard program from a directory the sandbox can write to', function()
    local i = skip_unless_active()
    t.skip(not i.seccomp, 'no system call filter on this platform')
    -- The helper runs outside the sandbox: a wl-copy in the project (here in $PATH) could have
    -- been planted by a sandboxed program, and must not be the one it runs.
    local marker = root .. '/ran-outside'
    for _, tool in ipairs({ 'wl-copy', 'wl-paste' }) do
      write(proj .. '/bin/' .. tool, '#!/bin/sh\ntouch ' .. marker .. '\n')
      vim.uv.fs_chmod(proj .. '/bin/' .. tool, 493)
    end
    local out = run(
      [[
      pcall(vim.fn.setreg, '+', 'x')
      io.stdout:write(vim.json.encode({ vim.api.nvim__sandbox_info().clipboard }))
    ]],
      { path_prefix = proj .. '/bin', wayland = 'wayland-test' }
    )
    eq({ '' }, vim.json.decode(out)) -- no helper: the only wl-copy is in the project
    eq(nil, vim.uv.fs_stat(marker))
  end)

  it('clipboard: the helper works with the terminal UI too', function()
    local i = skip_unless_active()
    t.skip(not i.seccomp, 'no system call filter on this platform')
    t.skip(vim.fn.executable('script') == 0, 'needs script(1)')
    -- The TUI process is confined before it starts the editor process, so a helper forked by
    -- the editor process would be confined too, and could not reach the store.
    local store = root .. '/clipboard'
    write(root .. '/bin/wl-copy', '#!/bin/sh\ncat > ' .. store .. '\n')
    write(root .. '/bin/wl-paste', '#!/bin/sh\ncat ' .. store .. '\n')
    vim.uv.fs_chmod(root .. '/bin/wl-copy', 493)
    vim.uv.fs_chmod(root .. '/bin/wl-paste', 493)
    write(store, 'from the desktop')
    local out, err, code = run(
      [[
      local before = vim.fn.getreg('+')
      local ok, err = pcall(vim.fn.setreg, '+', 'yanked in wgvim')
      local child = vim.fn.system({ 'sh', '-c', 'echo "[$WGVIM_CLIPBOARD_FD]"' })
      vim.fn.writefile({ vim.json.encode({ before, ok, tostring(err), child }) }, 'result.json')
    ]],
      { path_prefix = root .. '/bin', wayland = 'wayland-test', tui = true }
    )
    local result = t.read_file(proj .. '/result.json')
    if result == nil then
      error(('no result; exit %s, stderr: %s, stdout: %s'):format(code, err, out:sub(-2000)))
    end
    local r = vim.json.decode(result)
    eq('from the desktop', r[1])
    eq(true, r[2], r[3])
    eq('[]\n', r[4]) -- not passed on to the editor's own children
    eq('yanked in wgvim', t.read_file(store))
  end)

  it('refuses keyrings, new namespaces and TIOCSTI, but not processes, threads or ioctls', function()
    local i = skip_unless_active()
    t.skip(not i.seccomp, 'no system call filter on this platform')
    t.skip(vim.fn.executable('python3') == 0, 'needs python3')
    write(proj .. '/probe.py', table.concat({
      'import ctypes, errno, os, threading, subprocess, json, fcntl, termios',
      'libc = ctypes.CDLL(None, use_errno=True)',
      'def call(fn, *a):',
      '    ctypes.set_errno(0); r = fn(*a)',
      '    return "ok" if r >= 0 else errno.errorcode.get(ctypes.get_errno(), "?")',
      'nr = {"x86_64": 250, "aarch64": 219}[os.uname().machine]  # keyctl',
      'r = {"keyctl": call(libc.syscall, nr, 0, ctypes.c_long(-3), 0)}',
      'r["unshare_user"] = call(libc.unshare, 0x10000000)',
      'r["unshare_pid"] = call(libc.unshare, 0x20000000)',
      'r["unshare_files"] = call(libc.unshare, 0x400)',
      'r["setns"] = call(libc.setns, 0, 0)',
      'th = threading.Thread(target=lambda: None); th.start(); th.join(); r["thread"] = "ok"',
      'r["subprocess"] = subprocess.run(["true"]).returncode',
      'fd = os.open("/dev/tty", os.O_RDWR)',
      'try: fcntl.ioctl(fd, termios.TIOCSTI, b" "); r["tiocsti"] = "ok"',
      'except OSError as e: r["tiocsti"] = errno.errorcode[e.errno]',
      'fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\\0" * 8); r["winsz"] = "ok"',
      'open("probe.json", "w").write(json.dumps(r))',
    }, '\n'))
    -- In :terminal, so that it has a controlling terminal for the ioctls.
    run([[
      vim.fn.jobstart({ 'python3', 'probe.py' }, { term = true })
      vim.wait(10000, function() return vim.uv.fs_stat('probe.json') ~= nil end)
      vim.wait(100)
    ]])
    local r = vim.json.decode(t.read_file(proj .. '/probe.json'))
    eq({
      keyctl = 'EPERM',
      unshare_user = 'EPERM',
      unshare_pid = 'EPERM',
      unshare_files = 'ok', -- unshare() without namespace flags still works
      setns = 'EPERM',
      thread = 'ok', -- clone3() gives ENOSYS: the C library falls back to clone()
      subprocess = 0,
      tiocsti = 'EPERM',
      winsz = 'ok', -- other terminal ioctls still work
    }, r)
  end)

  describe('Harper', function()
    local vsix = t.paths.test_source_path .. '/deps/harper-linux-x64-3.1.0.vsix'
    local script = t.paths.test_source_path .. '/scripts/install-harper.sh'

    local function install(file)
      return vim
        .system({ script, file }, { env = { PREFIX = home .. '/.local' }, text = true })
        :wait(60000)
    end

    it('installs only the pinned release', function()
      write(root .. '/fake.vsix', 'not the pinned file')
      local r = install(root .. '/fake.vsix')
      eq(1, r.code)
      matches('is not the pinned release', r.stderr)
      eq(nil, vim.uv.fs_stat(home .. '/.local/bin/harper-ls'))
    end)

    it('runs harper-ls in the sandbox from the shipped config', function()
      local i = skip_unless_active()
      t.skip(not vim.uv.fs_stat(vsix), 'no ' .. vsix .. ' (it is pushed to deps/ separately)')
      local r = install(vsix)
      eq(0, r.code, r.stderr)
      if vim.fn.executable('python3') == 1 then
        local c = vim.system({ 'python3', '-I', t.paths.test_source_path .. '/scripts/check-harper.py',
          home .. '/.local/bin/harper-ls' }, { text = true }):wait(60000)
        eq(0, c.code, c.stdout)
      end
      write(proj .. '/notes.md', '# Notes\n\nI recieve alot of mail.\n')
      local out = run([[
        vim.lsp.enable('harper_ls')
        vim.cmd.edit('notes.md')
        local b = vim.api.nvim_get_current_buf()
        vim.wait(20000, function() return #vim.diagnostic.get(b) > 0 end, 50)
        local msgs = {}
        for _, d in ipairs(vim.diagnostic.get(b)) do msgs[#msgs + 1] = d.message end
        -- "Add to the user dictionary", as the code action does.
        local client = vim.lsp.get_clients({ bufnr = b })[1]
        local added
        for _, d in ipairs(vim.diagnostic.get(b)) do
          if d.message:find('recieve', 1, true) then
            local res = client:request_sync('textDocument/codeAction', {
              textDocument = { uri = vim.uri_from_bufnr(b) },
              range = { start = { line = d.lnum, character = d.col },
                        ['end'] = { line = d.end_lnum, character = d.end_col } },
              context = { diagnostics = { d.user_data.lsp } },
            }, 10000, b)
            for _, a in ipairs(res and res.result or {}) do
              if a.title:find('user dictionary', 1, true) then
                local cmd = type(a.command) == 'table' and a.command
                  or { command = a.command, arguments = a.arguments }
                added = client:request_sync('workspace/executeCommand', cmd, 10000, b)
              end
            end
          end
        end
        vim.wait(1000)
        local dict = vim.fn.stdpath('state') .. '/harper/dictionary.txt'
        local report = {}
        for _, k in ipairs({ 'start', 'ok', 'info', 'warn', 'error' }) do
          vim.health[k] = function(m) report[#report + 1] = k .. ': ' .. m end
        end
        require('wgvim.health').check_harper(vim.health)
        io.stdout:write(vim.json.encode({
          msgs = msgs,
          added = added ~= nil and added.err == nil,
          dict = vim.fn.filereadable(dict) == 1 and vim.fn.readfile(dict) or {},
          health = table.concat(report, '\n'),
        }))
      ]], { path_prefix = home .. '/.local/bin' })
      local res = vim.json.decode(out)
      local all = table.concat(res.msgs, '\n')
      matches('recieve', all)
      matches('a lot', all)
      eq(true, res.added)
      eq({ 'recieve' }, res.dict)
      matches('ok: harper%-ls 3%.1%.0, the pinned build', res.health)
      matches('ok: Enabled, memory limited to 1024 MB', res.health)
      eq(true, i.status == 'active')
    end)
  end)

  describe('.git watch', function()
    before_each(function()
      vim.fn.mkdir(proj .. '/.git/hooks', 'p')
      write(proj .. '/.git/config', '[core]\n\tbare = false\n')
      write(proj .. '/.git/hooks/pre-commit.sample', '#!/bin/sh\n')
    end)

    it('reports what changed in .git/config and the hooks during the session', function()
      skip_unless_active()
      local _, err = run([[
        vim.fn.writefile({ '[core]', '\tbare = false', '\tfsmonitor = something' }, '.git/config')
        vim.fn.writefile({ '#!/bin/sh' }, '.git/hooks/post-checkout')
        os.remove('.git/hooks/pre-commit.sample')
      ]])
      matches('these files changed that git takes commands from', err)
      matches('changed +%.git/config\n +%+ \tfsmonitor = something\n', err)
      matches('added +%.git/hooks/post%-checkout\n', err)
      matches('removed +%.git/hooks/pre%-commit%.sample\n', err)
      eq(nil, err:find('bare = false', 1, true)) -- only the added lines are shown
    end)

    it('says nothing when they did not change, and :checkhealth shows the watch', function()
      skip_unless_active()
      local out, err = run([[
        vim.fn.writefile({ 'x' }, 'file.txt')
        local i = vim.api.nvim__sandbox_info()
        io.stdout:write(vim.json.encode({ i.git_watch, i.git_watch_files }))
      ]])
      eq(nil, err:find('git takes commands from', 1, true))
      local r = vim.json.decode(out)
      eq(vim.uv.fs_realpath(proj), r[1])
      eq(2, r[2]) -- .git/config and the one hook
    end)

    it('watches a core.hooksPath directory in the project', function()
      skip_unless_active()
      write(proj .. '/.git/config', '[core]\n\thooksPath = .githooks\n')
      vim.fn.mkdir(proj .. '/.githooks', 'p')
      write(proj .. '/.githooks/pre-commit', '#!/bin/sh\nexit 0\n')
      local _, err = run([[
        vim.fn.writefile({ '#!/bin/sh', 'something else' }, '.githooks/pre-commit')
      ]])
      matches('changed +%.githooks/pre%-commit\n', err)
    end)

    it('does not pass escape sequences from file names to the terminal', function()
      skip_unless_active()
      local _, err = run([[
        vim.fn.writefile({ '#!/bin/sh' }, '.git/hooks/x\27]0;title\7y')
      ]])
      matches('added +%.git/hooks/x%?%]0;title%?y\n', err)
      eq(nil, err:find('\27', 1, true))
    end)

    it('reports once with the terminal UI', function()
      local i = skip_unless_active()
      t.skip(not i.seccomp, 'no system call filter on this platform')
      t.skip(vim.fn.executable('script') == 0, 'needs script(1)')
      local out = run([[
        vim.fn.writefile({ '#!/bin/sh' }, '.git/hooks/post-checkout')
      ]], { tui = true })
      local _, count = out:gsub('git takes commands from', '')
      eq(1, count)
      matches('added +%.git/hooks/post%-checkout', out)
    end)
  end)

  it('clipboard: over SSH, copies with OSC 52 and pastes what was copied', function()
    skip_unless_active()
    local out = run(
      [[
      vim.o.clipboard = 'unnamedplus'
      vim.fn.setline(1, { 'over ssh' })
      vim.cmd('normal! yy')
    ]],
      {
        ssh_tty = '/dev/pts/99',
        wayland = 'wayland-test',
        then_script = [[
          io.stdout:write(vim.json.encode({
            vim.api.nvim__sandbox_info().clipboard,
            vim.fn['provider#clipboard#Executable'](),
            vim.fn.getreg('+', 1, true),
          }))
        ]],
      }
    )
    eq({ '', 'OSC 52 (copy only)', { 'over ssh' } }, vim.json.decode(out))
  end)

  it('in the home directory, allows only its non-hidden entries', function()
    skip_unless_active()
    local out = run(
      [[
      vim.fn.writefile({ 'more notes' }, 'notes.txt')
      local i = vim.api.nvim__sandbox_info()
      io.stdout:write(vim.json.encode({
        ssh = (pcall(vim.fn.readfile, '.ssh/id_ed25519')),
        dot = (pcall(vim.fn.writefile, { 'x' }, '.newdotfile')),
        notes = i.notes,
      }))
    ]],
      { cwd = home }
    )
    local r = vim.json.decode(out)
    eq(false, r.ssh)
    eq(false, r.dot)
    matches('home directory', r.notes[1])
    eq('more notes\n', t.read_file(home .. '/notes.txt'))
  end)

  it('--sandbox-allow and --sandbox-allow-ro add paths', function()
    skip_unless_active()
    local out = run(
      [[
      local other = vim.fn.readfile(']] .. outside .. [[/other.txt')[1]
      local ok = pcall(vim.fn.writefile, { 'x' }, ']] .. outside .. [[/other.txt')
      io.stdout:write(vim.json.encode({ other, ok }))
    ]],
      { args = { '--sandbox-allow-ro', outside } }
    )
    eq({ 'other', false }, vim.json.decode(out))
    run(
      [[vim.fn.writefile({ 'rw' }, ']] .. outside .. [[/other.txt')]],
      { args = { '--sandbox-allow', outside } }
    )
    eq('rw\n', t.read_file(outside .. '/other.txt'))
  end)

  it('can be turned off', function()
    local out = run(
      [[io.stdout:write(vim.api.nvim__sandbox_info().status .. ' '
        .. vim.fn.readfile(vim.env.HOME .. '/.ssh/id_ed25519')[1])]],
      { args = { '--sandbox', 'off' } }
    )
    eq('off secret key', out)
  end)

  it('rejects an unknown mode', function()
    local _, err, code = run('', { args = { '--sandbox', 'maybe' } })
    eq(2, code)
    matches('must be on, off or require', err)
  end)

  it('works with clangd', function()
    skip_unless_active()
    t.skip(vim.fn.executable('clangd') == 0, 'needs clangd')
    write(
      proj .. '/main.c',
      '#include <stdio.h>\nint main(void) { printf("x"); return undefined_name; }\n'
    )
    write(
      proj .. '/compile_commands.json',
      vim.json.encode({ { directory = proj, file = proj .. '/main.c', command = 'cc -c main.c' } })
    )
    local out = run([[
      vim.cmd.edit('main.c')
      vim.lsp.start({
        name = 'clangd',
        cmd = { 'clangd', '--background-index' },
        root_dir = vim.fn.getcwd(),
      })
      vim.wait(30000, function() return #vim.diagnostic.get(0) > 0 end, 100)
      local msgs = {}
      for _, d in ipairs(vim.diagnostic.get(0)) do msgs[#msgs + 1] = d.message end
      io.stdout:write(vim.json.encode(msgs))
    ]])
    local msgs = table.concat(vim.json.decode(out), '\n')
    matches('undefined_name', msgs)
    eq(nil, msgs:find('stdio.h', 1, true))  -- system headers are readable
  end)
end)

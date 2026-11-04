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
  local cmd = { n.nvim_prog, '--headless' }
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
  local r = vim
    .system(cmd, {
      cwd = cwd,
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
      },
      text = true,
    })
    :wait(60000)
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

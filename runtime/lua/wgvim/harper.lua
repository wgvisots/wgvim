-- wgvim: the pinned Harper release (|wgvim-harper|), for :checkhealth and scripts.
-- The same hashes are in cmake.deps/deps.txt (HARPER_VSIX_SHA256, HARPER_LS_SHA256), which
-- scripts/install-harper.sh reads; a test checks that the two agree.
local M = {}

--- Pinned releases: the VS Code extension package Harper publishes (.vsix, a zip file) and the
--- harper-ls executable inside it (extension/bin/harper-ls).
M.pins = {
  {
    version = '3.1.0',
    platform = 'linux-x64',
    vsix = 'harper-linux-x64-3.1.0.vsix',
    vsix_sha256 = 'bbaffeb39dacf398a6b09c4d30c576dae28dcfdfe10c033ff5399ff054260e6b',
    bin_sha256 = '4a3a19bd3e538d16a5fd3f17af18d077856e7f200ebe2dfb881ec4c92226afc6',
  },
}

--- The SHA-256 of file `path`, or nil.
--- @param path string
--- @return string?
function M.file_sha256(path)
  local f = io.open(path, 'rb')
  if not f then
    return nil
  end
  local data = f:read('*a')
  f:close()
  return vim.fn.sha256(data)
end

--- The pin that harper-ls at `path` matches, or nil.
--- @param path string
--- @return table?
function M.pin_of(path)
  local h = M.file_sha256(path)
  for _, p in ipairs(M.pins) do
    if p.bin_sha256 == h then
      return p
    end
  end
  return nil
end

return M

# TODO: provenance of the cpp and matlab queries

`cpp/` and `matlab/` were added by the wgvim maintainers and their origin was not
recorded at the time. Before this tree is distributed, find and record in `NOTICE`:

- the upstream repository and the exact commit or tag the files came from
  (believed to be nvim-treesitter; unconfirmed),
- the licence that applies to them,
- any edits made locally.

`matlab/` has no parser vendored yet, so it is inactive until one is added.
The other directories here (c, diff, lua, markdown, ...) ship with Neovim and are
covered by LICENSE.txt.

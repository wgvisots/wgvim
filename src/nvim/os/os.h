#pragma once

#include <stddef.h>
#include <stdint.h>
#include <uv.h>

#include "nvim/cmdexpand_defs.h"
#include "nvim/garray_defs.h"
#include "nvim/os/os_defs.h"
#include "nvim/os/stdpaths_defs.h"
#include "nvim/types_defs.h"

// True if when running in a test environment ($WGVIM_TEST).
// TODO(justinmk): Can we use v:testing instead?
EXTERN bool nvim_testing INIT( = false);
extern char *default_vim_dir;
extern char *default_vimruntime_dir;
extern char *default_lib_dir;
extern char *build_tree_exe;
extern char *build_tree_runtime;

// IWYU pragma: begin_exports
#include "os/env.h.generated.h"
#include "os/mem.h.generated.h"
#include "os/stdpaths.h.generated.h"
#include "os/users.h.generated.h"
// IWYU pragma: end_exports

#define ENV_LOGFILE "WGVIM_LOG_FILE"
#define ENV_LOGFILE_WANT "__WGVIM_LOG_FILE_WANT"
#define ENV_NVIM "WGVIM"
#define ENV_STARTREASON "__WGVIM_STARTREASON"
#define ENV_TEST_LOG "__WGVIM_TEST_LOG"

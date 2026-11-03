#pragma once

#include <stdbool.h>

#include "nvim/api/private/defs.h"  // IWYU pragma: keep
#include "nvim/memory_defs.h"  // IWYU pragma: keep

typedef enum {
  kLandlockOff = 0,      ///< turned off by the user
  kLandlockActive,       ///< applied
  kLandlockUnavailable,  ///< the kernel has no Landlock
  kLandlockFailed,       ///< a Landlock system call failed
} LandlockStatus;

#include "os/landlock.h.generated.h"

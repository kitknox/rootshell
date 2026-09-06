//
//  rootshell-Bridging-Header.h
//  rootshell
//
//  Bridging header for Ghostty C API
//

#ifndef rootshell_Bridging_Header_h
#define rootshell_Bridging_Header_h

// Import the Ghostty C API
#import "ghostty.h"

// Import ios_system for local shell support (iOS/visionOS only, not Catalyst).
// The umbrella pulls in ios_async.h / ios_pid_allocator.h, so importing those
// directly would ask for submodules the module map doesn't declare.
#if !TARGET_OS_MACCATALYST
#import <ios_system/ios_system.h>
#endif

// Import Helix editor FFI (iOS/visionOS only, not Catalyst)
#if !TARGET_OS_MACCATALYST
#import <HelixKit/helix_ios.h>
#import "Features/Croc/Util/CrocXXHash.h"
#endif

// Import libgit2 for native git command support (iOS/visionOS only, not Catalyst)
#if !TARGET_OS_MACCATALYST
#include <libgit2/git2.h>
#include <libgit2/git2/sys/errors.h>
#include "Features/Git/GitSSHTransportBridge.h"
#endif

// CoreWLAN plugin protocol for Mac Catalyst WiFi info
#import "Core/Networking/CoreWLANPluginProtocol.h"

// DNS resolver for AS number lookups.
// res_query is a macro in resolv.h and doesn't bridge to Swift properly,
// so we declare res_9_query directly. Available on all Apple platforms via libresolv.
int res_9_query(const char *, int, int, unsigned char *, int);

// Accessor for ios_system's thread-local FILE* streams.
// Swift cannot access C __thread variables directly, so we provide inline wrappers.
#if !TARGET_OS_MACCATALYST
static inline FILE* ios_get_thread_stdin(void) { return thread_stdin; }
static inline FILE* ios_get_thread_stdout(void) { return thread_stdout; }
static inline FILE* ios_get_thread_stderr(void) { return thread_stderr; }
static inline void ios_set_thread_stdout(FILE* f) { thread_stdout = f; }
static inline void ios_set_thread_stderr(FILE* f) { thread_stderr = f; }
#endif

// bat_ios and ripgrep_ios C FFI entry points (linked from xcframeworks)
#if !TARGET_OS_MACCATALYST
int bat_main(int argc, const char* const* argv);
int bat_main_cancellable(int argc, const char* const* argv, const volatile unsigned char* cancel_flag);
void bat_set_terminal_palette(unsigned int fg, unsigned int bg, const unsigned int* palette);
void bat_clear_terminal_palette(void);
int rg_main(int argc, const char* const* argv);
int jq_main(int argc, char* argv[]);
#endif

// Import FD receiver for Catalyst helper integration
#import "Core/Helper/FDReceiver.h"

// Import ObjC exception catcher for AVFoundation NSException handling
#import "Features/AIAgent/Voice/Audio/AVExceptionCatcher.h"

// Additional iOS-specific functions
#ifdef __cplusplus
extern "C" {
#endif

/// Get the PTY master file descriptor for iOS external backend.
/// Returns -1 if not using iOS external backend or if FD is unavailable.
int ghostty_surface_pty_master_fd(void* surface);

/// Get the response pipe read FD for iOS external backend.
/// Swift should read from this FD to get terminal responses (e.g., cursor position).
/// Returns -1 if not using iOS external backend or if FD is unavailable.
int ghostty_surface_response_read_fd(void* surface);

/// Returns whether cursor key application mode (DECCKM) is active.
/// When true, arrow keys should send SS3 sequences (\x1bOA, etc.)
/// When false, arrow keys should send CSI sequences (\x1b[A, etc.)
bool ghostty_surface_cursor_key_mode(void* surface);

/// Returns whether focus event reporting (DEC mode 1004) is active.
bool ghostty_surface_focus_event_mode(void* surface);

/// Returns the total number of rows in the primary screen (including scrollback).
uintptr_t ghostty_surface_total_rows(void* surface);

/// Returns the displayed terminal's primary-screen scrollbar state.
bool ghostty_surface_display_scrollbar(void* surface, ghostty_action_scrollbar_s* out);

/// Dump the entire primary screen as ANSI-styled text. Returns NULL if empty.
/// Caller must free with ghostty_surface_free_dump.
const char* ghostty_surface_dump_primary_screen(void* surface, uintptr_t* out_len);

/// Dump the alternate screen viewport as ANSI-styled text. Returns NULL if
/// the alternate screen is not initialized or empty.
/// Caller must free with ghostty_surface_free_dump.
const char* ghostty_surface_dump_alternate_screen(void* surface, uintptr_t* out_len);

/// Returns whether the alternate screen is currently active (e.g., vim, htop).
bool ghostty_surface_is_alternate_active(void* surface);

/// Free text returned by ghostty_surface_dump_primary_screen or
/// ghostty_surface_dump_alternate_screen.
void ghostty_surface_free_dump(const char* ptr, uintptr_t len);

/// Set a render-only vertical scroll offset in pixels for smooth scrollback.
void ghostty_surface_set_smooth_scroll_offset(ghostty_surface_t surface, double y_px);

/// Scroll to an absolute row and apply a render-only smooth scroll offset.
void ghostty_surface_scroll_to_row_smooth(ghostty_surface_t surface, uintptr_t row, double y_px);

/// Reserve a bottom inset in framebuffer pixels (e.g. the iOS home-indicator
/// safe-area strip). The grid and prompt stay put; the reserved strip renders
/// blank at rest and is filled by smooth-scroll overscan rows when the viewport
/// is scrolled off the bottom. Pass 0 to clear.
void ghostty_surface_set_bottom_inset(ghostty_surface_t surface, double px);

/// Begin a touch selection-handle drag anchored at the fixed (opposite)
/// endpoint of the current selection. Returns false if there is no selection.
bool ghostty_surface_selection_handle_drag_begin(ghostty_surface_t surface, bool dragging_start);

/// Report whether each endpoint of the current selection is within the viewport.
/// Lets the touch UI show only the visible endpoint's handle for a selection
/// that spans more than one screen. Returns false if there is no selection.
bool ghostty_surface_selection_viewport_visibility(ghostty_surface_t surface, bool* start_visible, bool* end_visible);

#ifdef __cplusplus
}
#endif

#endif /* rootshell_Bridging_Header_h */

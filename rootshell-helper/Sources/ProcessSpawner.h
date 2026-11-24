//
//  ProcessSpawner.h
//  rootshell-helper
//
//  Process spawning with PTY and login shell support.
//  Based on ghostty/src/Command.zig and ghostty/src/termio/Exec.zig
//

#import <Foundation/Foundation.h>
#import "PTYManagerImpl.h"

NS_ASSUME_NONNULL_BEGIN

/// Configuration for spawning a shell process
@interface ShellSpawnConfig : NSObject

/// Window size for the PTY
@property (nonatomic, assign) PTYSize size;

/// Working directory (nil = use user's home directory)
@property (nonatomic, copy, nullable) NSString *workingDirectory;

/// Shell to launch (nil = use user's default shell from passwd)
@property (nonatomic, copy, nullable) NSString *shell;

/// Custom command to run (nil = launch login shell)
@property (nonatomic, copy, nullable) NSArray<NSString *> *command;

/// Verified recovery command, executed once before the configured login shell.
@property (nonatomic, copy, nullable) NSString *recoveryCommand;

/// Environment variables to set
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *environment;

/// Whether to inject shell integration scripts
@property (nonatomic, assign) BOOL enableShellIntegration;

/// Path to shell integration resources
@property (nonatomic, copy, nullable) NSString *shellIntegrationPath;

/// Start in HOME when workingDirectory cannot be opened; otherwise the child exits.
@property (nonatomic, assign) BOOL fallbackToHomeDirectory;

@end

/// Result of spawning a shell process
@interface ShellSpawnResult : NSObject

/// Process ID of the spawned shell
@property (nonatomic, readonly) pid_t pid;

/// PTY pair (caller takes ownership)
@property (nonatomic, readonly, strong) PTYPair *pty;

/// The shell started in HOME because the requested directory could not be opened.
@property (nonatomic, readonly) BOOL usedHomeDirectoryFallback;

- (instancetype)initWithPID:(pid_t)pid pty:(PTYPair *)pty;
- (instancetype)initWithPID:(pid_t)pid pty:(PTYPair *)pty usedHomeDirectoryFallback:(BOOL)usedHomeDirectoryFallback;

@end

/// Spawns shell processes with PTY support
@interface ProcessSpawner : NSObject

/// Spawns a new shell process with the given configuration
/// Uses /usr/bin/login to properly set up login shell environment
/// Returns nil on failure
+ (nullable ShellSpawnResult *)spawnShellWithConfig:(ShellSpawnConfig *)config
                                              error:(NSError **)error;

/// Checks if user has ~/.hushlogin file
+ (BOOL)hasHushlogin;

/// Gets the user's default shell from passwd database
+ (nullable NSString *)defaultShellForUser:(NSError **)error;

/// Gets the current username
+ (nullable NSString *)currentUsername:(NSError **)error;

/// Waits for a child process and returns its exit status
/// Returns -1 if process is still running (non-blocking)
+ (int)waitForProcess:(pid_t)pid blocking:(BOOL)blocking;

/// Sends a signal to a process
+ (BOOL)killProcess:(pid_t)pid signal:(int)signal error:(NSError **)error;

/// Available process ancestry plus same-user multiplexer/socket identities.
/// Environment output contains only namespaceKeys, never the full environment.
+ (NSArray<NSDictionary<NSString *, id> *> *)localMultiplexerProcesses:(NSArray<NSString *> *)namespaceKeys;

@end

NS_ASSUME_NONNULL_END

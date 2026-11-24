//
//  ProcessSpawner.m
//  rootshell-helper
//
//  Process spawning implementation using fork/exec
//  Based on ghostty/src/termio/Exec.zig
//

#import "ProcessSpawner.h"
#import <sys/wait.h>
#import <sys/stat.h>
#import <sys/ioctl.h>
#import <pwd.h>
#import <signal.h>
#import <unistd.h>
#import <libproc.h>
#import <sys/sysctl.h>
#import <sys/un.h>

static NSString * const RootShellFallbackShell = @"/bin/zsh -f";

@interface ProcessSpawner ()
+ (NSString *)validatedShellOrFallback:(nullable NSString *)candidate;
+ (BOOL)isValidShellCommand:(nullable NSString *)command;
+ (nullable NSString *)executablePathInShellCommand:(NSString *)command;
+ (BOOL)shellQuotesAreBalanced:(NSString *)command;
+ (NSString *)injectShellIntegrationForShell:(NSString *)shell
                              integrationDir:(NSString *)dir
                                 environment:(NSMutableDictionary<NSString *, NSString *> *)env;
@end

@implementation ShellSpawnConfig

- (instancetype)init {
    if (self = [super init]) {
        _size = (PTYSize){24, 80, 0, 0};
        _environment = @{};
        _enableShellIntegration = NO;
    }
    return self;
}

@end

@implementation ShellSpawnResult

- (instancetype)initWithPID:(pid_t)pid pty:(PTYPair *)pty {
    return [self initWithPID:pid pty:pty usedHomeDirectoryFallback:NO];
}

- (instancetype)initWithPID:(pid_t)pid pty:(PTYPair *)pty usedHomeDirectoryFallback:(BOOL)usedHomeDirectoryFallback {
    if (self = [super init]) {
        _pid = pid;
        _pty = pty;
        _usedHomeDirectoryFallback = usedHomeDirectoryFallback;
    }
    return self;
}

@end

@implementation ProcessSpawner

+ (nullable ShellSpawnResult *)spawnShellWithConfig:(ShellSpawnConfig *)config
                                              error:(NSError **)error {
    NSError *localError = nil;

    // Create PTY pair
    PTYPair *pty = [PTYManagerImpl createPTYWithSize:config.size error:&localError];
    if (!pty) {
        if (error) *error = localError;
        return nil;
    }

    // Get user information
    NSString *username = [self currentUsername:&localError];
    if (!username) {
        if (error) *error = localError;
        [pty close];
        return nil;
    }

    // Get and validate the shell. The helper is the authoritative safety
    // boundary because older clients can send unvalidated values.
    NSString *shell = config.shell;
    if (!shell) {
        shell = [self defaultShellForUser:&localError];
    }
    shell = [self validatedShellOrFallback:shell];

    // Automatic shell integration (ghostty src/shell-integration.zig): the
    // environment and, for bash, the exec line are adjusted per shell.
    NSDictionary<NSString *, NSString *> *environment = config.environment;
    if (config.enableShellIntegration && config.shellIntegrationPath && !config.command) {
        NSMutableDictionary *env = [environment mutableCopy];
        shell = [self injectShellIntegrationForShell:shell
                                      integrationDir:config.shellIntegrationPath
                                         environment:env];
        environment = env;
    }

    // Build command arguments
    NSArray<NSString *> *args;
    if (config.command) {
        // Custom command
        args = config.command;
    } else {
        // Use /usr/bin/login to get proper login shell behavior
        // This matches macOS Ghostty and ensures proper session/foreground setup
        args = [self buildLoginCommandWithUsername:username shell:shell];
        if (config.recoveryCommand.length > 0) {
            NSMutableArray *recoveryArgs = [args mutableCopy];
            // login establishes the controlling terminal before this wrapper.
            // Keep the shell integration environment for the eventual shell,
            // but let the attachment command use its own scoped environment.
            recoveryArgs[recoveryArgs.count - 1] = [NSString stringWithFormat:
                @"%@\n%@", config.recoveryCommand, args.lastObject];
            args = recoveryArgs;
        }
        NSLog(@"Launching via /usr/bin/login: %@", shell);
    }

    // Convert to C strings
    char **argv = [self convertToCStringArray:args];
    if (!argv) {
        if (error) {
            *error = [NSError errorWithDomain:@"ProcessSpawner"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to convert arguments"}];
        }
        [pty close];
        return nil;
    }

    // Build environment
    char **envp = [self buildEnvironment:environment];
    if (!envp) {
        [self freeCStringArray:argv];
        if (error) {
            *error = [NSError errorWithDomain:@"ProcessSpawner"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to build environment"}];
        }
        [pty close];
        return nil;
    }

    // Resolve before fork so the child makes no Foundation calls.
    NSString *homeDir = NSHomeDirectory();
    const char *homePath = homeDir.UTF8String;
    const char *workingPath = (config.workingDirectory ?: homeDir).UTF8String;
    BOOL fallbackToHome = config.fallbackToHomeDirectory;
    // Opened here so the reported fallback is exactly what the child does: it
    // fchdirs to this fd or chdirs to HOME, and exits if either fails.
    int workingDirFD = -1;
    const char *fallbackNotice = NULL;
    if (fallbackToHome) {
        workingDirFD = open(workingPath, O_SEARCH | O_CLOEXEC);
        if (workingDirFD < 0) {
            fallbackNotice = [NSString stringWithFormat:@"rootshell: cannot open %s: %s; starting in %s\n",
                              workingPath, strerror(errno), homePath].UTF8String;
        }
    }

    // Fork the process
    // Based on ghostty/src/termio/Exec.zig
    pid_t pid = fork();

    if (pid < 0) {
        // Fork failed
        int fork_errno = errno;
        if (workingDirFD >= 0) close(workingDirFD);
        [self freeCStringArray:argv];
        [self freeCStringArray:envp];
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:fork_errno
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"Failed to fork process",
                NSLocalizedFailureReasonErrorKey: [NSString stringWithUTF8String:strerror(fork_errno)]
            }];
        }
        [pty close];
        return nil;
    }

    if (pid == 0) {
        // Child process
        // Based on ghostty/src/pty.zig:125-176 (childPreExec)

        // Redirect stdin, stdout, stderr to slave PTY FIRST
        // This way all error messages will go to the PTY
        dup2(pty.slaveFD, STDIN_FILENO);
        dup2(pty.slaveFD, STDOUT_FILENO);
        dup2(pty.slaveFD, STDERR_FILENO);

        // Create new session and become session leader
        if (setsid() < 0) {
            perror("setsid failed");
            _exit(1);
        }

        // Set the slave PTY as the controlling terminal
        if (ioctl(pty.slaveFD, TIOCSCTTY, 0) < 0) {
            perror("TIOCSCTTY failed");
            _exit(1);
        }

        // Note: We don't call tcsetpgrp() here - let bash/login handle it during initialization

        // CRITICAL: Unblock all signals first
        // The child inherits the parent's signal mask, and if SIGINT is blocked,
        // it will never be delivered even if ISIG is enabled on the PTY
        sigset_t unblock_all;
        sigemptyset(&unblock_all);
        sigprocmask(SIG_SETMASK, &unblock_all, NULL);

        // Reset signal handlers to defaults
        // (fork inherits signal handlers from parent)
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = SIG_DFL;
        sigemptyset(&sa.sa_mask);

        for (int sig = 1; sig < NSIG; sig++) {
            // Skip signals that can't be caught
            if (sig == SIGKILL || sig == SIGSTOP) continue;
            sigaction(sig, &sa, NULL);
        }

        // Close all other file descriptors
        // Close master and slave (we've dup'd slave to 0/1/2)
        close(pty.masterFD);
        if (pty.slaveFD > STDERR_FILENO) {
            close(pty.slaveFD);
        }

        if (fallbackToHome) {
            if (fallbackNotice) fputs(fallbackNotice, stderr);
            if ((workingDirFD >= 0 ? fchdir(workingDirFD) : chdir(homePath)) != 0) {
                perror("chdir failed");
                _exit(1);
            }
        } else if (chdir(workingPath) != 0) {
            perror("chdir failed");
            _exit(1);
        }

        // Execute the command
        // /usr/bin/login (for shells) or custom command
        execve(argv[0], argv, envp);

        // If we get here, exec failed
        perror("execve failed");
        fprintf(stderr, "Failed to exec: %s\n", argv[0]);
        _exit(127);
    }

    // Parent process

    // Close slave FD in parent (child has its own copy)
    // IMPORTANT: Use closeSlave() method to mark it as closed in PTYPair.
    // Otherwise PTYPair.close() will try to close this fd again later,
    // but by then the fd number may have been reused for something else
    // (like the kqueue for client monitoring), causing subtle bugs.
    [pty closeSlave];
    if (workingDirFD >= 0) close(workingDirFD);

    // Note: The child process sets itself as foreground via tcsetpgrp() before exec
    // We don't do it from the parent because tcsetpgrp() must be called from within the session

    // IMPORTANT: Don't free argv/envp yet! The child process needs them for execve().
    // After fork(), the child shares memory pages with parent (copy-on-write).
    // If we free these arrays now, the child's pointers become invalid.
    // We need to delay freeing until after child has called execve().
    // Small memory leak, but necessary for correctness.
    // TODO: Use vfork() instead of fork() to avoid this issue, or
    // add synchronization to free after child execs.

    // [self freeCStringArray:argv];  // Commented out - causes child to get garbage
    // [self freeCStringArray:envp];  // Commented out - causes child to get garbage

    return [[ShellSpawnResult alloc] initWithPID:pid pty:pty usedHomeDirectoryFallback:fallbackNotice != NULL];
}

+ (NSArray<NSString *> *)buildLoginCommandWithUsername:(NSString *)username
                                                  shell:(NSString *)shell {
    // Based on ghostty/src/termio/Exec.zig:1518-1549
    // Command: /usr/bin/login -q -flp USERNAME /bin/bash --noprofile --norc -c "exec -l SHELL"

    NSMutableArray *args = [NSMutableArray array];

    [args addObject:@"/usr/bin/login"];

    // Add -q flag if user has hushlogin
    if ([self hasHushlogin]) {
        [args addObject:@"-q"];
    }

    // -f: Skip authentication
    // -l: Don't change to home directory (preserves CWD)
    // -p: Preserve environment
    [args addObject:@"-flp"];
    [args addObject:username];

    // Use bash to exec the actual shell
    // Bash is faster than zsh for this operation (~2x)
    [args addObject:@"/bin/bash"];
    [args addObject:@"--noprofile"];
    [args addObject:@"--norc"];
    [args addObject:@"-c"];

    // exec -l replaces bash with the user's shell as a login shell. execfail
    // keeps this non-interactive bash alive only when exec itself fails, so a
    // launch-time race or bad interpreter can still fall through to clean zsh.
    // Once the selected shell starts successfully it replaces bash, and a later
    // normal exit closes the session without invoking the fallback.
    NSString *execCmd = [NSString stringWithFormat:
        @"shopt -s execfail\n"
        @"exec -l %@\n"
        @"exec -l %@\n"
        @"exit 127",
        shell, RootShellFallbackShell];
    [args addObject:execCmd];

    return args;
}

/// Returns the (possibly modified) shell command. zsh gets a ZDOTDIR whose
/// .zshenv chains to the user's; bash runs in POSIX mode with ENV pointing at
/// the script, which replays the login startup files; fish and elvish find
/// their scripts through XDG_DATA_DIRS.
+ (NSString *)injectShellIntegrationForShell:(NSString *)shell
                              integrationDir:(NSString *)dir
                                 environment:(NSMutableDictionary<NSString *, NSString *> *)env {
    NSString *executable = [self executablePathInShellCommand:shell];
    NSString *name = executable.lastPathComponent;

    if ([name isEqualToString:@"zsh"]) {
        NSString *existing = env[@"ZDOTDIR"];
        if (existing) env[@"GHOSTTY_ZSH_ZDOTDIR"] = existing;
        env[@"ZDOTDIR"] = [dir stringByAppendingPathComponent:@"zsh"];
        return shell;
    }

    if ([name isEqualToString:@"bash"]) {
        // The script needs bash 4+; the system /bin/bash is 3.2.
        if ([executable isEqualToString:@"/bin/bash"]) return shell;
        NSString *script = [dir stringByAppendingPathComponent:@"bash/ghostty.bash"];
        if (![[NSFileManager defaultManager] isReadableFileAtPath:script]) return shell;
        NSString *existingEnv = env[@"ENV"];
        if (existingEnv) env[@"GHOSTTY_BASH_ENV"] = existingEnv;
        env[@"ENV"] = script;
        env[@"GHOSTTY_BASH_INJECT"] = @"1";
        // POSIX mode exports HISTFILE; give it the default so history still
        // lands in the usual file, and let the script un-export it.
        if (!env[@"HISTFILE"]) {
            NSString *home = env[@"HOME"] ?: NSHomeDirectory();
            env[@"HISTFILE"] = [home stringByAppendingPathComponent:@".bash_history"];
            env[@"GHOSTTY_BASH_UNEXPORT_HISTFILE"] = @"1";
        }
        return [shell stringByAppendingString:@" --posix"];
    }

    if ([name isEqualToString:@"fish"] || [name isEqualToString:@"elvish"]) {
        // fish: <dir>/fish/vendor_conf.d, elvish: <dir>/elvish/lib. The
        // scripts remove the dir again and key on the XDG_DIR variable.
        NSString *existing = env[@"XDG_DATA_DIRS"];
        env[@"XDG_DATA_DIRS"] = existing.length > 0
            ? [NSString stringWithFormat:@"%@:%@", dir, existing]
            : dir;
        env[@"GHOSTTY_SHELL_INTEGRATION_XDG_DIR"] = dir;
        return shell;
    }

    return shell;
}

+ (BOOL)hasHushlogin {
    // Check for ~/.hushlogin
    // Based on ghostty/src/termio/Exec.zig:1473-1517
    NSString *homedir = NSHomeDirectory();
    NSString *hushloginPath = [homedir stringByAppendingPathComponent:@".hushlogin"];

    struct stat st;
    return (stat([hushloginPath UTF8String], &st) == 0);
}

+ (nullable NSString *)defaultShellForUser:(NSError **)error {
    struct passwd *pw = getpwuid(getuid());
    if (!pw || !pw->pw_shell) {
        if (error) {
            *error = [NSError errorWithDomain:@"ProcessSpawner"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to get user shell"}];
        }
        return nil;
    }

    return [NSString stringWithUTF8String:pw->pw_shell];
}

+ (NSString *)validatedShellOrFallback:(nullable NSString *)candidate {
    NSString *trimmed = [candidate stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (![self isValidShellCommand:trimmed]) {
        NSLog(@"Invalid shell command '%@'; falling back to %@",
              candidate ?: @"(missing)", RootShellFallbackShell);
        return RootShellFallbackShell;
    }

    return trimmed;
}

+ (BOOL)isValidShellCommand:(nullable NSString *)command {
    if (!command || command.length == 0 || command.length > 1024) return NO;
    if ([command rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound) {
        return NO;
    }
    if (![self shellQuotesAreBalanced:command]) return NO;

    NSString *executable = [self executablePathInShellCommand:command];
    if (!executable || ![executable hasPrefix:@"/"]) return NO;

    struct stat executableStat;
    if (stat(executable.fileSystemRepresentation, &executableStat) != 0) return NO;
    if (!S_ISREG(executableStat.st_mode)) return NO;
    return access(executable.fileSystemRepresentation, X_OK) == 0;
}

+ (nullable NSString *)executablePathInShellCommand:(NSString *)command {
    if (command.length == 0) return nil;

    unichar first = [command characterAtIndex:0];
    if (first == '\'' || first == '"') {
        unichar quote = first;
        BOOL escaped = NO;
        for (NSUInteger index = 1; index < command.length; index++) {
            unichar character = [command characterAtIndex:index];
            if (escaped) {
                escaped = NO;
                continue;
            }
            if (quote == '"' && character == '\\') {
                escaped = YES;
                continue;
            }
            if (character == quote) {
                return [command substringWithRange:NSMakeRange(1, index - 1)];
            }
        }
        return nil;
    }

    NSRange separator = [command rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]];
    return separator.location == NSNotFound
        ? command
        : [command substringToIndex:separator.location];
}

+ (BOOL)shellQuotesAreBalanced:(NSString *)command {
    unichar quote = 0;
    BOOL escaped = NO;

    for (NSUInteger index = 0; index < command.length; index++) {
        unichar character = [command characterAtIndex:index];
        if (escaped) {
            escaped = NO;
            continue;
        }
        if (quote == '\'') {
            if (character == '\'') quote = 0;
            continue;
        }
        if (character == '\\') {
            escaped = YES;
            continue;
        }
        if (quote != 0) {
            if (character == quote) quote = 0;
        } else if (character == '\'' || character == '"') {
            quote = character;
        }
    }

    return quote == 0 && !escaped;
}

+ (nullable NSString *)currentUsername:(NSError **)error {
    struct passwd *pw = getpwuid(getuid());
    if (!pw || !pw->pw_name) {
        if (error) {
            *error = [NSError errorWithDomain:@"ProcessSpawner"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to get username"}];
        }
        return nil;
    }

    return [NSString stringWithUTF8String:pw->pw_name];
}

+ (int)waitForProcess:(pid_t)pid blocking:(BOOL)blocking {
    int status;
    int options = blocking ? 0 : WNOHANG;

    pid_t result = waitpid(pid, &status, options);

    if (result == 0) {
        // Process still running (non-blocking)
        return -1;
    } else if (result < 0) {
        // Error
        return -1;
    }

    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }

    return -1;
}

+ (BOOL)killProcess:(pid_t)pid signal:(int)signal error:(NSError **)error {
    if (kill(pid, signal) != 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:errno
                                     userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to send signal %d to process", signal]
            }];
        }
        return NO;
    }
    return YES;
}

#pragma mark - Helper Methods

+ (NSArray<NSDictionary<NSString *, id> *> *)localMultiplexerProcesses:(NSArray<NSString *> *)namespaceKeys {
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (bytes <= 0) return @[];
    NSMutableData *pids = [NSMutableData dataWithLength:(NSUInteger)bytes + 4096];
    bytes = proc_listpids(PROC_ALL_PIDS, 0, pids.mutableBytes, (int)pids.length);
    NSMutableArray *result = [NSMutableArray array];
    NSSet *kinds = [NSSet setWithArray:@[@"tmux", @"zellij", @"herdr", @"zmx"]];
    NSSet *allowed = [NSSet setWithArray:namespaceKeys];
    for (int index = 0; index < bytes / sizeof(pid_t); index++) {
        pid_t pid = ((pid_t *)pids.bytes)[index];
        struct proc_bsdinfo info = {0};
        if (pid <= 0 || proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) continue;
        // login retains a privileged parent above the user's shell. Keep its
        // ancestry/TTY record even when we cannot inspect its executable.
        NSMutableDictionary *record = [@{
            @"pid": @(pid), @"ppid": @(info.pbi_ppid), @"pgid": @(info.pbi_pgid),
            @"tty": @(info.e_tdev), @"foreground": @(info.e_tpgid),
            @"startedAt": @(info.pbi_start_tvsec * 1000000 + info.pbi_start_tvusec)
        } mutableCopy];
        // Ownership gates executable, environment, and socket inspection,
        // independently of the ancestry records needed to find local clients.
        NSString *executable = nil;
        if (info.pbi_uid == getuid()) {
            char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
            if (proc_pidpath(pid, path, sizeof(path)) > 0) {
                executable = [NSString stringWithUTF8String:path];
                if (executable) record[@"executable"] = executable;
            }
        }
        if (executable && [kinds containsObject:executable.lastPathComponent]) {
            // KERN_PROCARGS2 preserves argument boundaries (ps does not).
            int mib[] = {CTL_KERN, KERN_PROCARGS2, pid};
            size_t length = 1024 * 1024;
            NSMutableData *buffer = [NSMutableData dataWithLength:length];
            NSMutableDictionary *environment = [NSMutableDictionary dictionary];
            if (sysctl(mib, 3, buffer.mutableBytes, &length, NULL, 0) == 0 && length > sizeof(int)) {
                const char *cursor = buffer.bytes, *end = cursor + length;
                int argc = 0; memcpy(&argc, cursor, sizeof(argc)); cursor += sizeof(argc);
                size_t count = strnlen(cursor, end - cursor); cursor += count;
                while (cursor < end && *cursor == '\0') cursor++;
                for (int arg = 0; arg < argc && cursor < end; arg++) {
                    count = strnlen(cursor, end - cursor);
                    if (cursor + count >= end) break;
                    cursor += count + 1;
                }
                while (cursor < end) {
                    count = strnlen(cursor, end - cursor);
                    if (cursor + count >= end) break;
                    NSString *value = [[NSString alloc] initWithBytes:cursor length:count encoding:NSUTF8StringEncoding];
                    NSRange equals = [value rangeOfString:@"="];
                    if (value && equals.location != NSNotFound) {
                        NSString *key = [value substringToIndex:equals.location];
                        if ([allowed containsObject:key]) environment[key] = [value substringFromIndex:equals.location + 1];
                    }
                    cursor += count + 1;
                }
            }
            record[@"environment"] = environment;
            NSMutableSet *sockets = [NSMutableSet set];
            NSMutableSet *listeners = [NSMutableSet set];
            int fdBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
            if (fdBytes > 0 && fdBytes < 16 * 1024 * 1024) {
                NSMutableData *fds = [NSMutableData dataWithLength:fdBytes + 1024];
                fdBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds.mutableBytes, (int)fds.length);
                for (int fdIndex = 0; fdIndex < fdBytes / sizeof(struct proc_fdinfo); fdIndex++) {
                    struct proc_fdinfo fd = ((struct proc_fdinfo *)fds.bytes)[fdIndex];
                    if (fd.proc_fdtype != PROX_FDTYPE_SOCKET) continue;
                    struct socket_fdinfo socket = {0};
                    if (proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, sizeof(socket)) != sizeof(socket)
                        || socket.psi.soi_kind != SOCKINFO_UN) continue;
                    struct un_sockinfo un = socket.psi.soi_proto.pri_un;
                    const char *paths[] = {un.unsi_addr.ua_sun.sun_path, un.unsi_caddr.ua_sun.sun_path};
                    for (int p = 0; p < 2; p++) {
                        size_t n = strnlen(paths[p], sizeof(un.unsi_addr.ua_sun.sun_path));
                        if (n == 0 || paths[p][0] != '/' || n == sizeof(un.unsi_addr.ua_sun.sun_path)) continue;
                        NSString *name = [[NSString alloc] initWithBytes:paths[p] length:n encoding:NSUTF8StringEncoding];
                        if (name) {
                            if (p == 1) [sockets addObject:name];
                            if (p == 0 && (socket.psi.soi_options & SO_ACCEPTCONN)) [listeners addObject:name];
                        }
                    }
                }
            }
            record[@"sockets"] = sockets.allObjects;
            record[@"listeners"] = listeners.allObjects;
        }
        [result addObject:record];
    }
    return result;
}

+ (char **)convertToCStringArray:(NSArray<NSString *> *)strings {
    if (!strings) return NULL;

    size_t count = strings.count;
    char **array = malloc((count + 1) * sizeof(char *));
    if (!array) return NULL;

    for (size_t i = 0; i < count; i++) {
        const char *str = [strings[i] UTF8String];
        array[i] = strdup(str);
        if (!array[i]) {
            // Cleanup on failure
            for (size_t j = 0; j < i; j++) {
                free(array[j]);
            }
            free(array);
            return NULL;
        }
    }

    array[count] = NULL;
    return array;
}

+ (char **)buildEnvironment:(NSDictionary<NSString *, NSString *> *)customEnv {
    // DON'T inherit current environment - use ONLY what EnvironmentBuilder provides
    // This prevents iOS/Xcode-specific variables from leaking into shells and
    // breaking downstream tools like openssl, python, etc.
    // The login shell will set up the rest via /etc/profile, ~/.zshrc, etc.
    NSMutableDictionary *env = [NSMutableDictionary dictionaryWithDictionary:customEnv];

    // Convert to C array
    NSMutableArray *envStrings = [NSMutableArray array];
    for (NSString *key in env) {
        NSString *entry = [NSString stringWithFormat:@"%@=%@", key, env[key]];
        [envStrings addObject:entry];
    }

    return [self convertToCStringArray:envStrings];
}

+ (void)freeCStringArray:(char **)array {
    if (!array) return;

    for (char **ptr = array; *ptr != NULL; ptr++) {
        free(*ptr);
    }
    free(array);
}

@end

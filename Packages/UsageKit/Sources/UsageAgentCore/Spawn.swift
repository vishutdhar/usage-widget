import Foundation

/// Spawns `executable` as the leader of a new process group, so a timeout
/// can signal everything it starts. stdin comes from `stdin` (or
/// /dev/null), stdout and stderr go to the given descriptors, signals are
/// at their defaults, and no other descriptor is inherited.
func spawnInOwnGroup(executable: URL, arguments: [String], environment: [String: String],
                     stdin: Int32?, stdout: Int32, stderr: Int32) -> Result<pid_t, RunFailure> {
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    if let stdin {
        posix_spawn_file_actions_adddup2(&actions, stdin, 0)
    } else {
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    }
    posix_spawn_file_actions_adddup2(&actions, stdout, 1)
    posix_spawn_file_actions_adddup2(&actions, stderr, 2)

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
    posix_spawnattr_setflags(&attributes, Int16(flags))
    posix_spawnattr_setpgroup(&attributes, 0)
    var defaults = sigset_t()
    sigfillset(&defaults)
    sigdelset(&defaults, SIGKILL)
    sigdelset(&defaults, SIGSTOP)
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    var mask = sigset_t()
    sigemptyset(&mask)
    posix_spawnattr_setsigmask(&attributes, &mask)

    let argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map { strdup($0) } + [nil]
    let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
        argv.forEach { free($0) }
        envp.forEach { free($0) }
    }

    var pid: pid_t = 0
    let rc = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
    guard rc == 0 else { return .failure(.launchFailed(String(cString: strerror(rc)))) }
    return .success(pid)
}

/**
 * Launchers for prepared applications.
 *
 * `run` follows the beangle/boot idea: after jstart resolves the application
 * and prepares the dependency environment, the process replaces itself with
 * the real application process via exec(). The running process afterwards is
 * `java` (or a native binary in the future), not jstart, and there is no
 * parent/child waiting between them.
 *
 * Native executables will be launched through the same exec based entry.
 */
module jstart.launcher;

import std.array : join;
import std.file : exists;
import std.path : buildPath, pathSeparator;
import std.process : environment;
import std.stdio : stderr, stdout, writeln;
import std.string : toStringz;

version (Posix) {
  import core.sys.posix.unistd : execvp;
} else version (Windows) {
  import std.process : spawnProcess, wait;
}

/** Locate the java executable: $JAVA_HOME/bin/java or "java" on PATH. */
string javaExecutable() {
  auto javaHome = environment.get("JAVA_HOME");
  if (javaHome.length > 0) {
    auto bin = buildPath(javaHome, "bin", "java");
    if (exists(bin)) {
      return bin;
    }
  }
  return "java";
}

/**
 * Launch a jar application with:
 *   java [jvmOptions] -cp <classpath> <Main-Class> [appArgs]
 *
 * On POSIX the current process is replaced by java, so the exit code and
 * signal behavior are java's own. On Windows java runs as a child and its
 * exit code is returned.
 */
int runJarApp(string classpath, string mainClass, string[] jvmOptions,
    string[] appArgs, bool verbose = true) {
  auto java = javaExecutable();
  auto cmd = [java] ~ jvmOptions ~ ["-cp", classpath] ~ [mainClass] ~ appArgs;
  return execCmd(cmd, verbose);
}

/**
 * Launch a native executable, replacing the current process with it.
 * Reserved for future native binary targets.
 */
int runNativeApp(string executable, string[] args, bool verbose = true) {
  return execCmd([executable] ~ args, verbose);
}

/**
 * Replace the current process image with cmd[0] and its arguments.
 * Returns only on failure (exit 127, the shell convention).
 */
version (Posix) private int execCmd(string[] cmd, bool verbose) {
  if (verbose) {
    writeln("Running " ~ cmd.join(" "));
    stdout.flush();
    stderr.flush();
  }
  auto argv = new const(char)*[cmd.length + 1];
  foreach (i, a; cmd) {
    argv[i] = a.toStringz;
  }
  argv[cmd.length] = null;
  // execvp only returns when it failed: the process becomes java.
  execvp(cmd[0].toStringz, argv.ptr);
  stderr.writeln("Cannot execute " ~ cmd[0]);
  return 127;
}

version (Windows) private int execCmd(string[] cmd, bool verbose) {
  if (verbose) {
    writeln("Running " ~ cmd.join(" "));
    stdout.flush();
  }
  try {
    auto pid = spawnProcess(cmd);
    return wait(pid);
  } catch (Exception e) {
    stderr.writeln("Cannot launch " ~ cmd[0] ~ ": " ~ e.msg);
    return 1;
  }
}

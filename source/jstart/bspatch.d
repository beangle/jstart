/**
 * BSDIFF40 patch applier.
 *
 * beangle's build plugin produces native deltas in the classic bsdiff format
 * (8-byte "BSDIFF40" magic, then the control/diff/extra streams compressed
 * with bzip2), so applying a delta locally needs a bspatch.
 *
 * Preference order: the system `bspatch` command when it is installed (some
 * distributions package it; CentOS 8 does not), else a built-in
 * implementation which delegates only the bzip2 part to the host `bzip2`
 * command, the same way downloads are delegated to `curl`.
 * JSTART_BSPATCH=<path> points at a specific bspatch, JSTART_BSPATCH=builtin
 * forces the built-in one.
 */
module jstart.bspatch;

import std.array : split;
import std.conv : to;
import std.file : exists, getSize, mkdirRecurse, read, remove, tempDir, write;
import std.process : ProcessPipes, Redirect, environment, execute, pipeProcess,
  thisProcessID, wait;
import std.stdio : File, stderr, writeln;
import std.string : strip;

/// Whether the host provides the bzip2 command the patch format requires.
bool bzip2Available() {
  try {
    return execute(["bzip2", "--version"]).status == 0;
  } catch (Exception e) {
    return false;
  }
}

/// Whether a patch can be applied at all: a system bspatch, or bzip2 for the built-in one.
bool bspatchAvailable() {
  return systemBspatchPath().length > 0 || bzip2Available();
}

/**
 * System bspatch command: JSTART_BSPATCH if set (``builtin``/``none`` forces
 * the built-in implementation), else `bspatch` found on PATH, else "".
 */
string systemBspatchPath() {
  auto override_ = environment.get("JSTART_BSPATCH");
  if (override_.length) {
    auto value = override_.strip;
    if (value == "builtin" || value == "none" || value == "internal") {
      return "";
    }
    return value;
  }
  foreach (dir; environment.get("PATH").split(":")) {
    if (dir.length == 0) {
      continue;
    }
    auto candidate = dir ~ "/bspatch";
    if (exists(candidate)) {
      return candidate;
    }
  }
  return "";
}

/**
 * Apply the BSDIFF40 patch `patchFile` to `oldFile`, writing the rebuilt
 * file to `newFile`: the system bspatch when available, else the built-in
 * implementation. Returns false (after printing a reason) when the patch
 * cannot be applied; the caller is expected to fall back to a full download.
 */
bool applyBsdiff(string oldFile, string patchFile, string newFile, bool verbose = true) {
  auto command = systemBspatchPath();
  if (command.length) {
    if (applyWithSystemBspatch(command, oldFile, patchFile, newFile, verbose)) {
      return true;
    }
    if (verbose) {
      stderr.writeln("System bspatch unusable, falling back to the built-in implementation");
    }
  }
  return applyBsdiffBuiltin(oldFile, patchFile, newFile, verbose);
}

/// 用系统 bspatch（`bspatch <old> <new> <patch>`）应用补丁，并按 patch 头部校验输出大小。
private bool applyWithSystemBspatch(string command, string oldFile, string patchFile,
    string newFile, bool verbose) {
  if (exists(newFile)) {
    remove(newFile);
  }
  try {
    auto result = execute([command, oldFile, newFile, patchFile]);
    if (result.status != 0) {
      if (verbose) {
        stderr.writeln("bspatch failed (exit " ~ to!string(result.status) ~ "): " ~ result.output.strip);
      }
      return false;
    }
  } catch (Exception e) {
    if (verbose) {
      stderr.writeln("Cannot run " ~ command ~ ": " ~ e.msg);
    }
    return false;
  }
  auto expected = patchOutputLength(patchFile);
  if (!exists(newFile) || (expected > 0 && getSize(newFile) != expected)) {
    if (verbose) {
      stderr.writeln("bspatch produced no usable " ~ newFile);
    }
    if (exists(newFile)) {
      remove(newFile);
    }
    return false;
  }
  return true;
}

/// patch 头部声明的输出大小；读取失败或格式不对返回 -1。
private long patchOutputLength(string patchFile) {
  try {
    auto head = cast(ubyte[]) read(patchFile, 32);
    if (head.length < 32 || cast(string) head[0 .. 8] != "BSDIFF40") {
      return -1;
    }
    return offtin(head[24 .. 32]);
  } catch (Exception e) {
    return -1;
  }
}

/** 内置实现：自己解析 BSDIFF40，只有 bzip2 解压交给宿主命令。 */
bool applyBsdiffBuiltin(string oldFile, string patchFile, string newFile, bool verbose = true) {
  void fail(string msg) {
    if (verbose) {
      stderr.writeln("Cannot apply bsdiff patch: " ~ msg);
    }
  }

  if (!exists(oldFile)) {
    fail("no baseline file " ~ oldFile);
    return false;
  }
  if (!exists(patchFile)) {
    fail("no patch file " ~ patchFile);
    return false;
  }
  ubyte[] patch;
  try {
    patch = cast(ubyte[]) read(patchFile);
  } catch (Exception e) {
    fail("cannot read " ~ patchFile ~ ": " ~ e.msg);
    return false;
  }
  if (patch.length < 32 || cast(string) patch[0 .. 8] != "BSDIFF40") {
    fail("not a BSDIFF40 patch: " ~ patchFile);
    return false;
  }
  auto controlLength = offtin(patch[8 .. 16]);
  auto diffLength = offtin(patch[16 .. 24]);
  auto outputLength = offtin(patch[24 .. 32]);
  if (controlLength <= 0 || diffLength <= 0 || outputLength <= 0) {
    fail("corrupt header in " ~ patchFile);
    return false;
  }
  if (32 + controlLength + diffLength > patch.length) {
    fail("truncated patch " ~ patchFile);
    return false;
  }

  // 三段压缩流各自落到临时文件，再交给 bzip2 解压成管道流
  auto work = tempDir() ~ "/jstart-bspatch-" ~ to!string(thisProcessID);
  if (exists(work)) {
    remove(work);
  }
  mkdirRecurse(work);
  auto controlPath = work ~ "/control.bz2";
  auto diffPath = work ~ "/diff.bz2";
  auto extraPath = work ~ "/extra.bz2";
  scope (exit) {
    foreach (p; [controlPath, diffPath, extraPath]) {
      if (exists(p)) {
        remove(p);
      }
    }
    if (exists(work)) {
      remove(work);
    }
  }
  write(controlPath, patch[32 .. cast(size_t)(32 + controlLength)]);
  write(diffPath, patch[cast(size_t)(32 + controlLength) .. cast(size_t)(32 + controlLength + diffLength)]);
  write(extraPath, patch[cast(size_t)(32 + controlLength + diffLength) .. $]);

  ProcessPipes[3] pipes;
  try {
    pipes[0] = pipeProcess(["bzip2", "-d", "-c", controlPath], Redirect.stdout);
    pipes[1] = pipeProcess(["bzip2", "-d", "-c", diffPath], Redirect.stdout);
    pipes[2] = pipeProcess(["bzip2", "-d", "-c", extraPath], Redirect.stdout);
  } catch (Exception e) {
    fail("cannot start bzip2: " ~ e.msg);
    return false;
  }
  scope (exit) {
    // 先关读端再 wait：否则 bzip2 可能阻塞在写管道上，wait 会死等
    foreach (i; 0 .. pipes.length) {
      if (pipes[i].pid !is null) {
        pipes[i].stdout.close();
        wait(pipes[i].pid);
      }
    }
  }

  auto control = pipes[0].stdout;
  auto diff = pipes[1].stdout;
  auto extra = pipes[2].stdout;
  ubyte[] oldData;
  try {
    oldData = cast(ubyte[]) read(oldFile);
  } catch (Exception e) {
    fail("cannot read " ~ oldFile ~ ": " ~ e.msg);
    return false;
  }

  auto output = File(newFile, "wb");
  bool ok = true;
  long oldPos = 0;
  long newPos = 0;
  while (newPos < outputLength) {
    ubyte[24] ctrl;
    if (!readExact(control, ctrl)) {
      fail("truncated control stream");
      ok = false;
      break;
    }
    auto diffSize = offtin(ctrl[0 .. 8]);
    auto extraSize = offtin(ctrl[8 .. 16]);
    auto seekSize = offtin(ctrl[16 .. 24]);
    if (diffSize < 0 || extraSize < 0) {
      fail("negative block size");
      ok = false;
      break;
    }
    if (diffSize > 0) {
      auto block = new ubyte[cast(size_t) diffSize];
      if (!readExact(diff, block)) {
        fail("truncated diff stream");
        ok = false;
        break;
      }
      foreach (i; 0 .. block.length) {
        auto from = oldPos + i;
        if (from >= 0 && from < oldData.length) {
          block[i] = cast(ubyte)(block[i] + oldData[cast(size_t) from]);
        }
      }
      output.rawWrite(block);
      newPos += diffSize;
      oldPos += diffSize;
    }
    if (extraSize > 0) {
      auto block = new ubyte[cast(size_t) extraSize];
      if (!readExact(extra, block)) {
        fail("truncated extra stream");
        ok = false;
        break;
      }
      output.rawWrite(block);
      newPos += extraSize;
    }
    oldPos += seekSize;
  }
  output.close();
  if (ok && getSize(newFile) != outputLength) {
    fail("rebuilt size mismatch: " ~ to!string(getSize(newFile)) ~ " != " ~ to!string(outputLength));
    ok = false;
  }
  if (!ok && exists(newFile)) {
    remove(newFile);
  }
  return ok;
}

/// bsdiff "off_t": 7 magnitude bytes big-endian with the sign in byte 7.
private long offtin(const(ubyte)[] buf) {
  long y = buf[7] & 0x7F;
  y = (y << 8) | buf[6];
  y = (y << 8) | buf[5];
  y = (y << 8) | buf[4];
  y = (y << 8) | buf[3];
  y = (y << 8) | buf[2];
  y = (y << 8) | buf[1];
  y = (y << 8) | buf[0];
  return (buf[7] & 0x80) ? -y : y;
}

/// Read exactly buf.length bytes; false on premature end of stream.
private bool readExact(File input, ubyte[] buf) {
  size_t read = 0;
  while (read < buf.length) {
    auto chunk = input.rawRead(buf[read .. $]);
    if (chunk.length == 0) {
      return false;
    }
    read += chunk.length;
  }
  return true;
}

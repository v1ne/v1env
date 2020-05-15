#!/usr/bin/env rdmd
/*
 * BSD 2-Clause License
 *
 * Copyright (c) 2020, v1ne <v1ne2go@gmail.com>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 *    list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

module autoFixup;

immutable auto branchFileName = ".config/v1/git_named_branches";
immutable auto programName = "auto-fixup.d";
immutable auto programDescription =
"Automatically create fixup commits for the given selection of files, or
what's currently staged or what's currently modified. A base commit to
create a fixup for is the commit that last touched a line that the fixup
will change or remove.

A fixup is only created if the base commit is unique.
Also, the fixup is not created if the base commit is already on
origin/master or a named branch from ~/" ~ branchFileName ~",
because this implies that the base commit is already on an append-only
upstream branch.

Options:";

import core.stdc.stdlib;
import std.algorithm.iteration;
import std.algorithm.sorting;
import std.array;
import std.ascii;
import std.conv;
import std.exception: ErrnoException;
import std.getopt;
import std.path: buildPath, isAbsolute;
import std.process;
import std.range.primitives;
import std.regex;
import std.stdio;
import std.string;


struct Parameters {
  bool createSquashInsteadOfFixup;
  bool dryRun;
  bool force;
  bool verbose;
}

int main(string[] args) {
  Parameters parms;
  auto result = getopt(args,
    std.getopt.config.caseSensitive,
    std.getopt.config.bundling,
    "force|f", "Create fixup even though base commit is on a named branch", &parms.force,
    "dry-run|n", "Only determine base commit, don't create fixup", &parms.dryRun,
    "squash|s", "Create squash instead of fixup", &parms.createSquashInsteadOfFixup,
    "verbose|v", "Babble about what I'm doing", &parms.verbose);
  if(result.helpWanted) {
    writeln("Usage: %s [-%s] [files...]".format(
      programName, result.options.map!(opt => opt.optShort[1])));
    defaultGetoptPrinter(programDescription, result.options);
    return 0;
  }

  auto fileInfo = filesToCommit(parms, args[1..$]);
  if(fileInfo.files.empty) {
    writeln("No files changed. Nothing to fix up.");
    return 0;
  }

  auto removedLines = removedLinesInFiles(parms, fileInfo);
  if(removedLines.empty) {
    stdout.flush();
    stderr.writeln("No lines removed. Cannot fix up.");
    return 1;
  }

  auto previousCommits = commitsPreviouslyModifyingChangedLinesIn(parms, removedLines);
  auto baseCommits = baseCommitsFromFixupAndSquashes(parms, previousCommits);

  if(baseCommits.length > 1) {
    stdout.flush();
    stderr.writeln("Not fixing up. Found multiple base commits:", std.ascii.newline,
      baseCommits.toString);
    return 1;
  }

  if(!isBaseCommitAfterNamedBranches(parms, baseCommits[0].hash)) {
    if(parms.force)
      stdout.writeln("Warning: Fixing up commit that is on a named branch.");
    else {
      stdout.flush();
      stderr.writeln("Not fixing up. Base commit is on a named branch.");
      return 1;
    }
  }

  return createFixup(parms, fileInfo, baseCommits);
}


immutable auto gitCmd = "git";

auto executeGitCmd(string[] gitParameters) {
    auto cmdline = [gitCmd] ~ gitParameters;
    auto result = execute(cmdline);
    if(result.status != 0) {
      stdout.flush();
      stderr.writeln("Git command \"" ~ cmdline.join(" ") ~ "\" failed: ",
        std.ascii.newline, result.output);
      exit(1);
    }

    return result.output.lineSplitter();
 }

struct FileInfo {
  string[] files;
  bool useStaged;
}

auto filesToCommit(const ref Parameters parms, string[] args) {
  FileInfo fileInfo;

  if(!args.empty) {
    auto prefix = environment.get("GIT_PREFIX");
    fileInfo.files = prefix.empty
      ? args
      : args.map!(path => isAbsolute(path) ? path : buildPath(prefix, path)).array;
  } else {
    string[] staged;
    string[] modified;
    foreach(line; executeGitCmd(["status", "--porcelain"])) {
      if(line[0] == 'D' || line[0] == 'M' || line[0] == 'R')
        staged ~= line[3..$];
      else if(line[1] == 'D' || line[1] == 'M' || line[1] == 'R')
        modified ~= line[3..$];
    }

    if(!staged.empty) {
      fileInfo.files = staged;
      fileInfo.useStaged = true;
    } else if(!modified.empty) {
      fileInfo.files = modified;
    }
  }

  if(parms.verbose && !fileInfo.files.empty)
    writeln(fileInfo.useStaged ? "Staged " : "Modified ", "files to investigate: ",
      std.ascii.newline, "  ", fileInfo.files.join(" "));

  return fileInfo;
}

struct SubmoduleState {
  int linesAdded;
  int linesRemoved;
  int linesUnmodified;
}

struct ChangedFile {
  string filename;

  struct LinePair {
    int beginLine;
    int endLine;
  }
  LinePair[] hunks;
}

auto removedLinesInFiles(const ref Parameters parms, FileInfo fileInfo) {
  ChangedFile.LinePair[][string] hunks;

  ChangedFile.LinePair currentHunk;
  string currentFile;
  int currentLine = 0;

  SubmoduleState submoduleState;

  void endCurrentHunk() {
    if(submoduleState.linesAdded == 1 && submoduleState.linesRemoved == 1 && submoduleState.linesUnmodified == 0) {
      if(parms.verbose)
        writeln("Ignoring modified submodule: ", currentFile);
        submoduleState = SubmoduleState();
    }

    if(currentHunk.beginLine > 0) {
      hunks.require(currentFile, []) ~= currentHunk;
      currentHunk.beginLine = 0;
    }
  }

  foreach(line; executeGitCmd(["diff", "-p"]
      ~ (fileInfo.useStaged ? ["--staged"] : ["HEAD", "--"] ~ fileInfo.files))) {
    if(line.startsWith("diff --git a/") || line.startsWith("+++ b/") || line.startsWith("index ")) {
      /* ignore */
    } else if(line.startsWith("--- a/")) {
      endCurrentHunk();

      currentFile = line[6..$];
      submoduleState = SubmoduleState();
    } else if(line.startsWith("@@")) {
      endCurrentHunk();

      auto minusIndex = line.indexOf('-');
      auto commaIndex = line[minusIndex..$].indexOfAny(",") + minusIndex;
      if(commaIndex < minusIndex)
        continue; // submodule
      currentLine = line[minusIndex+1..commaIndex].to!int;
    } else if(line.startsWith("-Subproject commit ")) {
      submoduleState.linesRemoved++;
      ++currentLine;
    } else if(line.startsWith("+Subproject commit ")) {
      ++submoduleState.linesAdded;
    } else if(line.startsWith("-")) {
      if(currentHunk.beginLine == 0)
        currentHunk.beginLine = currentLine;
      currentHunk.endLine = currentLine + 1;

      ++currentLine;
    } else if(line.startsWith("+")) {
      /* ignore */
    } else if(line.startsWith(" ")) {
      endCurrentHunk();

      ++currentLine;
      ++submoduleState.linesUnmodified;
    } else {
      if(parms.verbose)
        writeln("In git diff output for ", currentFile, ", ignoring unrecognised line: ", line);
      endCurrentHunk();
    }
  }
  endCurrentHunk();

  auto result = hunks.keys.map!(filename => ChangedFile(filename, hunks[filename])).array;

  if(parms.verbose)
    writeln("Removed hunks:", std.ascii.newline,
      result.map!(file =>
        "  " ~ file.filename ~ ": "
        ~ file.hunks.map!(hunk => to!string(hunk.beginLine) ~ "-" ~ to!string(hunk.endLine))
          .join(", "))
      .join(std.ascii.newline));

  return result;
}


struct CommitHashAndTitle {
  string hash;
  size_t time;
  string title;
}

auto toString(CommitHashAndTitle[] commits) {
  return "  " ~ commits
    .map!(cah => cah.hash ~ " " ~ cah.title)
    .join(std.ascii.newline ~ "  ");
}

auto commitsPreviouslyModifyingChangedLinesIn(
    const ref Parameters parms, ChangedFile[] files) {
  CommitHashAndTitle[string] commitMap;
  foreach(file; files) {
    auto blame = executeGitCmd(["blame", "--porcelain"]
      ~ file.hunks.map!(hunk =>
          ["-L", to!string(hunk.beginLine) ~ "," ~ to!string(hunk.endLine -1)]).joiner.array
      ~ ["HEAD", "--", file.filename]);

    string hash;
    auto hashLineRegex = regex("^([0-9a-f]+) [0-9]+ [0-9]+");
    foreach(line; blame) {
      if(auto match = line.matchFirst(hashLineRegex)) {
        hash = match[1];
        commitMap.require(hash, CommitHashAndTitle(hash));
      } else if(line.startsWith("author-time ")) {
        commitMap[hash].time = to!size_t(line[12..$]);
      } else if(line.startsWith("summary ")) {
        commitMap[hash].title = line[8..$];
      }
    }
  }

  auto commits = commitMap.values;

  if(parms.verbose)
    writeln("Base commit candidates:", std.ascii.newline, commits.toString);

  return commits;
}

auto baseCommitsFromFixupAndSquashes(
    const ref Parameters parms, CommitHashAndTitle[] potentialBaseCommits) {
  CommitHashAndTitle[] baseCommits = potentialBaseCommits
    .map!(commit => {
        auto title = commit.title;
        while (title.startsWith("fixup! ") || title.startsWith("squash! "))
          title = title[title.indexOf(' ')+1..$];
        return CommitHashAndTitle(commit.hash, commit.time, title);
      }())
    .array;

  // Keep oldest commit ("base commit"), not some newer commit ("fixup! fixup! fixup! base commit")
  sort!("a.title < b.title || (a.title == b.title && a.time < b.time)")(baseCommits);
  baseCommits = baseCommits.uniq!("a.title == b.title").array;
  sort!("a.time < b.time")(baseCommits);

  return baseCommits;
}

bool isBaseCommitAfterNamedBranches(const ref Parameters parms, string baseCommitHash) {
  auto namedBranches = ["origin/master"];

  auto basesFilePath = buildPath(environment.get("HOME"), branchFileName);
  try {
    auto basesFile = File(basesFilePath);
    namedBranches ~= basesFile
      .byLineCopy()
      .map!strip
      .filter!(line => !line.empty && !line.startsWith('#'))
      .map!(splitter).joiner
      .map!strip
      .array;
  } catch(ErrnoException) {
    if(parms.verbose)
      writeln("Unable to open ", basesFilePath);
  }

  if(parms.verbose)
    writeln("Named branches to check against: " ~ namedBranches.join(" "));

  auto isNotBeforeOrAtNamedBranch =
    executeGitCmd(["rev-list", "--ignore-missing", "--parents", "--reverse", baseCommitHash]
      ~ namedBranches.map!(base => "^" ~ base).array)
    .empty;
  return !isNotBeforeOrAtNamedBranch;
}

int createFixup(const ref Parameters parms, FileInfo fileInfo, CommitHashAndTitle[] baseCommits) {
  assert(baseCommits.length == 1);
  auto shortBaseCommitHash = executeGitCmd(["rev-parse", "--short", baseCommits[0].hash]).front;
  auto baseCommitString = shortBaseCommitHash ~ ": " ~ baseCommits[0].title;
  auto type = parms.createSquashInsteadOfFixup ? "squash" : "fixup";

  if(parms.dryRun) {
    writeln("Would create %s for base commit %s".format(type, baseCommitString));
  } else {
    auto result = executeGitCmd(
      ["commit", "--%s=%s".format(type, baseCommits[0].hash)]
      ~ (fileInfo.useStaged ? [] : fileInfo.files));
    auto hashLines = result.filter!(line => line.startsWith('[')).array;
    if(hashLines.length != 1) {
      stdout.flush();
      stderr.writeln("Unexpected output from Git: " ~ result.join(std.ascii.newline));
      exit(1);
    }
    auto hashLine = hashLines.front;
    auto fixupHash = hashLine[hashLine.indexOf(' ') + 1 .. hashLine.indexOf(']')];
    writeln("Created %s %s for base commit %s".format(type, fixupHash, baseCommitString));
  }

  return 0;
}

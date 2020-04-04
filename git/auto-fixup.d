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

immutable auto programDescription =
"Automatically create fixup commits for what's currently staged,
modified or the given selection of files. Fixups are only created
if the base commit that all changed or removed lines refer to is
unique.

Options:";

import core.stdc.stdlib;
import std.algorithm.iteration;
import std.algorithm.sorting;
import std.array;
import std.ascii;
import std.conv;
import std.getopt;
import std.process;
import std.range.primitives;
import std.regex;
import std.stdio;
import std.string;


struct Parameters {
  bool dryRun;
  bool verbose;
}

int main(string[] args) {
  Parameters parms;
  auto result = getopt(args,
    std.getopt.config.caseSensitive,
    std.getopt.config.bundling,
    "dry-run|n", "Only determine base commit, don't create fixup", &parms.dryRun,
    "verbose|v", "Babble about what I'm doing", &parms.verbose);
  if(result.helpWanted) {
    writeln("Usage: %s [-%s] [files...]".format(
      args[0], result.options.map!(opt => opt.optShort[1])));
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

  if(!args.empty)
    fileInfo.files = args;
  else {
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

  void endCurrentHunk() {
    if(currentHunk.beginLine > 0) {
      hunks.require(currentFile, []) ~= currentHunk;
      currentHunk.beginLine = 0;
    }
  }

  foreach(line; executeGitCmd(["diff", "-p"]
      ~ (fileInfo.useStaged ? ["--staged"] : "--" ~ fileInfo.files))) {
    if(line.startsWith("--- a/")) {
      endCurrentHunk();

      currentFile = line[6..$];
    } else if(line.startsWith("@@")) {
      endCurrentHunk();

      auto minusIndex = line.indexOf('-');
      auto commaIndex = line[minusIndex..$].indexOfAny(",") + minusIndex;
      if(commaIndex < minusIndex)
        continue; // submodule
      currentLine = line[minusIndex+1..commaIndex].to!int;
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
    } else {
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

  }

int createFixup(const ref Parameters parms, FileInfo fileInfo, CommitHashAndTitle[] baseCommits) {
  assert(baseCommits.length == 1);
  auto shortBaseCommitHash = executeGitCmd(["rev-parse", "--short", baseCommits[0].hash]).front;
  auto baseCommitString = shortBaseCommitHash ~ ": " ~ baseCommits[0].title;

  if(parms.dryRun) {
    writeln("Would create fixup for base commit ", baseCommitString);
  } else {
    auto result = executeGitCmd(["commit", "--fixup=" ~ baseCommits[0].hash] ~
      (fileInfo.useStaged ? [] : fileInfo.files)).front;
    auto fixupHash = result[result.indexOf(' ') + 1 .. result.indexOf(']')];
    writeln("Created fixup ", fixupHash, " for base commit ", baseCommitString);
  }

  return 0;
}

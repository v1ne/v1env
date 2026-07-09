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


/*
 * Known bugs:

  BUG 1: Dry-run exit code is always 1 (not 0)
  Location: auto-rebase.d:277

  if(parms.dryRun) return true; In D, true → 1 when returned as int. So -n
  always exits with status 1 (failure), even on success. The "Nothing to rebase"
  path returns 0, so the exit code is inconsistent between success states.

  Evidence: Every -n invocation in my tests exits with code 1.


  BUG 2: Fixup targeting the root commit crashes
  Location: auto-rebase.d:134
  (parentCommit) combined with auto-rebase.d:214, 270

  string parentCommit(string commit) { return commit.empty ? "" : commit ~ "^";
  } If a fixup targets the root commit, parentCommit returns <root>^, which is
  not a valid git ref. Then revParse fails and the program dies with fatal: bad
  revision.

  Reproduction:

  commit 1: "root" commit 2: "fixup! root" $ auto-rebase.d -F -n → Git command
  "git rev-parse 116500c^ --" failed: fatal: bad revision '116500c^'


  BUG 3: Ambiguous title matching picks newest, not target Location:
  auto-rebase.d:168-197 (earliestMentionedTitle)

  When two commits share the same subject line (e.g., "Update docs"), a fixup!
  Update docs matches the newest commit with that title, not necessarily the
  intended target. The assoc-array key collision also means the fixup-hash used
  for error reporting may not be the intended one.

  Reproduction: Created two "Update docs" commits on either side of
  origin/master; fixup resolved to the newer one.


  BUG 4: Duplicate fixup targets collapse in assocArray Location:
  auto-rebase.d:155-166 (toOriginalTitleToHashMap)

  If multiple fixups reference the same target title, they all produce the same
  map key, and .assocArray keeps only one value. This means:

  Only one fixup-commit hash survives for error reporting.  If that single fixup
  can't be resolved, the "Unable to resolve" message lists it once instead of
  listing all duplicates.


  BUG 5: Unused start parameter Location:
  auto-rebase.d:168

  string earliestMentionedTitle(string start, string[string] titlesToHashes)
  start is always passed as "HEAD" but never referenced in the body. Dead code —
  if the intent was to scope the log walk, the bug is that it isn't.


  BUG 6: origin/master is hardcoded Location:
  auto-rebase.d:221

  auto possibleBases = ["origin/master"]; No way to configure the upstream.
  Repos using main, a different remote, or no remote at all get silently wrong
  behavior. --ignore-missing masks the missing ref rather than producing a clear
  error.
 */

module autoRebase;

immutable auto branchFileName = ".config/v1/git_named_branches";
immutable auto programName = "auto-rebase.d";
immutable auto programDescription =
"Rebase the current branch in a branch-develop-merge scenario

In a workflow that branches off origin/master, adds changes and merges them
back, the changes need to be reshuffled frequently. This reshuffling needs a
suitable base commit to rebase the current set of changes on.
That base commit is selected to be the latest of origin/master and
named commits from ~/" ~ branchFileName ~". Dead branch names are ignored.

When selecting -f to cover all fixups from the base commit to HEAD, the base
commit can move back or forth. Thus, the new base commit can lay before or
beyond e.g. origin/master. This is useful to restrict the number of commits
shown in the rebase as well as when rewriting historic commits.

Options:";

import core.stdc.stdlib;
import std.algorithm.iteration;
import std.array;
import std.ascii;
import std.conv;
import std.exception: ErrnoException;
import std.getopt;
import std.path: buildPath;
import std.process;
import std.range.primitives;
import std.range;
import std.stdio;
import std.string;
import std.typecons: tuple;


struct Parameters {
  bool allFixups;
  bool autosquash;
  bool dryRun;
  bool smallBaseForFixups;
  bool verbose;
}

int main(string[] args) {
  Parameters parms;
  auto result = getopt(args,
    std.getopt.config.caseSensitive,
    std.getopt.config.bundling,
    std.getopt.config.passThrough,
    "a", "Pass --autosquash to the final \"git rebase\" command",
      &parms.autosquash,
    "f", "Use smallest base covering all fixups/squashes in base..HEAD",
      &parms.smallBaseForFixups,
    "F", "Use base x covering all fixups in the entire history",
      &parms.allFixups,
    "n", "Dry run, only show base commit",
      &parms.dryRun,
    "v", "Babble about what I'm doing",
      &parms.verbose);
  if(result.helpWanted) {
    writeln("Usage: %s [-%s] [files...]".format(
      programName, result.options.map!(opt => opt.optShort[1])));
    defaultGetoptPrinter(programDescription, result.options);
    return 0;
  }

  auto base = parms.allFixups ? baseForFixups(parms) : baseFromBranches(parms);
  if(base.empty) {
    writeln("Nothing to rebase. You're probably on the base commit.");
    return 0;
  }

  if(parms.smallBaseForFixups) {
    base = restrictBaseForFixups(parms, base);
    if(base.empty) {
      writeln("No fixups found, no rebase needed.");
      return 0;
    }
  }

  return rebase(parms, args, base);
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

string revParse(string rev) {
  return executeGitCmd(["rev-parse", rev, "--"]).front;
}

string parentCommit(string commit) {
  return commit.empty ? "" : commit ~ "^";
}

struct HashAndTitle {
  string hash;
  string title;
}

void printHashesAndTitles(string title, HashAndTitle[] hats) {
  writeln(title);
  foreach(hat; hats)
    writeln("  ", hat.title);
}

auto hashAndTitleFromGitCmd(string[] gitParameters) {
  return executeGitCmd(gitParameters)
    .map!(line => {auto sep = line.indexOf(" ");
      return HashAndTitle(line[0..sep], line[sep+1..$]);}());
}

//! returns a map original title -> hash
string[string] toOriginalTitleToHashMap(HashAndTitle[] hats) {
  return hats.map!(hat => {
      auto title = hat.title.strip;
      while (title.startsWith("fixup! ") || title.startsWith("squash! "))
        title = title[title.indexOf(' ')+1..$].stripLeft;

      if(title.indexOf('"') == 0 && title.lastIndexOf('"') == title.length - 1)
        title = title[1..$-1].strip;

      return tuple(title, hat.hash);
    }()).assocArray;
}

string earliestMentionedTitle(string start, string[string] titlesToHashes) {
  if(titlesToHashes.empty)
    return "";

  string lastHash;
  foreach(hat; hashAndTitleFromGitCmd(["log", "--format=%H:%h %s"])) {
    auto hashes = hat.hash.split(':').array;
    auto fullHash = hashes[0];
    auto abbrevHash = hashes[1];

    lastHash = abbrevHash;
    if(hat.title in titlesToHashes || fullHash in titlesToHashes || abbrevHash in titlesToHashes) {
      titlesToHashes.remove(hat.title);
      titlesToHashes.remove(fullHash);
      titlesToHashes.remove(abbrevHash);
    }

    if(titlesToHashes.empty)
      break;
  }

  if(!titlesToHashes.empty) {
    stdout.flush();
    stderr.writeln("Unable to resolve these fixups: ");
    foreach(title; titlesToHashes.keys) stderr.writeln("  ", titlesToHashes[title], " ", title);
    exit(1);
  }

  return lastHash;
}

// traverse the whole commit history to find the first fixup/squash
string baseForFixups(const ref Parameters parms) {
  auto hashesAndTitles =
    hashAndTitleFromGitCmd(["log", "--extended-regexp", r"--grep=^fixup!|^squash!", "--format=%h %s"])
      .filter!(hat => hat.title.startsWith("fixup!") || hat.title.startsWith("squash!"))
      .array;

  if(parms.verbose)
    printHashesAndTitles("Found fixups/squashes:", hashesAndTitles);

  auto earliestReferencedCommitHash =
    earliestMentionedTitle("HEAD", toOriginalTitleToHashMap(hashesAndTitles));
  if(parms.verbose)
    writeln("Earliest referenced commit: ", earliestReferencedCommitHash);

  return earliestReferencedCommitHash.parentCommit;
}

/*
 * Find the latest commit from a set of possible bases that leads up to HEAD.
 */
string baseFromBranches(const ref Parameters parms) {
  auto possibleBases = ["origin/master"];

  auto basesFilePath = buildPath(environment.get("HOME"), branchFileName);
  try {
    auto basesFile = File(basesFilePath);
    possibleBases ~= basesFile
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
    writeln("Possible bases: " ~ possibleBases.join(" "));

  auto commitsSucceedingLatestBase =
    executeGitCmd(["rev-list", "--ignore-missing", "--parents", "--reverse", "HEAD"]
      ~ possibleBases.map!(base => "^" ~ base).array)
    .filter!(line => line.indexOf(' ') >= 0) // exclude parentless root commit
    .map!(line => line[0..line.indexOf(' ')]);
  auto commitSucceedingLatestBase =
    commitsSucceedingLatestBase.empty ? "" : commitsSucceedingLatestBase.front;
  if(parms.verbose)
    writeln("Latest base: ", commitSucceedingLatestBase);

  return commitSucceedingLatestBase.parentCommit;
}

// move "base" closer to HEAD so that only fixups/squashs are covered
string restrictBaseForFixups(const ref Parameters parms, string base) {
  auto hashesAndTitles =
    hashAndTitleFromGitCmd(
        ["log", "--extended-regexp", r"--grep=^fixup!|^squash!", "--format=%H %s", base ~ "..HEAD"])
      .filter!(hat => hat.title.startsWith("fixup!") || hat.title.startsWith("squash!"))
      .array;

  if(parms.verbose)
    printHashesAndTitles("Fixups in range:", hashesAndTitles);

  auto earliestReferencedCommitHash =
    earliestMentionedTitle("HEAD", toOriginalTitleToHashMap(hashesAndTitles));
  if(parms.verbose)
    writeln("Earliest referenced commit: ", earliestReferencedCommitHash);

  return earliestReferencedCommitHash.parentCommit;
}

int rebase(const ref Parameters parms, string[] args, string base) {
  if(parms.dryRun || parms.verbose)
    writeln("Base commit: " ~ revParse(base));
  if(parms.dryRun)
    return true;

  stdout.flush();
  stderr.flush();
  return wait(spawnProcess([gitCmd, "rebase", "-i", base]
    ~ (parms.autosquash ? ["--autosquash"] : [])
    ~ args[1..$]));
}

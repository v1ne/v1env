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

module lizensator;

immutable auto programName = "lizensator.d";
immutable auto programDescription = "Licence boilerplate management tool

Gathers license information from the specified directories, stored the
information and a central place. The tool can also verify that licenses
haven't changed.

Options:";

import core.stdc.stdlib: exit;
import std.algorithm: min;
import std.algorithm.iteration;
import std.algorithm.sorting: sort;
import std.algorithm.searching: until;
import std.array;
import std.conv;
import std.digest.sha;
import std.file;
import std.format;
import std.getopt;
import std.path: dirName;
import std.range: drop;
import std.regex;
import std.stdio;
import std.string;
import std.typecons: tuple;

immutable auto kInfoFileName = "README.md";
immutable auto kBeginLicenses = "<!-- V1LIC-BEGIN-LICENSES -->";
immutable auto kEndLicenses = "<!-- V1LIC-END-LICENSES -->";
immutable auto kTriggerPrefix = "<!-- V1LIC-";
immutable auto kTriggerEnd = " -->";
immutable auto kBeginLicense = "<!-- V1LIC-BEGIN-LICENSE ";
immutable auto kLicensePath = "<!-- V1LIC-LICENSE-FILE-PATH -->";
immutable auto kDefaultText = "<!-- V1LIC-BEGIN-LICENSE path= hash= -->
* [name](URL): Short description<br/>
  License file: <!-- V1LIC-LICENSE-FILE-PATH --> `` <br/>";

struct Parameters {
  bool dryRun;
  bool verbose;
  bool verify;
}
Parameters params;

int main(string[] args) {
  auto result = getopt(args, std.getopt.config.caseSensitive, std.getopt.config.bundling,
    "check|verify|c", "Check that all license information is up-to-date", &params.verify,
    "dry-run|n", "Only determine what would be done, don't write any file", &params.dryRun,
    "verbose|v", "Babble about what I'm doing", &params.verbose
  );
  if (result.helpWanted) {
    writeln("Usage: %s [-%s] [directories and files...]".format(programName,
        result.options.map!(opt => opt.optShort[1])));
    defaultGetoptPrinter(programDescription, result.options);
    return 0;
  }

  auto licenseFiles = findLicenseFiles(args[1 .. $]);
  auto licenses = parseThirdPartyModules(licenseFiles);
  if(params.verbose) {
    if(!licenses.empty)
      writeln("Licenses found: \n  " ~ licenses.map!(l => "%s: %s".format(
        l.info.licenseFilePath, l.info.hash)).join("\n  "));
    else
      writeln("No licenses found.");
  }

  auto info = readInfoFile(kInfoFileName);
  auto updateResult = updateThirdPartyModuleInfos(info, licenses.map!(parsedLicense => parsedLicense.info).array);

  if(params.verify) {
    if(updateResult.changes.empty()) {
      if(params.verbose) writeln("License information up to data.");
      return 0;
    } else {
      stderr.writeln("FAIL: License information changed: ", updateResult.changes.join(", "));
      return 1;
    }
  }

  if(params.dryRun) {
    if(params.verbose) writeln("----------------- Merged output: -----------------");
    writeInfoFile(stdout, updateResult.fileParts);
  } else {
    if(params.verbose) writeln("Writing updated information to " ~ kInfoFileName);
    writeInfoFile(File(kInfoFileName, "w"), updateResult.fileParts);
  }

  return 0;
}

string[] findLicenseFiles(string[] paths) {
  string[] files;

  if (paths.empty()) {
    paths = ["."];
  }

  foreach (path; paths) {
    if (isFile(path))
      files ~= path;
    else
      files ~= dirEntries(path, "{LICENSE,LICENSE.,LICENSING.}*", SpanMode.depth)
        .filter!(e => e.isFile)
        .map!(e => e.name)
        .array;
  }
  return files;
}

struct ThirdPartyModuleInfo {
  string path;
  string licenseFilePath;
  string hash;
  string text;
}

struct ParsedThirdPartyModule {
  ThirdPartyModuleInfo info;
  string licenseText;
}

ParsedThirdPartyModule[] parseThirdPartyModules(string[] filePaths) {
  string filteredLicense(string filename) {
    auto copyrightRe = regex("(copyright *)?(\\(c\\)|©) *[0-9]+(-[0-9]+)* *[\\w,.; @<>()\\[\\]_-]+");

    return File(filename).byLine()
      .map!strip
      .map!toLower
      .map!(l => l.replaceAll(copyrightRe, "COPYRIGHT"))
      .map!split.joiner.join(" ") // merge spaces and empty lines by word-splitting
      .to!string;
  }

  return filePaths.map!(licenseFilePath => {
    auto licenseText = filteredLicense(licenseFilePath);

    licenseFilePath = licenseFilePath.length >= 2 && licenseFilePath.startsWith("./")
      ? licenseFilePath[2..$] : licenseFilePath;
    auto moduleDir = licenseFilePath.dirName();
    moduleDir = moduleDir.empty || moduleDir == "." ? "./" : moduleDir;
    return ParsedThirdPartyModule(ThirdPartyModuleInfo(
        moduleDir,
        licenseFilePath,
        licenseText.hexDigest!SHA1()[0..16].dup),
      licenseText);
  }()).array;
}

struct InfoFileParts {
  string before;
  ThirdPartyModuleInfo[] info;
  string after;
}

struct UpdateResult {
  InfoFileParts fileParts;
  string[] changes;
}
UpdateResult updateThirdPartyModuleInfos(InfoFileParts oldFileParts, ThirdPartyModuleInfo[] newInfos) {
  UpdateResult result;
  result.fileParts = oldFileParts;
  result.fileParts.info = [];

  auto newModulesByPath = newInfos.map!(info => tuple(info.path, info)).assocArray;
  foreach(oldModule; oldFileParts.info.sort!((a, b) => a.path < b.path)) {
    auto pNewModuleInfo = oldModule.path in newModulesByPath;
    if(!pNewModuleInfo) {
      result.changes ~= oldModule.path ~ " (removed)";
      writeln("Removed module: ", oldModule.path);
      continue;
    }

    newModulesByPath.remove(oldModule.path);

    ThirdPartyModuleInfo moduleInfo = oldModule;
    if(moduleInfo.hash != pNewModuleInfo.hash) {
        result.changes ~= moduleInfo.path ~ " (license changed)";
        writeln("Module changed license: ", moduleInfo.path);
    }

    moduleInfo.text = updateText(moduleInfo.text, *pNewModuleInfo);
    result.fileParts.info ~= moduleInfo;
  }

  foreach(newModule; newModulesByPath.values) {
    result.changes ~= newModule.path ~ " (added)";
    writeln("New module: ", newModule.path);

    newModule.text = updateText(kDefaultText, newModule);
    result.fileParts.info ~= newModule;
  }

  return result;
}

string updateText(string oldText, const ref ThirdPartyModuleInfo info) {
  return oldText.split('\n').map!(line => {
      auto licenseStartIdx = line.indexOf(kBeginLicense);
      if(licenseStartIdx >= 0) {
        auto endIdx = line.indexOf(kTriggerEnd);
        line = line[0..licenseStartIdx+kBeginLicense.length]
          ~ "path=%s hash=%s".format(info.path, info.hash)
          ~ line[endIdx..$];
        return line;
      }

      auto licensePathIdx = line.indexOf(kLicensePath);
      if(licensePathIdx >= 0) {
        auto wordOffset = licensePathIdx+kLicensePath.length;
        auto licensePathEnd = line[min(line.length, wordOffset+2) .. $].indexOf('`');
        if(licensePathEnd >= 0)
          return line[0..wordOffset]
            ~ " `%s`".format(info.licenseFilePath)
            ~ line[wordOffset + 2 + licensePathEnd+1..$];
        else
          return line[0..wordOffset] ~ " `%s`".format(info.licenseFilePath);
      }

      return line;
    }()).filter!(line => !line.empty).join("\n");
}

InfoFileParts readInfoFile(string infoFilePath) {
  InfoFileParts fileParts;

  auto lines = File(infoFilePath).byLine();

  auto textBeforeLicenses = appender!string;
  foreach (line; lines.until!(line => line.strip() == kBeginLicenses)) {
    textBeforeLicenses ~= line;
    textBeforeLicenses ~= '\n';
  }
  fileParts.before = textBeforeLicenses[].chomp();

  bool inLicense = false;
  ThirdPartyModuleInfo moduleInfo;
  foreach (line; lines.drop(1).until!(line => line.strip() == kEndLicenses)) {
    auto licenseStartIdx = line.indexOf(kBeginLicense);
    if(licenseStartIdx >= 0) {
      auto endIdx = line.indexOf(kTriggerEnd);
      if(endIdx > licenseStartIdx) {
        if(inLicense && !moduleInfo.hash.empty && !moduleInfo.path.empty)
          fileParts.info ~= moduleInfo;
        inLicense = true;

        moduleInfo = ThirdPartyModuleInfo();

        auto words = line[licenseStartIdx+kBeginLicense.length .. endIdx].split().map!(w => w.split('=')).join().array;
        if(words.length == 4 && words[0] == "path" && words[2] == "hash") {
          moduleInfo.path = words[1].dup;
          moduleInfo.hash = words[3].dup;
        }
      }
    }

    moduleInfo.text ~= line ~ "\n";
  }
  if(inLicense && !moduleInfo.hash.empty && !moduleInfo.path.empty)
    fileParts.info ~= moduleInfo;

  auto textAfterLicenses = appender!string;
  foreach (line; lines.drop(1)) {
    textAfterLicenses ~= line;
    textBeforeLicenses ~= '\n';
  }
  fileParts.after = textAfterLicenses[].chomp();

  return fileParts;
}

void writeInfoFile(File file, const ref InfoFileParts fileParts) {
  if(!fileParts.before.empty)
    file.writeln(fileParts.before);
  file.writeln(kBeginLicenses);

  foreach(info; fileParts.info) {
    file.writeln(info.text);
  }

  file.writeln(kEndLicenses);
  if(!fileParts.after.empty)
    file.writeln(fileParts.after);
}

// Create fixup/squash commits for the given files, or whatever is staged or
// modified, by blaming the base commit(s) of the lines being changed. Single
// file because `gorun` (invoked from the "af" git alias in gitconfig) only
// compiles the one file it's given.
package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// ── CLI entry point ─────────────────────────────────────────────────────────

const (
	branchFileName     = ".config/v1/git_named_branches"
	programName        = "auto-fixup"
	gitCmd             = "git"
	programDescription = `Automatically create fixup commits for the given selection of files, or
what's currently staged or what's currently modified. A base commit to
create a fixup for is the commit that last touched a line that the fixup
will change or remove.

A fixup is only created if the base commit is unique.
Also, the fixup is not created if the base commit is already on
origin/master or a named branch from ~/.config/v1/git_named_branches,
because this implies that the base commit is already on an append-only
upstream branch.

Options:`
)

type Parameters struct {
	force      bool
	dryRun     bool
	squash     bool
	verbose    bool
	helpWanted bool
	chunked    bool
}

type FileInfo struct {
	files     []string
	useStaged bool
}

type CommitHashAndTitle struct {
	hash  string
	time  int64
	title string
}

func main() {
	parms := Parameters{}
	var positionalArgs []string
	var parseError bool

	for i := 1; i < len(os.Args); i++ {
		arg := os.Args[i]

		if arg == "--" {
			positionalArgs = append(positionalArgs, os.Args[i+1:]...)
			break
		} else if arg == "--help" || arg == "-h" {
			parms.helpWanted = true
		} else if arg == "--force" || arg == "-f" {
			parms.force = true
		} else if arg == "--dry-run" || arg == "-n" {
			parms.dryRun = true
		} else if arg == "--squash" || arg == "-s" {
			parms.squash = true
		} else if arg == "--verbose" || arg == "-v" {
			parms.verbose = true
		} else if arg == "--chunked" || arg == "-c" {
			parms.chunked = true
		} else if strings.HasPrefix(arg, "-") && arg != "-" {
			for j := 1; j < len(arg); j++ {
				switch arg[j] {
				case 'h':
					parms.helpWanted = true
				case 'f':
					parms.force = true
				case 'n':
					parms.dryRun = true
				case 's':
					parms.squash = true
				case 'v':
					parms.verbose = true
				case 'c':
					parms.chunked = true
				default:
					fmt.Fprintf(os.Stderr, "Unknown option: -%c\n", arg[j])
					parseError = true
				}
			}
		} else {
			positionalArgs = append(positionalArgs, arg)
		}
	}

	if parseError {
		os.Exit(1)
	}

	if parms.helpWanted {
		fmt.Printf("Usage: %s [-%s] [files...]\n", programName, "cfnsv")
		fmt.Println(programDescription)
		fmt.Println("  -c, --chunked       Fix up hunk by hunk; leave ambiguous hunks alone")
		fmt.Println("  -f, --force         Create fixup even though base commit is on a named branch")
		fmt.Println("  -n, --dry-run       Only determine base commit, don't create fixup")
		fmt.Println("  -s, --squash        Create squash instead of fixup")
		fmt.Println("  -v, --verbose       Babble about what I'm doing")
		fmt.Println("  -h, --help          Show this help message")
		os.Exit(0)
	}

	fileInfo := filesToCommit(parms, positionalArgs)
	if len(fileInfo.files) == 0 {
		fmt.Println("No files changed. Nothing to fix up.")
		os.Exit(0)
	}

	if parms.chunked {
		os.Exit(runChunked(parms, fileInfo))
	}

	removedLines := removedLinesInFiles(parms, fileInfo)
	if len(removedLines) == 0 {
		fmt.Fprintln(os.Stderr, "No lines removed. Cannot fix up.")
		os.Exit(1)
	}

	previousCommits := commitsPreviouslyModifyingChangedLinesIn(parms, removedLines)
	baseCommits := baseCommitsFromFixupAndSquashes(parms, previousCommits)

	if len(baseCommits) > 1 {
		fmt.Fprint(os.Stderr, "Not fixing up. Found multiple base commits:\n")
		for _, c := range baseCommits {
			fmt.Fprintf(os.Stderr, "  %s %s\n", c.hash, c.title)
		}
		os.Exit(1)
	}

	if !isBaseCommitAfterNamedBranches(parms, baseCommits[0].hash) {
		if parms.force {
			fmt.Println("Warning: Fixing up commit that is on a named branch.")
		} else {
			fmt.Fprintln(os.Stderr, "Not fixing up. Base commit is on a named branch.")
			os.Exit(1)
		}
	}

	exitCode := createFixup(parms, fileInfo, baseCommits)
	os.Exit(exitCode)
}

// ── Git plumbing ─────────────────────────────────────────────────────────────

// Run git and return its output split into lines. Callers that can
// meaningfully react to a git failure (leaving no dangling index surgery,
// printing a targeted message) should check the error; callers that have
// nothing better to do than die should use mustGit instead.
func executeGitCmd(args []string) ([]string, error) {
	cmd := exec.Command(gitCmd, args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("git command \"%s %s\" failed: \n%s", gitCmd, strings.Join(args, " "), string(output))
	}
	return lineSplitter(string(output)), nil
}

// Run git and exit the process on failure. Reserved for call sites that have
// no cleanup to do and nothing useful to say beyond git's own error.
func mustGit(args []string) []string {
	result, err := executeGitCmd(args)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	return result
}

func executeGitCmdWithStdin(args []string, stdin string) ([]string, error) {
	cmd := exec.Command(gitCmd, args...)
	cmd.Stdin = strings.NewReader(stdin)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("git command \"%s %s\" failed: \n%s", gitCmd, strings.Join(args, " "), string(output))
	}
	return lineSplitter(string(output)), nil
}

func lineSplitter(s string) []string {
	if s == "" {
		return []string{}
	}
	lines := strings.Split(s, "\n")
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	return lines
}

// ── Selecting files ──────────────────────────────────────────────────────────

func filesToCommit(parms Parameters, args []string) FileInfo {
	fileInfo := FileInfo{}

	if len(args) > 0 {
		prefix := os.Getenv("GIT_PREFIX")
		if prefix == "" {
			fileInfo.files = args
		} else {
			for _, path := range args {
				if filepath.IsAbs(path) {
					fileInfo.files = append(fileInfo.files, path)
				} else {
					fileInfo.files = append(fileInfo.files, filepath.Join(prefix, path))
				}
			}
		}
	} else {
		lines := mustGit([]string{"status", "--porcelain"})
		var staged []string
		var modified []string

		for _, line := range lines {
			if len(line) < 3 {
				continue
			}

			if line[0] == 'R' || line[1] == 'R' {
				parts := strings.Split(line, " -> ")
				line = parts[0]
			}

			if line[0] == 'D' || line[0] == 'M' || line[0] == 'R' {
				staged = append(staged, line[3:])
			} else if line[1] == 'D' || line[1] == 'M' || line[1] == 'R' {
				modified = append(modified, line[3:])
			}
		}

		if len(staged) > 0 {
			fileInfo.files = staged
			fileInfo.useStaged = true
		} else if len(modified) > 0 {
			fileInfo.files = modified
		}
	}

	if parms.verbose && len(fileInfo.files) > 0 {
		if fileInfo.useStaged {
			fmt.Printf("Staged files to investigate: \n  %s\n", strings.Join(fileInfo.files, " "))
		} else {
			fmt.Printf("Modified files to investigate: \n  %s\n", strings.Join(fileInfo.files, " "))
		}
	}

	return fileInfo
}

// ── Diff parsing (shared by both modes) ──────────────────────────────────────
//
// Chunked mode works on the hunks themselves; plain mode projects them down
// to per-file removed-line runs with removedRunsByFile. Keeping one parser is
// what stops the two modes from disagreeing about what a diff says.

const (
	hunkKindNormal = iota
	hunkKindWholeFile
	hunkKindModeChange
	// A file whose diff carries no @@ hunk at all (binary, in practice):
	// never fixable, but still counted as left over so the exit code is honest.
	hunkKindUnsupported
)

// LinePair is a half-open line range [beginLine, endLine) on the pre-image side.
type LinePair struct {
	beginLine int
	endLine   int
}

// ChangedFile is plain mode's view of one file: either every removed-line run
// in it (kind == hunkKindNormal, the common case), or -- for a rename or a
// mode change with nothing else to blame -- a marker that the whole file
// needs blaming as one unit (kind == hunkKindWholeFile / hunkKindModeChange,
// removedRuns unused).
type ChangedFile struct {
	filename    string
	kind        int
	removedRuns []LinePair
}

// DiffHunk is one `@@ ... @@` block, or -- for kind != hunkKindNormal -- a
// stand-in for a file-level change that has no hunk to split.
type DiffHunk struct {
	file string
	kind int

	// header holds the file-level lines ("diff --git ...", "index ...",
	// "--- a/...", "+++ b/...", rename/mode lines) shared by every real hunk
	// of this file. Only meaningful for kind == hunkKindNormal.
	header []string
	// atLine is the "@@ -a,b +c,d @@ ..." line verbatim.
	atLine string
	// body holds the hunk's content lines verbatim, in order, including
	// "\ No newline at end of file" markers.
	body []string

	// preBegin/preEnd are the diff hunk's line numbers on the pre-image
	// side (from the @@ header), used only for the "Skipping hunk" message.
	preBegin int
	preEnd   int

	// removedRuns are the maximal runs of consecutive removed lines inside
	// this hunk. Unused for pseudo-hunks (kind != hunkKindNormal): kind alone
	// says how to blame them.
	removedRuns []LinePair

	// binary only distinguishes the two hunkKindUnsupported wordings.
	binary bool
}

func diffOutput(fileInfo FileInfo) []string {
	args := []string{"diff", "-p"}
	if fileInfo.useStaged {
		args = append(args, "--staged")
	} else {
		args = append(args, "HEAD", "--")
		args = append(args, fileInfo.files...)
	}
	return mustGit(args)
}

// Split `git diff -p` output into individual hunks, keeping file headers and
// hunk bodies verbatim so a subset of them can be reassembled into a valid
// patch.
func parseDiffHunks(parms Parameters, lines []string) []*DiffHunk {
	var allHunks []*DiffHunk
	var fileHeader []string
	var currentFile string
	var currentHunk *DiffHunk
	var currentLine int
	var renamed, modeChanged, binaryFile bool
	// sawHunk: any hunk at all was emitted for this file.
	// sawRemovedRun: one of them removed lines, so blame has something to go on
	// and no file-level stand-in is needed.
	var sawHunk, sawRemovedRun bool
	var runBegin, runEnd int

	type submoduleState struct {
		linesAdded      int
		linesRemoved    int
		linesUnmodified int
	}
	var subState submoduleState

	flushRun := func() {
		if currentHunk != nil && runBegin > 0 {
			currentHunk.removedRuns = append(currentHunk.removedRuns, LinePair{runBegin, runEnd})
			runBegin = 0
		}
	}

	closeHunk := func() {
		if subState.linesAdded == 1 && subState.linesRemoved == 1 && subState.linesUnmodified == 0 {
			if parms.verbose {
				fmt.Printf("Ignoring modified submodule: %s\n", currentFile)
			}
			subState = submoduleState{}
		}
		flushRun()
		if currentHunk != nil {
			allHunks = append(allHunks, currentHunk)
			sawHunk = true
			if len(currentHunk.removedRuns) > 0 {
				sawRemovedRun = true
			}
			currentHunk = nil
		}
	}

	// A rename or a permission change removes no line, so it gets a stand-in
	// hunk -- but only when nothing else in the file gives blame a foothold.
	createRenameHunk := func() {
		if renamed && !sawRemovedRun {
			allHunks = append(allHunks, &DiffHunk{file: currentFile, kind: hunkKindWholeFile})
			sawHunk, sawRemovedRun = true, true
		}
		renamed = false
	}

	createModeHunk := func() {
		if modeChanged && !sawRemovedRun {
			allHunks = append(allHunks, &DiffHunk{file: currentFile, kind: hunkKindModeChange})
			sawHunk, sawRemovedRun = true, true
		}
		modeChanged = false
	}

	// Record files that produced no hunk, so a binary change in scope is
	// reported as a leftover instead of vanishing into a successful exit.
	createUnsupportedHunk := func() {
		if currentFile != "" && !sawHunk {
			allHunks = append(allHunks, &DiffHunk{
				file: currentFile, kind: hunkKindUnsupported, binary: binaryFile,
			})
			sawHunk = true
		}
	}

	closeFile := func() {
		closeHunk()
		createRenameHunk()
		createModeHunk()
		createUnsupportedHunk()
	}

	startNewFile := func(name string) {
		currentFile = name
		fileHeader = nil
		subState = submoduleState{}
		renamed = false
		modeChanged = false
		binaryFile = false
		sawHunk = false
		sawRemovedRun = false
	}

	for _, line := range lines {
		switch {
		case strings.HasPrefix(line, "diff --git a/"):
			closeFile()

			_, afterA, _ := strings.Cut(line, " a/")
			_, afterB, _ := strings.Cut(afterA, " b/")
			startNewFile(afterB)
			fileHeader = append(fileHeader, line)

		case strings.HasPrefix(line, "@@"):
			closeHunk()

			_, afterDash, _ := strings.Cut(line, "-")
			startStr := afterDash
			if idx := strings.IndexAny(afterDash, ", "); idx >= 0 {
				startStr = afterDash[:idx]
			}
			currentLine = atoi(startStr)

			preBegin := currentLine
			count := 1
			if commaIdx := strings.Index(afterDash, ","); commaIdx >= 0 {
				rest := afterDash[commaIdx+1:]
				if spIdx := strings.IndexByte(rest, ' '); spIdx >= 0 {
					rest = rest[:spIdx]
				}
				count = atoi(rest)
			}

			currentHunk = &DiffHunk{
				file: currentFile, kind: hunkKindNormal,
				header:   append([]string{}, fileHeader...),
				atLine:   line,
				preBegin: preBegin, preEnd: preBegin + count - 1,
			}
			runBegin = 0

		// Keep every pre-@@ line, not just the recognised shapes: a deletion
		// patch stripped of "deleted file mode"/"+++ /dev/null" makes git apply
		// bail with "header lacks filename information". Keying on position
		// rather than shape also spares content that merely looks like a
		// header -- removing "-- foo" prints as "--- foo".
		case currentHunk == nil:
			switch {
			case strings.HasPrefix(line, "rename "):
				renamed = true
			case strings.HasPrefix(line, "old mode "):
				modeChanged = true
			case strings.HasPrefix(line, "Binary files ") || strings.HasPrefix(line, "GIT binary patch"):
				binaryFile = true
			}
			fileHeader = append(fileHeader, line)

		case strings.HasPrefix(line, "-Subproject commit "):
			subState.linesRemoved++
			currentLine++
			currentHunk.body = append(currentHunk.body, line)

		case strings.HasPrefix(line, "+Subproject commit "):
			subState.linesAdded++
			currentHunk.body = append(currentHunk.body, line)

		case strings.HasPrefix(line, "-"):
			if runBegin == 0 {
				runBegin = currentLine
			}
			runEnd = currentLine + 1
			currentLine++
			currentHunk.body = append(currentHunk.body, line)

		case strings.HasPrefix(line, "+"):
			currentHunk.body = append(currentHunk.body, line)

		case strings.HasPrefix(line, " "):
			flushRun()
			currentLine++
			subState.linesUnmodified++
			currentHunk.body = append(currentHunk.body, line)

		default:
			if parms.verbose {
				fmt.Printf("In git diff output for %s, ignoring unrecognised line: %s\n", currentFile, line)
			}
			flushRun()
			currentHunk.body = append(currentHunk.body, line)
		}
	}
	closeFile()

	return allHunks
}

// Collapse hunks into plain mode's per-file view, in the order the files
// appear in the diff. A file whose hunks removed nothing is dropped: there is
// nothing for blame to attribute. A file whose only hunk is a rename/mode-
// change pseudo-hunk becomes a single whole-file/mode-change marker instead
// of a removed-line run list.
func removedRunsByFile(hunks []*DiffHunk) []ChangedFile {
	var order []string
	byFile := map[string]*ChangedFile{}

	for _, h := range hunks {
		if h.kind != hunkKindNormal {
			if _, exists := byFile[h.file]; !exists {
				order = append(order, h.file)
			}
			byFile[h.file] = &ChangedFile{filename: h.file, kind: h.kind}
			continue
		}
		if len(h.removedRuns) == 0 {
			continue
		}
		cf, exists := byFile[h.file]
		if !exists {
			cf = &ChangedFile{filename: h.file, kind: hunkKindNormal}
			byFile[h.file] = cf
			order = append(order, h.file)
		}
		cf.removedRuns = append(cf.removedRuns, h.removedRuns...)
	}

	result := make([]ChangedFile, 0, len(order))
	for _, file := range order {
		result = append(result, *byFile[file])
	}
	return result
}

// ── Blame & attribution (shared by both modes) ───────────────────────────────

var blameHashLineRegex = regexp.MustCompile("^([0-9a-f]+) [0-9]+ [0-9]+")

// Walk the porcelain lines of one `git blame --porcelain` invocation --
// which may cover several `-L` ranges back to back -- and return the commit
// hash attributed to each blamed line, in the order the lines were blamed,
// plus each mentioned commit's time and title. Shared by the plain and
// chunked attribution paths so there is exactly one porcelain parser.
func parseBlameEntries(lines []string) (hashSeq []string, info map[string]CommitHashAndTitle) {
	info = map[string]CommitHashAndTitle{}
	var hash string

	for _, line := range lines {
		matches := blameHashLineRegex.FindStringSubmatch(line)
		if len(matches) > 1 {
			hash = matches[1]
			hashSeq = append(hashSeq, hash)
			if _, exists := info[hash]; !exists {
				info[hash] = CommitHashAndTitle{hash: hash}
			}
		} else if strings.HasPrefix(line, "author-time ") {
			c := info[hash]
			c.time = atoi64(line[12:])
			info[hash] = c
		} else if strings.HasPrefix(line, "summary ") {
			c := info[hash]
			c.title = line[8:]
			info[hash] = c
		}
	}

	return hashSeq, info
}

func parseBlameOutput(lines []string) []CommitHashAndTitle {
	hashSeq, info := parseBlameEntries(lines)
	result := make([]CommitHashAndTitle, 0, len(hashSeq))
	seen := map[string]bool{}
	for _, hash := range hashSeq {
		if !seen[hash] {
			seen[hash] = true
			result = append(result, info[hash])
		}
	}
	return result
}

// Run one `git blame --porcelain` covering every given line range of file,
// in one invocation, then split the combined output back into one candidate
// list per range (in the order the ranges were given) -- the same
// attribution `-L a,b -L c,d ...` in separate invocations would produce,
// since ranges of one file don't interact in blame's output.
func blameRanges(ranges []LinePair, file string) [][]CommitHashAndTitle {
	if len(ranges) == 0 {
		return nil
	}

	args := []string{"blame", "--porcelain"}
	for _, r := range ranges {
		args = append(args, "-L", fmt.Sprintf("%d,%d", r.beginLine, r.endLine-1))
	}
	args = append(args, "HEAD", "--", file)

	hashSeq, info := parseBlameEntries(mustGit(args))

	result := make([][]CommitHashAndTitle, len(ranges))
	pos := 0
	for i, r := range ranges {
		n := r.endLine - r.beginLine
		end := pos + n
		if end > len(hashSeq) {
			end = len(hashSeq)
		}
		seen := map[string]bool{}
		for _, hash := range hashSeq[pos:end] {
			if !seen[hash] {
				seen[hash] = true
				result[i] = append(result[i], info[hash])
			}
		}
		pos = end
	}
	return result
}

func commitInfo(hash string) (int64, string) {
	lines := mustGit([]string{"log", "-1", "--format=%at%n%s", hash})
	var time int64
	var title string
	if len(lines) >= 1 {
		time = atoi64(lines[0])
	}
	if len(lines) >= 2 {
		title = lines[1]
	}
	return time, title
}

func lastModeChangeCommit(filename string) string {
	lines := mustGit([]string{"log", "--format=%H", "--raw", "--", filename})
	currentHash := ""
	for _, line := range lines {
		if strings.HasPrefix(line, ":") {
			fields := strings.Fields(line)
			if len(fields) >= 2 {
				oldMode := strings.TrimPrefix(fields[0], ":")
				newMode := fields[1]
				if oldMode != newMode {
					return currentHash
				}
			}
		} else if isFullHash(line) {
			currentHash = line
		}
	}
	return currentHash
}

func isFullHash(s string) bool {
	if len(s) != 40 {
		return false
	}
	for _, ch := range s {
		if !((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f')) {
			return false
		}
	}
	return true
}

func baseCommitsFromFixupAndSquashes(parms Parameters, potentialBaseCommits []CommitHashAndTitle) []CommitHashAndTitle {
	baseCommits := []CommitHashAndTitle{}

	for _, commit := range potentialBaseCommits {
		title := commit.title
		for strings.HasPrefix(title, "fixup! ") || strings.HasPrefix(title, "squash! ") {
			idx := strings.Index(title, " ")
			if idx >= 0 {
				title = title[idx+1:]
			} else {
				break
			}
		}
		baseCommits = append(baseCommits, CommitHashAndTitle{commit.hash, commit.time, title})
	}

	sort.SliceStable(baseCommits, func(i, j int) bool {
		if baseCommits[i].title != baseCommits[j].title {
			return baseCommits[i].title < baseCommits[j].title
		}
		return baseCommits[i].time < baseCommits[j].time
	})

	uniqCommits := []CommitHashAndTitle{}
	var lastTitle string
	for _, c := range baseCommits {
		if c.title != lastTitle {
			uniqCommits = append(uniqCommits, c)
			lastTitle = c.title
		}
	}

	sort.SliceStable(uniqCommits, func(i, j int) bool {
		return uniqCommits[i].time < uniqCommits[j].time
	})

	return uniqCommits
}

// namedBranchesCache and baseCommitVerdictCache memoize named-branch lookups
// across an entire run: chunked mode reclassifies every not-yet-attributed
// hunk each round, which otherwise means re-reading the branches file and
// re-running rev-list for the same base commit over and over (O(H^2) git
// invocations for H hunks). Safe as bare package vars: the process is
// single-threaded and short-lived, and HEAD's set of named branches cannot
// change mid-run.
var (
	namedBranchesCache []string
	namedBranchesRead  bool

	baseCommitVerdictCache = map[string]bool{}
)

func namedBranches(parms Parameters) []string {
	if namedBranchesRead {
		return namedBranchesCache
	}
	namedBranchesRead = true

	branches := []string{"origin/master"}

	home := os.Getenv("HOME")
	basesFilePath := filepath.Join(home, branchFileName)

	file, err := os.Open(basesFilePath)
	if err != nil {
		if parms.verbose {
			fmt.Printf("Unable to open %s\n", basesFilePath)
		}
	} else {
		defer file.Close()
		scanner := bufio.NewScanner(file)
		for scanner.Scan() {
			line := strings.TrimSpace(scanner.Text())
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			fields := strings.Fields(line)
			for _, field := range fields {
				branches = append(branches, strings.TrimSpace(field))
			}
		}
	}

	if parms.verbose {
		fmt.Printf("Named branches to check against: %s\n", strings.Join(branches, " "))
	}

	namedBranchesCache = branches
	return branches
}

func isBaseCommitAfterNamedBranches(parms Parameters, baseCommitHash string) bool {
	if verdict, ok := baseCommitVerdictCache[baseCommitHash]; ok {
		return verdict
	}

	args := []string{"rev-list", "--ignore-missing", "--parents", "--reverse", baseCommitHash}
	for _, branch := range namedBranches(parms) {
		args = append(args, "^"+branch)
	}

	verdict := len(mustGit(args)) > 0
	baseCommitVerdictCache[baseCommitHash] = verdict
	return verdict
}

// ── Creating the fixup commit (shared by both modes) ─────────────────────────

// Resolve hash to its short form.
func gitRevParseShort(hash string) (string, error) {
	lines, err := executeGitCmd([]string{"rev-parse", "--short", hash})
	if err != nil {
		return "", err
	}
	if len(lines) == 0 {
		return "", fmt.Errorf("git rev-parse --short %s produced no output", hash)
	}
	return lines[0], nil
}

// Pull the new commit's hash out of the "[branch hash] title" line
// `git commit` prints to stdout on success.
func extractBracketedHash(commitOutput []string) (string, error) {
	var hashLines []string
	for _, line := range commitOutput {
		if strings.HasPrefix(line, "[") {
			hashLines = append(hashLines, line)
		}
	}
	if len(hashLines) != 1 {
		return "", fmt.Errorf("unexpected output from git commit: %s", strings.Join(commitOutput, "\n"))
	}
	_, afterSpace, _ := strings.Cut(hashLines[0], " ")
	fixupHash, _, _ := strings.Cut(afterSpace, "]")
	return fixupHash, nil
}

// Create one fixup/squash commit for base, either from the index (pathArgs
// == nil, used by chunked mode and staged-scope plain mode) or path-limited
// (pathArgs given, working-tree-scope plain mode). Return the new commit's
// short hash and the "<short>: <title>" string used in the user-facing
// messages.
func createFixupCommit(parms Parameters, base CommitHashAndTitle, pathArgs []string) (fixupHash string, baseCommitString string, err error) {
	shortHash, err := gitRevParseShort(base.hash)
	if err != nil {
		return "", "", err
	}
	baseCommitString = fmt.Sprintf("%s: %s", shortHash, base.title)

	commitType := "fixup"
	if parms.squash {
		commitType = "squash"
	}
	args := append([]string{"commit", fmt.Sprintf("--%s=%s", commitType, base.hash)}, pathArgs...)

	result, err := executeGitCmd(args)
	if err != nil {
		return "", baseCommitString, err
	}

	fixupHash, err = extractBracketedHash(result)
	return fixupHash, baseCommitString, err
}

// ── Plain mode ────────────────────────────────────────────────────────────────

func removedLinesInFiles(parms Parameters, fileInfo FileInfo) []ChangedFile {
	result := removedRunsByFile(parseDiffHunks(parms, diffOutput(fileInfo)))

	if parms.verbose {
		fmt.Println("Removed hunks:")
		for _, file := range result {
			var hunkStrs []string
			switch file.kind {
			case hunkKindWholeFile:
				hunkStrs = []string{"(whole file)"}
			case hunkKindModeChange:
				hunkStrs = []string{"(mode change)"}
			default:
				for _, run := range file.removedRuns {
					hunkStrs = append(hunkStrs, fmt.Sprintf("%d-%d", run.beginLine, run.endLine))
				}
			}
			fmt.Printf("  %s: %s\n", file.filename, strings.Join(hunkStrs, ", "))
		}
	}

	return result
}

func commitsPreviouslyModifyingChangedLinesIn(parms Parameters, files []ChangedFile) []CommitHashAndTitle {
	commitMap := make(map[string]CommitHashAndTitle)
	var commitOrder []string

	for _, file := range files {
		if file.kind == hunkKindModeChange {
			hash := lastModeChangeCommit(file.filename)
			if _, exists := commitMap[hash]; !exists {
				t, title := commitInfo(hash)
				commitMap[hash] = CommitHashAndTitle{hash: hash, time: t, title: title}
				commitOrder = append(commitOrder, hash)
			}
			continue
		}

		args := []string{"blame", "--porcelain"}
		if file.kind == hunkKindWholeFile {
			// A pure rename yields a whole-file hunk keyed on the new name, which
			// does not exist at HEAD; blame the working tree so git follows the
			// rename.
			args = append(args, "--", file.filename)
		} else {
			for _, run := range file.removedRuns {
				args = append(args, "-L", fmt.Sprintf("%d,%d", run.beginLine, run.endLine-1))
			}
			args = append(args, "HEAD", "--", file.filename)
		}

		hashSeq, info := parseBlameEntries(mustGit(args))
		for _, hash := range hashSeq {
			if _, exists := commitMap[hash]; !exists {
				commitMap[hash] = info[hash]
				commitOrder = append(commitOrder, hash)
			}
		}
	}

	commits := []CommitHashAndTitle{}
	for _, hash := range commitOrder {
		commits = append(commits, commitMap[hash])
	}

	if parms.verbose {
		fmt.Println("Base commit candidates:")
		for _, c := range commits {
			fmt.Printf("  %s %s\n", c.hash, c.title)
		}
	}

	return commits
}

func createFixup(parms Parameters, fileInfo FileInfo, baseCommits []CommitHashAndTitle) int {
	base := baseCommits[0]
	commitType := "fixup"
	if parms.squash {
		commitType = "squash"
	}

	if parms.dryRun {
		shortHash, err := gitRevParseShort(base.hash)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		fmt.Printf("Would create %s for base commit %s: %s\n", commitType, shortHash, base.title)
		return 0
	}

	var pathArgs []string
	if !fileInfo.useStaged {
		pathArgs = fileInfo.files
	}

	fixupHash, baseCommitString, err := createFixupCommit(parms, base, pathArgs)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}

	fmt.Printf("Created %s %s for base commit %s\n", commitType, fixupHash, baseCommitString)
	return 0
}

// ── Chunked mode (-c/--chunked) ───────────────────────────────────────────────
//
// Operate on individual diff hunks instead of treating the whole pending
// change as one atomic unit.

func runChunked(parms Parameters, fileInfo FileInfo) int {
	// Committing the index would sweep in whatever else is staged. A selected
	// file's own staged content is worse still: `git apply --cached` of a hunk
	// taken from the HEAD diff has nothing left to apply onto.
	if !fileInfo.useStaged {
		if dirty := stagedFiles(); len(dirty) > 0 {
			fmt.Fprintln(os.Stderr, "Not fixing up. Chunked mode commits from the index, but the index is not clean:")
			for _, f := range dirty {
				fmt.Fprintf(os.Stderr, "  %s\n", f)
			}
			fmt.Fprintln(os.Stderr, "Stage everything you want fixed up, or unstage these changes first.")
			return 1
		}
	}

	if parms.dryRun {
		return runChunkedDryRun(parms, fileInfo)
	}
	return runChunkedReal(parms, fileInfo)
}

func stagedFiles() []string {
	return mustGit([]string{"diff", "--staged", "--name-only"})
}

// hunkStatus is the verdict classifyCandidates reaches for one hunk: either
// hunkAttributable, or one of the reasons a hunk is left over.
type hunkStatus int

const (
	hunkAttributable hunkStatus = iota
	hunkNoLinesRemoved
	hunkMultipleBaseCommits
	hunkOnNamedBranch
	hunkUnsupportedDiff
	hunkFileLevelCannotSplit
)

// Give the text after "Skipping hunk <file>:<range>: " for every status but
// hunkAttributable, whose reason is "" by construction.
func (s hunkStatus) skipReason() string {
	switch s {
	case hunkNoLinesRemoved:
		return "no lines removed"
	case hunkMultipleBaseCommits:
		return "multiple base commits"
	case hunkOnNamedBranch:
		return "base commit is on a named branch"
	case hunkUnsupportedDiff:
		return "unsupported diff"
	case hunkFileLevelCannotSplit:
		return "file-level change cannot be split"
	default:
		return ""
	}
}

// hunkResult is the classification of one DiffHunk in one round.
type hunkResult struct {
	hunk   *DiffHunk
	status hunkStatus
	// candidates are the collapsed base-commit candidates classifyCandidates
	// weighed to reach status: empty for hunkNoLinesRemoved/hunkUnsupportedDiff,
	// several for hunkMultipleBaseCommits, exactly one otherwise -- and for
	// status == hunkAttributable, candidates[0] *is* the base commit. Kept
	// mainly for --verbose display; grouping logic goes through status.
	candidates []CommitHashAndTitle
	forced     bool // attributable only because of --force
	consumed   bool // dry-run bookkeeping only
}

// Turn h's blame candidates into the same verdict plain mode would reach:
// unattributable (with a status), or a unique base commit (possibly only
// usable via --force).
func classifyCandidates(parms Parameters, h *DiffHunk, blamed []CommitHashAndTitle) (status hunkStatus, candidates []CommitHashAndTitle, forced bool) {
	if h.kind == hunkKindUnsupported {
		return hunkUnsupportedDiff, nil, false
	}

	candidates = baseCommitsFromFixupAndSquashes(parms, blamed)

	if len(candidates) == 0 {
		return hunkNoLinesRemoved, candidates, false
	}
	if len(candidates) > 1 {
		return hunkMultipleBaseCommits, candidates, false
	}
	if !isBaseCommitAfterNamedBranches(parms, candidates[0].hash) {
		if parms.force {
			return hunkAttributable, candidates, true
		}
		return hunkOnNamedBranch, candidates, false
	}
	return hunkAttributable, candidates, false
}

// Blame the pseudo-hunks that stand in for a whole-file change (rename, mode
// change) and so cannot be split by -L range. hunkKindNormal hunks are
// blamed in a batch by blameNormalHunksByFile instead.
func blameFileLevelHunkCandidates(h *DiffHunk) []CommitHashAndTitle {
	switch h.kind {
	case hunkKindModeChange:
		hash := lastModeChangeCommit(h.file)
		t, title := commitInfo(hash)
		return []CommitHashAndTitle{{hash: hash, time: t, title: title}}
	case hunkKindWholeFile:
		// A pure rename yields a whole-file hunk keyed on the new name, which
		// does not exist at HEAD; blame the working tree so git follows the
		// rename, same as the non-chunked path.
		return parseBlameOutput(mustGit([]string{"blame", "--porcelain", "--", h.file}))
	default:
		return nil
	}
}

// Blame every hunkKindNormal hunk's removed-line runs, issuing exactly one
// `git blame` invocation per file regardless of how many hunks or
// removed-line runs that file has in this round.
func blameNormalHunksByFile(hunks []*DiffHunk) map[*DiffHunk][]CommitHashAndTitle {
	var fileOrder []string
	byFile := map[string][]*DiffHunk{}
	for _, h := range hunks {
		if h.kind != hunkKindNormal || len(h.removedRuns) == 0 {
			continue
		}
		if _, exists := byFile[h.file]; !exists {
			fileOrder = append(fileOrder, h.file)
		}
		byFile[h.file] = append(byFile[h.file], h)
	}

	result := map[*DiffHunk][]CommitHashAndTitle{}
	for _, file := range fileOrder {
		var ranges []LinePair
		var owners []*DiffHunk
		for _, h := range byFile[file] {
			for _, run := range h.removedRuns {
				ranges = append(ranges, run)
				owners = append(owners, h)
			}
		}

		for i, candidates := range blameRanges(ranges, file) {
			h := owners[i]
			seen := map[string]bool{}
			for _, c := range result[h] {
				seen[c.hash] = true
			}
			for _, c := range candidates {
				if !seen[c.hash] {
					seen[c.hash] = true
					result[h] = append(result[h], c)
				}
			}
		}
	}
	return result
}

func hunkRangeDisplay(h *DiffHunk) string {
	switch h.kind {
	case hunkKindWholeFile:
		return "(whole file)"
	case hunkKindModeChange:
		return "(mode change)"
	case hunkKindUnsupported:
		if h.binary {
			return "(binary)"
		}
		return "(no hunks)"
	default:
		return fmt.Sprintf("%d-%d", h.preBegin, h.preEnd)
	}
}

func printSkipHunk(h *DiffHunk, status hunkStatus) {
	fmt.Fprintf(os.Stderr, "Skipping hunk %s:%s: %s\n", h.file, hunkRangeDisplay(h), status.skipReason())
}

// Blame and classify every hunk of one round, printing verbose diagnostics
// if requested. Every hunkKindNormal hunk of a given file is blamed together
// in one `git blame` invocation (blameNormalHunksByFile); only the
// file-level pseudo-hunks (rename, mode change) still cost one invocation
// each, since they aren't -L-range-shaped.
func classifyAll(parms Parameters, hunks []*DiffHunk) []*hunkResult {
	if parms.verbose {
		fmt.Println("Diff hunks found:")
		for _, h := range hunks {
			fmt.Printf("  %s:%s\n", h.file, hunkRangeDisplay(h))
		}
	}
	hunksPerFile := map[string]int{}
	for _, h := range hunks {
		hunksPerFile[h.file]++
	}

	candidatesByHunk := blameNormalHunksByFile(hunks)

	results := make([]*hunkResult, 0, len(hunks))
	for _, h := range hunks {
		blamed := candidatesByHunk[h]
		if h.kind != hunkKindNormal {
			blamed = blameFileLevelHunkCandidates(h)
		}
		status, candidates, forced := classifyCandidates(parms, h, blamed)
		// A rename or permission change is staged with the whole file, which
		// would drag that file's other hunks into the fixup behind the user's
		// back. Leave it for a run where it stands alone.
		if status == hunkAttributable && h.kind != hunkKindNormal && hunksPerFile[h.file] > 1 {
			status, forced = hunkFileLevelCannotSplit, false
		}
		if parms.verbose {
			fmt.Printf("Base commit candidates for %s:%s:\n", h.file, hunkRangeDisplay(h))
			for _, c := range candidates {
				fmt.Printf("  %s %s\n", c.hash, c.title)
			}
		}
		results = append(results, &hunkResult{hunk: h, status: status, candidates: candidates, forced: forced})
	}
	return results
}

// Pick the attributable group (hunks sharing the same collapsed base commit)
// with the oldest base commit among the not-yet-consumed results. Return ok
// == false if no attributable hunk remains.
func oldestGroup(results []*hunkResult) (base CommitHashAndTitle, members []*hunkResult, ok bool) {
	groupBase := map[string]CommitHashAndTitle{}
	groupOrder := []string{}
	groupMembers := map[string][]*hunkResult{}

	for _, r := range results {
		if r.consumed || r.status != hunkAttributable {
			continue
		}
		hash := r.candidates[0].hash
		if _, exists := groupBase[hash]; !exists {
			groupOrder = append(groupOrder, hash)
			groupBase[hash] = r.candidates[0]
		}
		groupMembers[hash] = append(groupMembers[hash], r)
	}

	if len(groupOrder) == 0 {
		return CommitHashAndTitle{}, nil, false
	}

	oldestHash := groupOrder[0]
	for _, hash := range groupOrder[1:] {
		if groupBase[hash].time < groupBase[oldestHash].time {
			oldestHash = hash
		}
	}
	return groupBase[oldestHash], groupMembers[oldestHash], true
}

// Print plain mode's warning if --force is what let this fixup target a commit
// that is already on a named branch. Call once per fixup, next to its
// Created/Would-create line.
func warnIfForced(members []*hunkResult) {
	for _, m := range members {
		if m.forced {
			fmt.Println("Warning: Fixing up commit that is on a named branch.")
			return
		}
	}
}

func runChunkedReal(parms Parameters, fileInfo FileInfo) int {
	totalFixups := 0

	// Staged scope: `git diff --staged` already reflects the full pending
	// change in the index, so a round's selected-hunk patch cannot be
	// re-applied on top of it (the content is already there). Instead, each
	// round: reset the affected files back to HEAD, apply just the selected
	// hunks, commit, then restage the *original* fully-staged blob for those
	// files. Since the just-committed hunk's content is now common between
	// the new HEAD and that original blob, `git diff --staged` naturally
	// shows only the remaining (leftover) hunks, with no line-number
	// bookkeeping required and the working tree never touched.
	var originalIndex map[string]indexEntry
	if fileInfo.useStaged {
		originalIndex = captureOriginalIndex(fileInfo.files)
	}

	for {
		diffLines := diffOutput(fileInfo)
		if len(diffLines) == 0 {
			if totalFixups == 0 {
				fmt.Fprintln(os.Stderr, "No lines removed. Cannot fix up.")
				return 1
			}
			return 0
		}

		hunks := parseDiffHunks(parms, diffLines)
		results := classifyAll(parms, hunks)

		base, members, ok := oldestGroup(results)
		if !ok {
			leftover := 0
			for _, r := range results {
				printSkipHunk(r.hunk, r.status)
				leftover++
			}
			if leftover > 0 {
				fmt.Printf("Created %d fixup(s), %d hunk(s) left over.\n", totalFixups, leftover)
				return 1
			}
			return 0
		}

		selected := make([]*DiffHunk, 0, len(members))
		for _, m := range members {
			selected = append(selected, m.hunk)
		}
		warnIfForced(members)
		if err := commitChunkedGroup(parms, fileInfo.useStaged, originalIndex, base, selected); err != nil {
			fmt.Fprintln(os.Stderr, err)
			if totalFixups > 0 {
				fmt.Printf("Created %d fixup(s) before the failure.\n", totalFixups)
			}
			return 1
		}
		totalFixups++
	}
}

func runChunkedDryRun(parms Parameters, fileInfo FileInfo) int {
	diffLines := diffOutput(fileInfo)
	if len(diffLines) == 0 {
		fmt.Fprintln(os.Stderr, "No lines removed. Cannot fix up.")
		return 1
	}

	hunks := parseDiffHunks(parms, diffLines)
	results := classifyAll(parms, hunks)

	commitType := "fixup"
	if parms.squash {
		commitType = "squash"
	}

	totalFixups := 0
	for {
		base, members, ok := oldestGroup(results)
		if !ok {
			break
		}
		for _, m := range members {
			m.consumed = true
		}

		warnIfForced(members)
		shortHash, err := gitRevParseShort(base.hash)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		fmt.Printf("Would create %s for base commit %s: %s\n", commitType, shortHash, base.title)
		totalFixups++
	}

	leftover := 0
	for _, r := range results {
		if !r.consumed {
			printSkipHunk(r.hunk, r.status)
			leftover++
		}
	}
	if leftover > 0 {
		fmt.Printf("Created %d fixup(s), %d hunk(s) left over.\n", totalFixups, leftover)
		return 1
	}
	return 0
}

// indexEntry is one line of `git ls-files -s`: the index's current mode and
// blob for a path.
type indexEntry struct {
	mode string
	blob string
}

// Record the current (fully-staged) index entry for each file, before any
// of chunked mode's resets touch it.
func captureOriginalIndex(files []string) map[string]indexEntry {
	result := map[string]indexEntry{}
	if len(files) == 0 {
		return result
	}
	args := append([]string{"ls-files", "-s", "--"}, files...)
	for _, line := range mustGit(args) {
		tabIdx := strings.IndexByte(line, '\t')
		if tabIdx < 0 {
			continue
		}
		path := line[tabIdx+1:]
		fields := strings.Fields(line[:tabIdx])
		if len(fields) < 2 {
			continue
		}
		result[path] = indexEntry{mode: fields[0], blob: fields[1]}
	}
	return result
}

// Restore the given files' index entries to their originally-captured
// (fully-staged) blob, so that `git diff --staged` against the new HEAD
// shows exactly the not-yet-committed leftover hunks. The working tree is
// never touched. Return one error per file whose restore failed, rather
// than dying, since by the time this runs the index is already mid-surgery
// and the caller needs to say so, not just vanish.
func restageOriginalIndex(files []string, original map[string]indexEntry) []error {
	var errs []error
	for _, f := range files {
		entry, ok := original[f]
		if !ok {
			continue
		}
		if _, err := executeGitCmd([]string{"update-index", "--cacheinfo", fmt.Sprintf("%s,%s,%s", entry.mode, entry.blob, f)}); err != nil {
			errs = append(errs, err)
		}
	}
	return errs
}

// restageOriginalIndexOrWarn is restageOriginalIndex for callers that have no
// more recovery to attempt: it is the last thing standing between a failed
// round and a silently corrupted index, so a failure here has to be reported
// loudly instead of swallowed.
func restageOriginalIndexOrWarn(files []string, original map[string]indexEntry) {
	errs := restageOriginalIndex(files, original)
	if len(errs) == 0 {
		return
	}
	fmt.Fprintln(os.Stderr, "Failed to restore the index to its original staged state:")
	for _, err := range errs {
		fmt.Fprintf(os.Stderr, "  %s\n", err)
	}
	fmt.Fprintln(os.Stderr, "Recovery: check `git status` / `git diff --staged`; you may need to re-stage these files by hand.")
}

// Apply the selected hunks (which all attribute to base) to the index and
// create one fixup/squash commit from the index.
func commitChunkedGroup(parms Parameters, useStaged bool, originalIndex map[string]indexEntry, base CommitHashAndTitle, hunks []*DiffHunk) error {
	var realHunks []*DiffHunk
	var realFiles []string
	var pseudoFiles []string
	seenRealFile := map[string]bool{}
	seenPseudoFile := map[string]bool{}

	for _, h := range hunks {
		if h.kind == hunkKindNormal {
			realHunks = append(realHunks, h)
			if !seenRealFile[h.file] {
				seenRealFile[h.file] = true
				realFiles = append(realFiles, h.file)
			}
		} else if !seenPseudoFile[h.file] {
			seenPseudoFile[h.file] = true
			pseudoFiles = append(pseudoFiles, h.file)
		}
	}

	if useStaged && len(realFiles) > 0 {
		// For staged scope, `git diff --staged` already reflects the full
		// pending change, so reset the affected files to HEAD first (giving the
		// round's hunk patch something to apply on top of), then restage them
		// to their original fully-staged blob so any not-yet-selected hunks of
		// the same file stay staged for a later round. Run the restage via
		// defer so it always happens -- including when a later step in this
		// function fails and returns early -- instead of leaving the index
		// reset with nothing to say why.
		if _, err := executeGitCmd(append([]string{"reset", "HEAD", "--"}, realFiles...)); err != nil {
			return err
		}
		defer restageOriginalIndexOrWarn(realFiles, originalIndex)
	}
	if len(realHunks) > 0 {
		patch := buildChunkedPatch(realHunks)
		if _, err := executeGitCmdWithStdin([]string{"apply", "--cached"}, patch); err != nil {
			return err
		}
	}
	for _, f := range pseudoFiles {
		if _, err := executeGitCmd([]string{"add", "-A", "--", f}); err != nil {
			return err
		}
	}

	fixupHash, baseCommitString, err := createFixupCommit(parms, base, nil)
	if err != nil {
		return err
	}

	commitType := "fixup"
	if parms.squash {
		commitType = "squash"
	}
	fmt.Printf("Created %s %s for base commit %s\n", commitType, fixupHash, baseCommitString)
	return nil
}

// Reconstruct a patch containing only the given hunks: each distinct file's
// header block once, followed by that file's selected hunks (in encounter
// order), byte-for-byte.
func buildChunkedPatch(hunks []*DiffHunk) string {
	var order []string
	byFile := map[string][]*DiffHunk{}
	for _, h := range hunks {
		if _, exists := byFile[h.file]; !exists {
			order = append(order, h.file)
		}
		byFile[h.file] = append(byFile[h.file], h)
	}

	var sb strings.Builder
	for _, f := range order {
		hs := byFile[f]
		for _, line := range hs[0].header {
			sb.WriteString(line)
			sb.WriteString("\n")
		}
		for _, h := range hs {
			sb.WriteString(h.atLine)
			sb.WriteString("\n")
			for _, bl := range h.body {
				sb.WriteString(bl)
				sb.WriteString("\n")
			}
		}
	}
	return sb.String()
}

// ── Small parsing utilities ───────────────────────────────────────────────────

// atoi and atoi64 parse the leading digits of the git output they're called
// on (hunk header numbers, blame author-time, commit %at) -- always clean
// digit strings by construction, so a parse error can only mean git's output
// shape changed; 0 is as good a fallback as any in that case.
func atoi(s string) int {
	n, _ := strconv.Atoi(s)
	return n
}

func atoi64(s string) int64 {
	n, _ := strconv.ParseInt(s, 10, 64)
	return n
}

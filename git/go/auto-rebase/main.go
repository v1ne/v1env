// Rebase the current branch onto a suitable base commit; see programDescription
// below. Run via `gorun` (invoked from the "ar"/"ara" git aliases in
// gitconfig) rather than compiled.
package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

type Parameters struct {
	allFixups          bool
	autosquash         bool
	dryRun             bool
	smallBaseForFixups bool
	verbose            bool
}

type HashAndTitle struct {
	hash  string
	title string
}

const (
	branchFileName     = ".config/v1/git_named_branches"
	programName        = "auto-rebase"
	programDescription = `Rebase the current branch in a branch-develop-merge scenario

In a workflow that branches off origin/master, adds changes and merges them
back, the changes need to be reshuffled frequently. This reshuffling needs a
suitable base commit to rebase the current set of changes on.
That base commit is selected to be the latest of origin/master and
named commits from ~/.config/v1/git_named_branches. Dead branch names are ignored.

When selecting -f to cover all fixups from the base commit to HEAD, the base
commit can move back or forth. Thus, the new base commit can lay before or
beyond e.g. origin/master. This is useful to restrict the number of commits
shown in the rebase as well as when rewriting historic commits.

Options:`
	gitCmd = "git"
)

func main() {
	parms := Parameters{}
	var passthrough []string

	// getopt semantics: bundling + pass-through, with options permuted, so a flag
	// is still recognised even after a positional argument. Unknown options and
	// positionals are forwarded verbatim to the final "git rebase".
	endOfOptions := false
	for _, arg := range os.Args[1:] {
		switch {
		case endOfOptions:
			passthrough = append(passthrough, arg)
		case arg == "-h" || arg == "--help":
			printHelp()
			os.Exit(0)
		case arg == "--":
			endOfOptions = true
		case isKnownShortBundle(arg):
			for i := 1; i < len(arg); i++ {
				switch arg[i] {
				case 'a':
					parms.autosquash = true
				case 'f':
					parms.smallBaseForFixups = true
				case 'F':
					parms.allFixups = true
				case 'n':
					parms.dryRun = true
				case 'v':
					parms.verbose = true
				}
			}
		default:
			passthrough = append(passthrough, arg)
		}
	}

	var base string
	if parms.allFixups {
		base = baseForFixups(parms)
	} else {
		base = baseFromBranches(parms)
	}

	if base == "" {
		fmt.Println("Nothing to rebase. You're probably on the base commit.")
		os.Exit(0)
	}

	if parms.smallBaseForFixups {
		base = restrictBaseForFixups(parms, base)
		if base == "" {
			fmt.Println("No fixups found, no rebase needed.")
			os.Exit(0)
		}
	}

	exitCode := rebase(parms, passthrough, base)
	os.Exit(exitCode)
}

func isKnownShortBundle(arg string) bool {
	if len(arg) < 2 || arg[0] != '-' || arg[1] == '-' {
		return false
	}
	for i := 1; i < len(arg); i++ {
		switch arg[i] {
		case 'a', 'f', 'F', 'n', 'v':
		default:
			return false
		}
	}
	return true
}

func printHelp() {
	shortFlags := "aFfnv"
	fmt.Printf("Usage: %s [-%s] [files...]\n", programName, shortFlags)
	fmt.Println(programDescription)
	fmt.Println("  -a\tPass --autosquash to the final \"git rebase\" command")
	fmt.Println("  -f\tUse smallest base covering all fixups/squashes in base..HEAD")
	fmt.Println("  -F\tUse base covering all fixups in the entire history")
	fmt.Println("  -n\tDry run, only show base commit")
	fmt.Println("  -v\tBabble about what I'm doing")
	fmt.Println("  -h, --help\tShow this help message")
}

func executeGitCmd(args []string) []string {
	cmd := exec.Command(gitCmd, args...)
	output, err := cmd.CombinedOutput()

	if err != nil {
		os.Stdout.Sync()
		cmdStr := gitCmd + " " + strings.Join(args, " ")
		fmt.Fprintf(os.Stderr, "Git command \"%s\" failed: \n%s", cmdStr, string(output))
		os.Stderr.Sync()
		os.Exit(1)
	}

	lines := strings.Split(strings.TrimSuffix(string(output), "\n"), "\n")
	if len(lines) == 1 && lines[0] == "" {
		return []string{}
	}
	return lines
}

func revParse(rev string) string {
	lines := executeGitCmd([]string{"rev-parse", rev, "--"})
	if len(lines) > 0 {
		return lines[0]
	}
	return ""
}

func parentCommit(commit string) string {
	if commit == "" {
		return ""
	}
	return commit + "^"
}

func hashAndTitleFromGitCmd(args []string) []HashAndTitle {
	lines := executeGitCmd(args)
	result := []HashAndTitle{}

	for _, line := range lines {
		if line == "" {
			continue
		}
		sep := strings.Index(line, " ")
		if sep < 0 {
			continue
		}
		hash := line[:sep]
		title := line[sep+1:]
		result = append(result, HashAndTitle{hash, title})
	}

	return result
}

func toOriginalTitleToHashMap(hats []HashAndTitle) map[string]string {
	titleToHash := make(map[string]string)

	for _, hat := range hats {
		title := strings.TrimSpace(hat.title)

		for strings.HasPrefix(title, "fixup! ") || strings.HasPrefix(title, "squash! ") {
			sep := strings.Index(title, " ")
			if sep < 0 {
				break
			}
			title = strings.TrimLeft(title[sep+1:], " \t")
		}

		if len(title) >= 2 && title[0] == '"' && title[len(title)-1] == '"' {
			title = strings.TrimSpace(title[1 : len(title)-1])
		}

		titleToHash[title] = hat.hash
	}

	return titleToHash
}

func earliestMentionedTitle(start string, titlesToHashes map[string]string) string {
	if len(titlesToHashes) == 0 {
		return ""
	}

	lastHash := ""
	hats := hashAndTitleFromGitCmd([]string{"log", "--format=%H:%h %s"})

	for _, hat := range hats {
		parts := strings.Split(hat.hash, ":")
		if len(parts) < 2 {
			continue
		}
		fullHash := parts[0]
		abbrevHash := parts[1]

		lastHash = abbrevHash

		_, byTitle := titlesToHashes[hat.title]
		_, byFull := titlesToHashes[fullHash]
		_, byAbbrev := titlesToHashes[abbrevHash]
		if byTitle || byFull || byAbbrev {
			delete(titlesToHashes, hat.title)
			delete(titlesToHashes, fullHash)
			delete(titlesToHashes, abbrevHash)
		}

		if len(titlesToHashes) == 0 {
			break
		}
	}

	if len(titlesToHashes) > 0 {
		os.Stdout.Sync()
		fmt.Fprintf(os.Stderr, "Unable to resolve these fixups: \n")
		for title, hash := range titlesToHashes {
			fmt.Fprintf(os.Stderr, "  %s %s\n", hash, title)
		}
		os.Stderr.Sync()
		os.Exit(1)
	}

	return lastHash
}

func printHashesAndTitles(title string, hats []HashAndTitle) {
	fmt.Println(title)
	for _, hat := range hats {
		fmt.Println("  " + hat.title)
	}
}

func baseForFixups(parms Parameters) string {
	hats := hashAndTitleFromGitCmd([]string{"log", "--extended-regexp", "--grep=^fixup!|^squash!", "--format=%h %s"})

	var filtered []HashAndTitle
	for _, hat := range hats {
		if strings.HasPrefix(hat.title, "fixup!") || strings.HasPrefix(hat.title, "squash!") {
			filtered = append(filtered, hat)
		}
	}
	hats = filtered

	if parms.verbose {
		printHashesAndTitles("Found fixups/squashes:", hats)
	}

	titleToHash := toOriginalTitleToHashMap(hats)
	earliestReferencedCommitHash := earliestMentionedTitle("HEAD", titleToHash)

	if parms.verbose {
		fmt.Println("Earliest referenced commit: " + earliestReferencedCommitHash)
	}

	return parentCommit(earliestReferencedCommitHash)
}

func baseFromBranches(parms Parameters) string {
	possibleBases := []string{"origin/master"}

	home := os.Getenv("HOME")
	basesFilePath := filepath.Join(home, branchFileName)

	file, err := os.Open(basesFilePath)
	if err != nil {
		if parms.verbose {
			fmt.Println("Unable to open " + basesFilePath)
		}
	} else {
		defer file.Close()
		scanner := bufio.NewScanner(file)
		for scanner.Scan() {
			line := strings.TrimSpace(scanner.Text())
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}

			tokens := strings.Fields(line)
			for _, token := range tokens {
				token = strings.TrimSpace(token)
				if token != "" {
					possibleBases = append(possibleBases, token)
				}
			}
		}
	}

	if parms.verbose {
		fmt.Println("Possible bases: " + strings.Join(possibleBases, " "))
	}

	revListArgs := []string{"rev-list", "--ignore-missing", "--parents", "--reverse", "HEAD"}
	for _, base := range possibleBases {
		revListArgs = append(revListArgs, "^"+base)
	}

	lines := executeGitCmd(revListArgs)

	var commitSucceedingLatestBase string
	for _, line := range lines {
		// --parents lines are "hash parent...", so the root commit -- which
		// has no parent -- is the only one without a space; skip it.
		if strings.Contains(line, " ") {
			sep := strings.Index(line, " ")
			commitSucceedingLatestBase = line[:sep]
			break
		}
	}

	if parms.verbose {
		fmt.Println("Latest base: " + commitSucceedingLatestBase)
	}

	return parentCommit(commitSucceedingLatestBase)
}

func restrictBaseForFixups(parms Parameters, base string) string {
	hats := hashAndTitleFromGitCmd([]string{"log", "--extended-regexp", "--grep=^fixup!|^squash!", "--format=%H %s", base + "..HEAD"})

	var filtered []HashAndTitle
	for _, hat := range hats {
		if strings.HasPrefix(hat.title, "fixup!") || strings.HasPrefix(hat.title, "squash!") {
			filtered = append(filtered, hat)
		}
	}
	hats = filtered

	if parms.verbose {
		printHashesAndTitles("Fixups in range:", hats)
	}

	titleToHash := toOriginalTitleToHashMap(hats)
	earliestReferencedCommitHash := earliestMentionedTitle("HEAD", titleToHash)

	if parms.verbose {
		fmt.Println("Earliest referenced commit: " + earliestReferencedCommitHash)
	}

	return parentCommit(earliestReferencedCommitHash)
}

func rebase(parms Parameters, args []string, base string) int {
	if parms.dryRun || parms.verbose {
		fmt.Println("Base commit: " + revParse(base))
	}

	if parms.dryRun {
		return 1 // preserves the D script's dry-run exit code: `return true`, which is 1 as an int
	}

	os.Stdout.Sync()
	os.Stderr.Sync()

	rebaseArgs := []string{"rebase", "-i", base}
	if parms.autosquash {
		rebaseArgs = append(rebaseArgs, "--autosquash")
	}
	rebaseArgs = append(rebaseArgs, args...)

	cmd := exec.Command(gitCmd, rebaseArgs...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	err := cmd.Run()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			return exitErr.ExitCode()
		}
		return 1
	}

	return 0
}

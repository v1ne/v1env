#!/usr/bin/env python3
"""Tests for auto-fixup.d

Run with:  python3 -m pytest test_auto_fixup.py -v
       or: python3 -m unittest test_auto_fixup -v

Key behaviours documented by these tests:
  - Files with staged status 'A' (newly added) are NOT tracked; script reports "No files changed"
  - A single-line file changed to another single-line content produces a diff hunk with no
    comma in the @@ header ("@@ -1 +1 @@"), which the script's submodule-detection path
    skips. Tests use ≥2-line files to avoid this edge case.
  - git blame follows rename history, so pure renames and rename+modifications work correctly.
"""

import os
import shutil
import subprocess
import tempfile
import unittest

SCRIPT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'auto-fixup.d')


class AutoFixupBase(unittest.TestCase):
    """Base class: fresh isolated git repo + helpers for each test."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix='auto-fixup-test-')
        self.repo = os.path.join(self.tmpdir, 'repo')
        os.makedirs(self.repo)
        self._ts = 1_000_000  # monotonically increasing commit timestamps

        # HOME → tmpdir: prevents ~/.config/v1/git_named_branches from leaking in.
        # GIT_CONFIG_NOSYSTEM: skip /etc/gitconfig.
        # GIT_ADVICE: suppress 'hint:' chatter.
        self.env = {
            **os.environ,
            'HOME': self.tmpdir,
            'GIT_CONFIG_NOSYSTEM': '1',
            'GIT_ADVICE': '0',
            'GIT_AUTHOR_NAME': 'Tester',
            'GIT_AUTHOR_EMAIL': 'test@example.com',
            'GIT_COMMITTER_NAME': 'Tester',
            'GIT_COMMITTER_EMAIL': 'test@example.com',
            'GIT_EDITOR': '/usr/bin/true',
        }

        self._git('init', '--quiet')
        self._git('config', 'user.name', 'Tester')
        self._git('config', 'user.email', 'test@example.com')

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    # ── helpers ──────────────────────────────────────────────────────────────

    def _git(self, *args, check=True, cwd=None, env_extra=None):
        env = dict(self.env)
        if env_extra:
            env.update(env_extra)
        result = subprocess.run(
            ['git', *args],
            cwd=cwd or self.repo,
            env=env,
            capture_output=True,
            text=True,
        )
        if check and result.returncode != 0:
            raise RuntimeError(
                f'git {list(args)!r} failed (exit {result.returncode}):\n'
                f'  stdout: {result.stdout!r}\n  stderr: {result.stderr!r}'
            )
        return result

    def _write(self, relpath, content):
        path = os.path.join(self.repo, relpath)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'w') as f:
            f.write(content)

    def _remove(self, relpath):
        os.remove(os.path.join(self.repo, relpath))

    def _commit(self, message, files=None, ts=None):
        """Stage files (or all changes) and create a commit with a controlled timestamp.
        GIT_AUTHOR_DATE requires the @<epoch> prefix for raw Unix timestamps."""
        if ts is None:
            self._ts += 1
            ts = self._ts
        date = f'@{ts} +0000'
        env_extra = {'GIT_AUTHOR_DATE': date, 'GIT_COMMITTER_DATE': date}
        if files:
            for f in files:
                self._git('add', f)
        else:
            self._git('add', '-A')
        self._git('commit', '-m', message, env_extra=env_extra)
        return self._git('rev-parse', 'HEAD').stdout.strip()

    def _run(self, *args):
        """Run auto-fixup.d in the test repo and return the CompletedProcess."""
        return subprocess.run(
            [SCRIPT_PATH, *args],
            cwd=self.repo,
            env=self.env,
            capture_output=True,
            text=True,
        )

    def _set_origin_master(self, commit_hash):
        """Simulate origin/master pointing at commit_hash by writing the ref directly."""
        ref_dir = os.path.join(self.repo, '.git', 'refs', 'remotes', 'origin')
        os.makedirs(ref_dir, exist_ok=True)
        with open(os.path.join(ref_dir, 'master'), 'w') as f:
            f.write(commit_hash + '\n')

    def _set_named_branches(self, *branches):
        """Populate ~/.config/v1/git_named_branches relative to the isolated HOME."""
        cfg_dir = os.path.join(self.tmpdir, '.config', 'v1')
        os.makedirs(cfg_dir, exist_ok=True)
        with open(os.path.join(cfg_dir, 'git_named_branches'), 'w') as f:
            f.write('\n'.join(branches) + '\n')

    def _log_subjects(self):
        """Return commit subjects newest-first."""
        r = self._git('log', '--format=%s')
        return [l for l in r.stdout.strip().splitlines() if l]

    def _commit_count(self):
        return len(self._log_subjects())


# ═════════════════════════════════════════════════════════════════════════════
# Group 1: No-op / early exits
# ═════════════════════════════════════════════════════════════════════════════

class TestNoOp(AutoFixupBase):

    def test_no_changes(self):
        """Clean working tree: nothing to fix up."""
        self._write('file.txt', 'content\n')
        self._commit('Initial')
        r = self._run()
        self.assertEqual(r.returncode, 0)
        self.assertIn('No files changed', r.stdout)
        self.assertEqual(self._commit_count(), 1)

    def test_only_additions_unstaged(self):
        """Appending lines without removing any: no base commit can be found."""
        self._write('file.txt', 'line1\nline2\n')
        self._commit('Initial')
        self._write('file.txt', 'line1\nline2\nline3\n')  # pure append, no removal
        r = self._run()
        self.assertEqual(r.returncode, 1)
        self.assertIn('No lines removed', r.stderr)

    def test_new_file_staged(self):
        """A brand-new staged file (git status 'A') is not tracked by the script.
        Only M/D/R staged statuses are collected; 'A' is silently skipped."""
        self._write('seed.txt', 'seed\n')
        self._commit('Seed')
        self._write('new_file.txt', 'brand new content\n')
        self._git('add', 'new_file.txt')
        r = self._run()
        self.assertEqual(r.returncode, 0)
        self.assertIn('No files changed', r.stdout)


# ═════════════════════════════════════════════════════════════════════════════
# Group 2: File selection (staged vs. unstaged vs. explicit args)
# ═════════════════════════════════════════════════════════════════════════════

class TestFileSelection(AutoFixupBase):

    def test_staged_used_when_available(self):
        """A staged modification is found and a fixup target is identified."""
        self._write('file.txt', 'line1\nline2\n')
        self._commit('Add file')
        self._write('file.txt', 'modified\nline2\n')
        self._git('add', 'file.txt')
        r = self._run('--dry-run')
        self.assertEqual(r.returncode, 0)
        self.assertIn('fixup', r.stdout)
        self.assertIn('Add file', r.stdout)

    def test_unstaged_used_when_no_staged(self):
        """Unstaged modification is used when nothing is staged."""
        self._write('file.txt', 'line1\nline2\n')
        self._commit('Add file')
        self._write('file.txt', 'modified\nline2\n')  # not staged
        r = self._run('--dry-run')
        self.assertEqual(r.returncode, 0)
        self.assertIn('fixup', r.stdout)

    def test_staged_prioritized_over_unstaged(self):
        """When staged changes exist, unstaged changes to other files are ignored."""
        self._write('file1.txt', 'line1\nfiller\n')
        self._commit('Commit A', ts=1_000_001)
        self._write('file2.txt', 'line2\nfiller\n')
        self._commit('Commit B', ts=1_000_002)

        self._write('file1.txt', 'modified1\nfiller\n')
        self._git('add', 'file1.txt')              # staged — from Commit A
        self._write('file2.txt', 'modified2\nfiller\n')  # NOT staged — from Commit B

        r = self._run('--dry-run')
        self.assertEqual(r.returncode, 0)
        self.assertIn('Commit A', r.stdout)
        self.assertNotIn('Commit B', r.stdout)

    def test_explicit_file_arg_used(self):
        """Explicitly passed file is used regardless of staged/unstaged state."""
        self._write('file1.txt', 'line1\nfiller\n')
        self._commit('Commit A')
        self._write('file2.txt', 'line2\nfiller\n')
        self._commit('Commit B')
        self._write('file1.txt', 'modified1\nfiller\n')
        self._write('file2.txt', 'modified2\nfiller\n')

        r = self._run('--dry-run', 'file1.txt')
        self.assertEqual(r.returncode, 0)
        self.assertIn('Commit A', r.stdout)
        self.assertNotIn('Commit B', r.stdout)

    def test_explicit_file_arg_limits_scope(self):
        """Only the specified file is considered, not other modified files."""
        self._write('file1.txt', 'line1\nfiller\n')
        self._commit('Commit A')
        self._write('file2.txt', 'line2\nfiller\n')
        self._commit('Commit B')
        self._write('file1.txt', 'modified1\nfiller\n')
        self._write('file2.txt', 'modified2\nfiller\n')

        r = self._run('--dry-run', 'file2.txt')
        self.assertEqual(r.returncode, 0)
        self.assertIn('Commit B', r.stdout)
        self.assertNotIn('Commit A', r.stdout)

    def test_staged_deletion_detected(self):
        """A staged file deletion (D in first column of git status) triggers a fixup."""
        self._write('file.txt', 'line1\nline2\n')
        self._commit('Add file')
        self._git('rm', 'file.txt')
        r = self._run('--dry-run')
        self.assertEqual(r.returncode, 0)
        self.assertIn('fixup', r.stdout)

    def test_unstaged_deletion_detected(self):
        """Deleting a file from disk without staging (D in second column) triggers a fixup."""
        self._write('file.txt', 'line1\nline2\n')
        self._commit('Add file')
        self._remove('file.txt')  # working-tree deletion, not staged
        r = self._run('--dry-run')
        self.assertEqual(r.returncode, 0)
        self.assertIn('fixup', r.stdout)


# ═════════════════════════════════════════════════════════════════════════════
# Group 3: Diff parsing and hunk detection
# ═════════════════════════════════════════════════════════════════════════════

class TestDiffParsing(AutoFixupBase):

    def test_single_line_modification(self):
        """Changing one line in a multi-line file produces one hunk and one base commit."""
        self._write('file.txt', 'line1\nline2\nline3\n')
        self._commit('Add file')
        self._write('file.txt', 'line1\nMODIFIED\nline3\n')
        r = self._run('--dry-run')
        self.assertEqual(r.returncode, 0)
        self.assertIn('fixup', r.stdout)

    def test_multiple_separate_hunks_same_commit(self):
        """Two hunks far apart in the same file, both from the same commit."""
        # 15 lines; modify line 1 and line 12 (gap > 6 → separate hunks)
        lines = [f'line{i:02d}' for i in range(1, 16)]
        self._write('file.txt', '\n'.join(lines) + '\n')
        self._commit('Add file')
        lines[0] = 'MODIFIED_TOP'
        lines[11] = 'MODIFIED_BOTTOM'
        self._write('file.txt', '\n'.join(lines) + '\n')
        r = self._run('--dry-run')
        self.assertEqual(r.returncode, 0)
        self.assertIn('fixup', r.stdout)

    def test_deleted_file_all_lines_blamed(self):
        """Staging a file deletion causes all its lines to be blamed, finding a base commit."""
        self._write('file.txt', 'alpha\nbeta\ngamma\n')
        self._commit('Add file')
        self._git('rm', 'file.txt')
        r = self._run('--dry-run')
        self.assertEqual(r.returncode, 0)
        self.assertIn('fixup', r.stdout)

    def test_pure_rename_staged(self):
        """A staged pure rename creates a kWholeFile hunk blamed against HEAD -- new.txt.
        BUG: new.txt doesn't exist at HEAD (only old.txt does), so git blame fails.
        Expected correct behaviour: fixup is created for the commit that added old.txt."""
        self._write('old.txt', 'content line\nfiller\n')
        self._commit('Add old.txt')
        self._git('mv', 'old.txt', 'new.txt')
        r = self._run('--dry-run')
        # BUG: git blame HEAD -- new.txt fails → script exits with git error
        self.assertEqual(r.returncode, 0)   # FAILS: actually exit 1
        self.assertIn('fixup', r.stdout)

    def test_rename_with_content_change(self):
        """A staged rename + content change: line-removal hunks are used for blame."""
        self._write('old.txt', 'original line\nextra line\n')
        self._commit('Add old.txt')
        self._git('mv', 'old.txt', 'new.txt')
        self._write('new.txt', 'modified line\nextra line\n')
        self._git('add', 'new.txt')
        r = self._run('--dry-run')
        self.assertEqual(r.returncode, 0)
        self.assertIn('fixup', r.stdout)

    def test_submodule_change_ignored(self):
        """A submodule pointer update (1 added + 1 removed Subproject line) is ignored."""
        sub_dir = os.path.join(self.tmpdir, 'sub')
        os.makedirs(sub_dir)

        def sub_git(*args):
            subprocess.run(
                ['git', *args], cwd=sub_dir, env=self.env,
                check=True, capture_output=True,
            )

        sub_git('init', '--quiet')
        sub_git('config', 'user.name', 'Tester')
        sub_git('config', 'user.email', 'test@example.com')

        with open(os.path.join(sub_dir, 'sub.txt'), 'w') as f:
            f.write('sub v1\n')
        sub_git('add', '.')
        sub_git('commit', '-m', 'Sub v1')

        # protocol.file.allow=always is required since git 2.38.1 (security hardening)
        self._git('config', 'protocol.file.allow', 'always')
        self._git('submodule', 'add', sub_dir, 'submod',
                  env_extra={'GIT_CONFIG_COUNT': '1',
                             'GIT_CONFIG_KEY_0': 'protocol.file.allow',
                             'GIT_CONFIG_VALUE_0': 'always'})
        self._commit('Add submodule')

        # Second commit in sub repo
        with open(os.path.join(sub_dir, 'sub.txt'), 'w') as f:
            f.write('sub v2\n')
        sub_git('add', '.')
        sub_git('commit', '-m', 'Sub v2')
        second_hash = subprocess.run(
            ['git', 'rev-parse', 'HEAD'],
            cwd=sub_dir, env=self.env, capture_output=True, text=True, check=True,
        ).stdout.strip()

        # Update the submodule pointer: fetch from origin, checkout new commit
        submod_path = os.path.join(self.repo, 'submod')
        subprocess.run(
            ['git', 'fetch', 'origin'],
            cwd=submod_path, env=self.env, check=True, capture_output=True,
        )
        subprocess.run(
            ['git', 'checkout', second_hash],
            cwd=submod_path, env=self.env, check=True, capture_output=True,
        )
        self._git('add', 'submod')

        # The diff for a submodule pointer update has @@ -1 +1 @@ (no comma),
        # which the script skips via its submodule-detection path.
        r = self._run()
        self.assertEqual(r.returncode, 1)
        self.assertIn('No lines removed', r.stderr)


# ═════════════════════════════════════════════════════════════════════════════
# Group 4: Base commit resolution (fixup/squash chains, uniqueness)
# ═════════════════════════════════════════════════════════════════════════════

class TestBaseCommitResolution(AutoFixupBase):

    def test_multiple_commits_different_files(self):
        """Changed lines from two different commits → ambiguous, refuse."""
        self._write('file1.txt', 'line1\nfiller\n')
        self._commit('Commit A')
        self._write('file2.txt', 'line2\nfiller\n')
        self._commit('Commit B')
        self._write('file1.txt', 'modified1\nfiller\n')
        self._write('file2.txt', 'modified2\nfiller\n')
        r = self._run()
        self.assertEqual(r.returncode, 1)
        self.assertIn('multiple base commits', r.stderr)

    def test_multiple_commits_same_file_different_hunks(self):
        """Two hunks in the same file each blamed to a different commit → ambiguous."""
        a_lines = '\n'.join(f'a{i}' for i in range(1, 6))
        b_lines = '\n'.join(f'b{i}' for i in range(1, 11))
        self._write('file.txt', a_lines + '\n')
        self._commit('Commit A', ts=1_000_001)
        self._write('file.txt', a_lines + '\n' + b_lines + '\n')
        self._commit('Commit B', ts=1_000_002)

        # Modify line 1 (from A) and line 12 = b7 (from B) — gap > 6 → separate hunks
        lines = (a_lines + '\n' + b_lines).splitlines()
        lines[0] = 'MODIFIED_A'
        lines[11] = 'MODIFIED_B'
        self._write('file.txt', '\n'.join(lines) + '\n')
        r = self._run()
        self.assertEqual(r.returncode, 1)
        self.assertIn('multiple base commits', r.stderr)

    def test_multiple_files_same_commit(self):
        """Lines from different files all blamed to the same commit → single base."""
        self._write('file1.txt', 'line1\nfiller\n')
        self._write('file2.txt', 'line2\nfiller\n')
        self._commit('Commit A')
        self._write('file1.txt', 'modified1\nfiller\n')
        self._write('file2.txt', 'modified2\nfiller\n')
        r = self._run('--dry-run')
        self.assertEqual(r.returncode, 0)
        self.assertIn('Commit A', r.stdout)

    def test_fixup_commit_resolves_to_original(self):
        """Lines last touched by a 'fixup! X' commit resolve to the original commit X."""
        self._write('file.txt', 'original line\nfiller\n')
        self._commit('Base', ts=1_000_001)
        self._write('file.txt', 'fixed line\nfiller\n')
        self._commit('fixup! Base', ts=1_000_002)
        self._write('file.txt', 'modified line\nfiller\n')
        r = self._run('--dry-run')
        self.assertEqual(r.returncode, 0)
        self.assertIn('Base', r.stdout)
        self.assertNotIn('fixup! fixup!', r.stdout)

    def test_squash_commit_resolves_to_original(self):
        """Lines last touched by a 'squash! X' commit resolve to the original commit X."""
        self._write('file.txt', 'original line\nfiller\n')
        self._commit('Base', ts=1_000_001)
        self._write('file.txt', 'squashed line\nfiller\n')
        self._commit('squash! Base', ts=1_000_002)
        self._write('file.txt', 'modified line\nfiller\n')
        r = self._run('--dry-run')
        self.assertEqual(r.returncode, 0)
        self.assertIn('Base', r.stdout)

    def test_double_fixup_chain(self):
        """'fixup! fixup! X' strips two levels and resolves to the original X."""
        self._write('file.txt', 'A\nfiller\n')
        self._commit('Base', ts=1_000_001)
        self._write('file.txt', 'B\nfiller\n')
        self._commit('fixup! Base', ts=1_000_002)
        self._write('file.txt', 'C\nfiller\n')
        self._commit('fixup! fixup! Base', ts=1_000_003)
        self._write('file.txt', 'D\nfiller\n')
        r = self._run('--dry-run')
        self.assertEqual(r.returncode, 0)
        self.assertIn('Base', r.stdout)

    def test_fixup_and_original_collapse_to_single_base(self):
        """Lines blamed to 'Base' and to 'fixup! Base' both collapse to the same target."""
        self._write('file.txt', 'line A\nline B\n')
        self._commit('Base', ts=1_000_001)
        self._write('file.txt', 'line A\nline B2\n')
        self._commit('fixup! Base', ts=1_000_002)
        # Modify both line 1 (attributed to Base) and line 2 (attributed to fixup! Base)
        self._write('file.txt', 'modified A\nmodified B2\n')
        r = self._run('--dry-run')
        self.assertEqual(r.returncode, 0)
        self.assertIn('Base', r.stdout)

    def test_oldest_commit_chosen_when_titles_match(self):
        """When blamed lines resolve to the same title, the oldest commit's hash is used.
        Setup: Commit A 'Work' owns line 1; Commit B 'fixup! Work' owns line 2.
        Both resolve to 'Work'; the deduplication must keep the older A."""
        # Commit A: introduces both lines
        self._write('file.txt', 'line from A\nfiller\n')
        hash_a = self._commit('Work', ts=1_000_001)
        # fixup! Work: only changes line 2, so blame for line 1 still points to A
        self._write('file.txt', 'line from A\nmodified filler\n')
        self._commit('fixup! Work', ts=1_000_002)
        # Modify both lines: line 1 blamed to A, line 2 blamed to fixup! Work
        self._write('file.txt', 'modified line\nmodified again\n')
        r = self._run('--dry-run')
        self.assertEqual(r.returncode, 0)
        short_a = self._git('rev-parse', '--short', hash_a).stdout.strip()
        self.assertIn(short_a, r.stdout)


# ═════════════════════════════════════════════════════════════════════════════
# Group 5: Named branch protection
# ═════════════════════════════════════════════════════════════════════════════

class TestNamedBranchProtection(AutoFixupBase):

    def test_base_on_origin_master_blocked(self):
        """Base commit reachable from origin/master → refuse to create fixup."""
        self._write('file.txt', 'line1\nfiller\n')
        hash_a = self._commit('Commit A')
        self._set_origin_master(hash_a)
        self._write('file.txt', 'modified\nfiller\n')
        r = self._run()
        self.assertEqual(r.returncode, 1)
        self.assertIn('named branch', r.stderr)

    def test_base_after_origin_master_allowed(self):
        """Base commit NOT reachable from origin/master → fixup is allowed."""
        self._write('file.txt', 'line1\nfiller\n')
        hash_a = self._commit('Commit A')
        self._set_origin_master(hash_a)          # A is on origin/master
        self._write('file2.txt', 'line2\nfiller\n')
        self._commit('Commit B')                 # B is after origin/master
        self._write('file2.txt', 'modified\nfiller\n')
        r = self._run('--dry-run')
        self.assertEqual(r.returncode, 0)
        self.assertIn('fixup', r.stdout)

    def test_base_on_origin_master_with_force(self):
        """--force overrides the named-branch check, printing a warning."""
        self._write('file.txt', 'line1\nfiller\n')
        hash_a = self._commit('Commit A')
        self._set_origin_master(hash_a)
        self._write('file.txt', 'modified\nfiller\n')
        r = self._run('--force', '--dry-run')
        self.assertEqual(r.returncode, 0)
        self.assertIn('Warning', r.stdout)
        self.assertIn('named branch', r.stdout)

    def test_no_origin_master_always_allowed(self):
        """Without any remote, --ignore-missing makes the branch check a no-op."""
        self._write('file.txt', 'line1\nfiller\n')
        self._commit('Commit A')
        self._write('file.txt', 'modified\nfiller\n')
        r = self._run('--dry-run')
        self.assertEqual(r.returncode, 0)
        self.assertIn('fixup', r.stdout)

    def test_base_on_custom_named_branch_blocked(self):
        """A commit reachable from a branch in git_named_branches is protected."""
        self._write('file.txt', 'line1\nfiller\n')
        hash_a = self._commit('Commit A')
        self._git('branch', 'my-stable', hash_a)
        self._set_named_branches('my-stable')
        self._write('file.txt', 'modified\nfiller\n')
        r = self._run()
        self.assertEqual(r.returncode, 1)
        self.assertIn('named branch', r.stderr)

    def test_base_after_custom_named_branch_allowed(self):
        """A commit newer than the named-branch tip is not protected."""
        self._write('file.txt', 'line1\nfiller\n')
        hash_a = self._commit('Commit A')
        self._git('branch', 'my-stable', hash_a)
        self._set_named_branches('my-stable')
        self._write('file2.txt', 'line2\nfiller\n')
        self._commit('Commit B')
        self._write('file2.txt', 'modified\nfiller\n')
        r = self._run('--dry-run')
        self.assertEqual(r.returncode, 0)
        self.assertIn('fixup', r.stdout)

    def test_named_branches_file_comments_and_blanks_ignored(self):
        """Lines starting with # and blank lines in git_named_branches are ignored."""
        self._write('file.txt', 'line1\nfiller\n')
        hash_a = self._commit('Commit A')
        self._git('branch', 'my-stable', hash_a)
        self._set_named_branches('# this is a comment', '', 'my-stable', '')
        self._write('file.txt', 'modified\nfiller\n')
        r = self._run()
        self.assertEqual(r.returncode, 1)
        self.assertIn('named branch', r.stderr)


# ═════════════════════════════════════════════════════════════════════════════
# Group 6: CLI options
# ═════════════════════════════════════════════════════════════════════════════

class TestOptions(AutoFixupBase):

    def _setup_simple_modification(self):
        """Commit a two-line file, then change line 1 in the working tree."""
        self._write('file.txt', 'line1\nline2\n')
        self._commit('Base commit')
        self._write('file.txt', 'modified\nline2\n')

    def test_dry_run_no_commit_created(self):
        """--dry-run reports the intended action without creating a commit."""
        self._setup_simple_modification()
        r = self._run('--dry-run')
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self._commit_count(), 1)

    def test_dry_run_short_flag(self):
        """-n is the short form of --dry-run."""
        self._setup_simple_modification()
        r = self._run('-n')
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self._commit_count(), 1)

    def test_dry_run_shows_message(self):
        """Dry-run output names the base commit."""
        self._setup_simple_modification()
        r = self._run('--dry-run')
        self.assertIn('Would create fixup', r.stdout)
        self.assertIn('Base commit', r.stdout)

    def test_default_creates_fixup_commit(self):
        """Without options, a fixup! commit is created."""
        self._setup_simple_modification()
        r = self._run()
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self._commit_count(), 2)
        subjects = self._log_subjects()
        self.assertTrue(subjects[0].startswith('fixup! '))
        self.assertIn('Base commit', subjects[0])

    def test_default_reports_created_commit(self):
        """Success output mentions the created hash and the base commit."""
        self._setup_simple_modification()
        r = self._run()
        self.assertIn('Created fixup', r.stdout)
        self.assertIn('Base commit', r.stdout)

    def test_squash_option_creates_squash_commit(self):
        """--squash creates a squash! commit instead of a fixup! commit."""
        self._setup_simple_modification()
        r = self._run('--squash')
        self.assertEqual(r.returncode, 0)
        subjects = self._log_subjects()
        self.assertTrue(subjects[0].startswith('squash! '))
        self.assertIn('Base commit', subjects[0])

    def test_squash_short_flag(self):
        """-s is the short form of --squash."""
        self._setup_simple_modification()
        r = self._run('-s')
        self.assertEqual(r.returncode, 0)
        self.assertTrue(self._log_subjects()[0].startswith('squash! '))

    def test_verbose_output_unstaged(self):
        """--verbose prints the files list, hunk summary, and candidate list."""
        self._setup_simple_modification()
        r = self._run('--verbose', '--dry-run')
        self.assertEqual(r.returncode, 0)
        self.assertIn('Modified', r.stdout)
        self.assertIn('Removed hunks:', r.stdout)
        self.assertIn('Base commit candidates:', r.stdout)

    def test_verbose_output_staged(self):
        """With staged changes, --verbose reports 'Staged' instead of 'Modified'."""
        self._write('file.txt', 'line1\nline2\n')
        self._commit('Base commit')
        self._write('file.txt', 'modified\nline2\n')
        self._git('add', 'file.txt')
        r = self._run('-v', '-n')
        self.assertEqual(r.returncode, 0)
        self.assertIn('Staged', r.stdout)

    def test_help_exits_zero(self):
        """--help prints usage and exits 0."""
        r = self._run('--help')
        self.assertEqual(r.returncode, 0)
        self.assertIn('Usage:', r.stdout)

    def test_help_short_flag(self):
        """-h is the short form of --help."""
        r = self._run('-h')
        self.assertEqual(r.returncode, 0)
        self.assertIn('Usage:', r.stdout)

    def test_option_bundling(self):
        """-nv bundles --dry-run and --verbose."""
        self._setup_simple_modification()
        r = self._run('-nv')
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self._commit_count(), 1)       # dry-run: no commit
        self.assertIn('Would create fixup', r.stdout)   # dry-run message
        self.assertIn('Removed hunks:', r.stdout)       # verbose output

    def test_force_short_flag(self):
        """-f is the short form of --force."""
        self._write('file.txt', 'line1\nfiller\n')
        hash_a = self._commit('Commit A')
        self._set_origin_master(hash_a)
        self._write('file.txt', 'modified\nfiller\n')
        r = self._run('-f', '--dry-run')
        self.assertEqual(r.returncode, 0)
        self.assertIn('Warning', r.stdout)


# ═════════════════════════════════════════════════════════════════════════════
# Known bug: single-line files with single-line changes
#
# When both the old and new versions of a file hunk contain exactly one line
# (no comma in either side of the @@ header, e.g. "@@ -1 +1 @@"), the script
# hits its submodule-detection branch and calls `continue`, leaving currentLine
# at 0.  The subsequent `-` line sets currentHunk.beginLine = 0, which the
# endCurrentHunk() guard (`beginLine > 0`) then rejects — so no hunk is
# recorded.  The result is a spurious "No lines removed. Cannot fix up." error.
#
# A secondary effect: because currentLine is NOT reset between files, a later
# file can accidentally inherit a non-zero currentLine from the previous file,
# producing a hunk at the wrong line number.
#
# All tests in this class assert the CORRECT (desired) behaviour and are
# therefore expected to FAIL until the script is fixed.
# ═════════════════════════════════════════════════════════════════════════════

class TestSingleLineFileBug(AutoFixupBase):

    def test_single_line_modification_unstaged(self):
        """Replacing the sole line of a 1-line file should yield a fixup.
        BUG: @@ -1 +1 @@ triggers the submodule skip → 'No lines removed'."""
        self._write('file.txt', 'original\n')
        self._commit('Initial')
        self._write('file.txt', 'modified\n')
        r = self._run('--dry-run')
        # correct: exit 0 + fixup message
        self.assertEqual(r.returncode, 0)
        self.assertIn('fixup', r.stdout)

    def test_single_line_modification_staged(self):
        """Same as above but with the change staged.
        BUG: @@ -1 +1 @@ is skipped → 'No lines removed'."""
        self._write('file.txt', 'original\n')
        self._commit('Initial')
        self._write('file.txt', 'modified\n')
        self._git('add', 'file.txt')
        r = self._run('--dry-run')
        self.assertEqual(r.returncode, 0)
        self.assertIn('fixup', r.stdout)

    def test_single_line_file_with_explicit_arg(self):
        """Explicitly passing a 1-line file that was modified should work.
        BUG: @@ -1 +1 @@ skipped → 'No lines removed'."""
        self._write('file.txt', 'original\n')
        self._commit('Commit A')
        self._write('file.txt', 'modified\n')
        r = self._run('--dry-run', 'file.txt')
        self.assertEqual(r.returncode, 0)
        self.assertIn('Commit A', r.stdout)

    def test_two_single_line_files_different_commits(self):
        """Two 1-line files from two commits — should report multiple base commits.
        BUG: file1.txt's hunk is dropped; currentLine spillover gives file2.txt a hunk
        at line 1 (from Commit B), so the script finds only one base and succeeds."""
        self._write('file1.txt', 'A\n')
        self._commit('Commit A')
        self._write('file2.txt', 'B\n')
        self._commit('Commit B')
        self._write('file1.txt', 'X\n')
        self._write('file2.txt', 'Y\n')
        r = self._run()
        # correct: both files' commits found → exit 1
        self.assertEqual(r.returncode, 1)
        self.assertIn('multiple base commits', r.stderr)

    def test_staged_1line_prioritized_over_unstaged(self):
        """Staged 1-line change should be used in preference to unstaged changes.
        BUG: staged diff has @@ -1 +1 @@ → hunk skipped → 'No lines removed'."""
        self._write('file1.txt', 'line1\n')
        self._commit('Commit A', ts=1_000_001)
        self._write('file2.txt', 'line2\n')
        self._commit('Commit B', ts=1_000_002)
        self._write('file1.txt', 'modified1\n')
        self._git('add', 'file1.txt')              # staged — from Commit A
        self._write('file2.txt', 'modified2\n')    # NOT staged — from Commit B
        r = self._run('--dry-run')
        # correct: uses staged file1.txt, finds Commit A
        self.assertEqual(r.returncode, 0)
        self.assertIn('Commit A', r.stdout)


# ═════════════════════════════════════════════════════════════════════════════
# Known limitation: permission-change (chmod) fixups
#
# A pure chmod produces only "old mode"/"new mode" lines in the diff — no @@
# hunks, no removed lines.  The current script therefore exits with
# "No lines removed. Cannot fix up."
#
# Desired behaviour: a permission change on a file should create a fixup for
# the most-recent commit that changed that file's permissions, or — if no
# such commit exists — for the commit that created the file.
#
# All tests in this class assert the CORRECT (desired) behaviour and are
# therefore expected to FAIL until the script is fixed.
# ═════════════════════════════════════════════════════════════════════════════

class TestPermissionChanges(AutoFixupBase):

    def test_chmod_targets_creation_commit(self):
        """chmod on a file with no prior permission change → fixup the creation commit."""
        self._write('file.txt', 'line1\nline2\n')
        self._commit('Add file')
        os.chmod(os.path.join(self.repo, 'file.txt'), 0o755)
        r = self._run('--dry-run')
        self.assertEqual(r.returncode, 0)
        self.assertIn('fixup', r.stdout)
        self.assertIn('Add file', r.stdout)

    def test_chmod_targets_last_permission_change(self):
        """chmod after a previous chmod → fixup the previous chmod commit, not creation."""
        self._write('file.txt', 'line1\nline2\n')
        self._commit('Add file', ts=1_000_001)
        os.chmod(os.path.join(self.repo, 'file.txt'), 0o755)
        self._commit('Make executable', ts=1_000_002)
        # chmod back — 'Make executable' is the last permission-change commit
        os.chmod(os.path.join(self.repo, 'file.txt'), 0o644)
        r = self._run('--dry-run')
        self.assertEqual(r.returncode, 0)
        self.assertIn('Make executable', r.stdout)
        self.assertNotIn('Add file', r.stdout)

    def test_staged_chmod_targets_creation_commit(self):
        """Staged chmod is detected and resolves to the creation commit."""
        self._write('file.txt', 'line1\nline2\n')
        self._commit('Add file')
        os.chmod(os.path.join(self.repo, 'file.txt'), 0o755)
        self._git('add', 'file.txt')
        r = self._run('--dry-run')
        self.assertEqual(r.returncode, 0)
        self.assertIn('fixup', r.stdout)
        self.assertIn('Add file', r.stdout)

    def test_chmod_on_named_branch_blocked(self):
        """chmod whose resolved target is on origin/master is blocked."""
        self._write('file.txt', 'line1\nline2\n')
        hash_a = self._commit('Add file')
        self._set_origin_master(hash_a)
        os.chmod(os.path.join(self.repo, 'file.txt'), 0o755)
        r = self._run()
        self.assertEqual(r.returncode, 1)
        self.assertIn('named branch', r.stderr)

    def test_chmod_multiple_files_different_commits_ambiguous(self):
        """chmod on two files whose creation commits differ → refuse (multiple base commits)."""
        self._write('file1.txt', 'line1\nline2\n')
        self._commit('Commit A', ts=1_000_001)
        self._write('file2.txt', 'line1\nline2\n')
        self._commit('Commit B', ts=1_000_002)
        os.chmod(os.path.join(self.repo, 'file1.txt'), 0o755)
        os.chmod(os.path.join(self.repo, 'file2.txt'), 0o755)
        r = self._run()
        self.assertEqual(r.returncode, 1)
        self.assertIn('multiple base commits', r.stderr)


if __name__ == '__main__':
    unittest.main()

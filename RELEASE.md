# Release process

FieldOps Pro - Phase 6, Stream 6.4 (6.4-D12)

How a release is cut. Written as a checklist because releases are cut
infrequently, which is exactly when steps get forgotten.

Read `VERSIONING.md` first to decide which number you are cutting.

---

## 1. Before you start

A release is only worth cutting from a tree that is already green. If the suite
is red or `main` has uncommitted work, stop here.

```powershell
git checkout main
git pull
git status              # must be clean
.\tests\Run-AllTests.ps1
```

All tests pass, or the release does not happen. There is no "known failure we
will fix after shipping" -- that is how a known failure becomes a shipped one.

---

## 2. Decide the version

| Question | Answer |
|----------|--------|
| Did a published schema lose or rename a field? | MAJOR (MINOR while pre-1.0) |
| Did a script parameter change meaning? | MAJOR (MINOR while pre-1.0) |
| New engine, language, playbook, or optional parameter? | MINOR |
| Only fixes and translations? | PATCH |

**Then ask the question SemVer does not**: can this release change a rule's
verdict on unchanged hardware? If yes, it needs a named changelog entry saying
which rule and in which direction, regardless of the number you chose.

---

## 3. Update the changelog

Move `[Unreleased]` to the new version heading with today's date, and open a
fresh `[Unreleased]` above it.

Write entries from **merged pull requests**, not from memory:

```powershell
git log --merges --pretty=format:"%ad | %s" --date=short v0.5.2..HEAD
```

Include what was fixed, in the words a customer would use. A changelog listing
only additions reads as marketing and gets skimmed; one that names a defect
honestly gets read.

Update the comparison links at the bottom of the file.

---

## 4. Check the version string everywhere

The version appears in several places, and one disagreeing with the others is
the kind of detail an evaluator notices.

- [ ] `CHANGELOG.md` heading
- [ ] Release zip filename
- [ ] Git tag
- [ ] GitHub release title
- [ ] `DOCS/INSTALL.md` deployment example
- [ ] Report footer, if it carries a version

---

## 5. Verify the tree

```powershell
.\TOOLS\Apply-LicenseHeaders.ps1        # stamps anything new; idempotent
.\tests\Run-AllTests.ps1                # green, including Slow audits
.\SCRIPTS\Core\Test-Installation.ps1    # must report READY
```

Then check by hand for things no test covers:

- [ ] No `.bak`, `.tmp` or scratch files in the tree
- [ ] `REPORTS\` and `LOGS\` empty of real machine data
- [ ] `CONFIG\technician.json` carries **no API key and no real name**
- [ ] `LICENSE` and `NOTICE` present at root
- [ ] No absolute developer paths in any deployed script (audit A5 covers this, but look anyway)

**The configuration check is the one that matters most.** A release zip
containing a live API key is an incident, and it is exactly the kind of thing
that gets missed because the file is normally correct on the developer's machine.

---

## 6. Build the release zip

Build it from a **clean checkout**, never from the working tree. A working tree
carries editor artifacts, stale reports and local configuration; a fresh clone
carries only what is committed.

```powershell
$ver = 'v0.6.0'
$stage = "$env:TEMP\fieldops-$ver"
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue

git clone --depth 1 --branch $ver . $stage
Remove-Item "$stage\.git" -Recurse -Force

# The stick does not need the test suite or the developer tooling.
Remove-Item "$stage\tests"   -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$stage\schemas" -Recurse -Force -ErrorAction SilentlyContinue

Compress-Archive -Path "$stage\*" -DestinationPath ".\fieldops-pro-$ver.zip" -Force
```

Note that `TOOLS\PowerShellModules\` stays. It carries the offline Pester bundle,
which is what makes the suite runnable air-gapped by anyone who later clones the
repository.

### Verify the artifact

Extract it somewhere clean and treat it as a customer would:

```powershell
Expand-Archive .\fieldops-pro-v0.6.0.zip -DestinationPath $env:TEMP\fieldops-verify
& "$env:TEMP\fieldops-verify\SCRIPTS\Core\Test-Installation.ps1"
```

It must report **READY**. If it does not, the zip is wrong -- not the self-test.

- [ ] Self-test reports READY from the extracted zip
- [ ] `Get-ChildItem -Recurse -Filter *.json | Select-String 'sk-ant'` finds nothing
- [ ] A French report renders with correct accents from the extracted copy

---

## 7. Tag and publish

```powershell
git tag -a v0.6.0 -m "FieldOps Pro v0.6.0"
git push origin v0.6.0
```

Create the GitHub release against that tag. Attach the zip. Paste the changelog
section verbatim -- release notes that paraphrase the changelog eventually
diverge from it.

---

## 8. Deploy to a real stick, and use it

```powershell
Expand-Archive .\fieldops-pro-v0.6.0.zip -DestinationPath E:\ -Force
E:\SCRIPTS\Core\Test-Installation.ps1
```

Then run a full compliance report on real hardware and read it end to end.

**This step is not ceremony.** The self-test verifies structure; only a real run
catches a report that renders with a broken section, a locale that falls back
silently, or an evaluator that degrades where it should not. A release that has
never been run from the medium it ships on has not been tested the way it will
be used.

- [ ] Launcher opens
- [ ] Compliance report renders in French with correct accents
- [ ] Report signature validates
- [ ] English render works
- [ ] Diagnostics write to `REPORTS\` and `LOGS\`

---

## 9. If a release is bad

Do not delete the tag or the release. A version that reached anyone is part of
the record, and quietly removing it means someone running it has no way to find
out it was withdrawn.

Instead:

1. Mark the GitHub release as deprecated, naming the defect
2. Fix forward
3. Cut a PATCH release
4. Record both the defect and the fix in the changelog

---

## Related

- `VERSIONING.md` -- what each number means
- `CHANGELOG.md` -- what changed
- `DOCS/INSTALL.md` -- what the customer does with the zip

# DupCleaner - Product Requirements Document (PRD)

**Product:** DupCleaner - Windows duplicate file and folder finder with deletion-safety intelligence
**Version:** 2.0
**Platform:** Windows 10 / Windows 11 (Windows PowerShell 5.1 + WinForms; optional single-file `DupCleaner.exe` host)
**Status:** Version 2.0. Modules 1, 4 and 5 are built. Modules 2 and 3 have a first working version (see Part C for exactly what is and is not covered).
**Repository:** https://github.com/Had-com/DupCleaner

## Contents

- Part A - Product overview, principles, module map, and requirements for the scanner (Module 1), processing and removal (Module 4) and user experience (Module 5)
- Part B - Deletion Safety Intelligence: investigation (Module 2) and safety assessment (Module 3)
- Part C - Implementation status, known gaps, and verification

---

# Part A - Product

## A1. Overview

### A1.1 Purpose

Disks fill up with copies: photo backups, "Copy of" folders, old report versions, installers downloaded twice. DupCleaner finds duplicate **files and folders by their real contents** (SHA-256, never by name), shows them while the scan runs, and lets the user remove extra copies **safely** - with the evidence, an undo, and a warning when a folder looks like it might still be needed.

### A1.2 Target users

| User | Need |
| --- | --- |
| Home user with a full disk | Free space quickly without breaking anything; plain-language explanations |
| Photographer / power user with many backups | Find identical folders across drives, keep one, undo mistakes |
| Technical user | See the evidence, control the removal method, repeat scans fast |

### A1.3 Product principles

1. **Safe by default.** The default removal is a move to a quarantine folder that can be undone.
2. **Nothing without a confirmation.** No automatic deletion, renaming, or application/service termination.
3. **Content, not names.** Identity is decided by SHA-256 of contents.
4. **Identical content does not mean interchangeable purpose.** Each copy is judged on its own (Part B).
5. **Show the evidence.** Every score and recommendation can be traced to recorded findings.
6. **Local and private.** No network access, no telemetry.
7. **Fast to come back to.** Hash cache, saved session, and remembered layout.

### A1.4 Non-goals

Uninstalling applications, editing application configuration, deleting Windows system files, replacing antivirus or Windows security, cloud services, and any guarantee that an application will never need a folder again.

## A2. Module map

| # | Module | Purpose | Status |
| --- | --- | --- | --- |
| 1 | Scanner | Find duplicate files and folders by SHA-256, with live results | Built |
| 2 | Safety investigation | Collect read-only evidence about each candidate folder | First version (Part C) |
| 3 | Safety assessment | Per-folder deletion-safety %, assessment confidence, classification, explanation | First version (Part C) |
| 4 | Processing and removal | Review, mark, apply (quarantine / Recycle Bin / permanent), undo, force delete | Built |
| 5 | User experience | Tabs, layout, preview, settings, themes | Built |

## A3. Module 1 - Scanner requirements

| ID | Requirement |
| --- | --- |
| S-1 | The user can add folders to scan by the Add folder button or by dragging folders onto the list, and can remove them. |
| S-2 | Duplicate files and duplicate folders are searched in one scan; each can be turned off. |
| S-3 | Files are grouped by size and then compared by SHA-256 of their contents; folders are compared by the hashes of everything inside them. |
| S-4 | Results appear live while the scan runs, with progress, an ETA, elapsed time, and Pause / Cancel. |
| S-5 | A persistent fingerprint cache keeps a hash only while the file's size and modified time still match; it can be turned off. |
| S-6 | Hard-linked copies of the same data are collapsed instead of being reported as duplicates. |
| S-7 | Links, junctions and reparse points are never followed. OneDrive online-only files and system / package locations can be skipped (on by default). |
| S-8 | Files below a configurable minimum size are ignored. |
| S-9 | Sub-folder sets that exist inside duplicate folders are recognised. |
| S-10 | The last results and the scan roots are saved and restored on the next start; result lists can be saved and restored. |
| S-11 | A finished scan opens the results tab that has duplicates (folders first when both exist). |

## A4. Module 4 - Processing and removal requirements

| ID | Requirement |
| --- | --- |
| P-1 | Duplicate files and duplicate folders have separate tabs. The Duplicate folders view lists sets on the left, the copies of the chosen set in the middle, and an INSIDE panel with a preview on the right. |
| P-2 | Files can be filtered by name or path, type and modified date (including a custom range); sets can be searched by path and sorted (space freed, name, number of copies, date). |
| P-3 | One copy per set is kept automatically (the oldest); the user can tick **Delete this copy**, press **Keep only this one**, **Reset to auto rule**, **Keep selected**, or **Select EVERY copy (keep none)**, which shows an explicit warning. |
| P-4 | **Apply** and **Delete now** use the action chosen in Settings: move to the quarantine folder (undoable), send to the Recycle Bin, or delete permanently. Each asks for confirmation; permanent delete asks twice. |
| P-5 | **Undo a move** restores quarantined items from their manifest; **Restore list** reloads a saved list. |
| P-6 | **Verify duplicates** re-checks the chosen copies before deleting. |
| P-7 | **Force delete** (Settings) clears read-only/hidden/system flags and uses long-path deletion; the result says whether a folder is held by another program or blocked by permissions, and a partially copied quarantine item is never touched. |
| P-8 | A copy that is already gone from disk is dropped as stale instead of failing; copies on a disk that is not connected are never dropped. |
| P-9 | A **Space saved** donut (saved so far vs. still can be freed) is shown whenever no file is selected; the total is kept between runs and reduced when a move is undone. |
| P-10 | Removal logs are written (last run, last undo) and shown when something fails. |

## A5. Module 5 - User experience requirements

| ID | Requirement |
| --- | --- |
| U-1 | Three main tabs: **1 Scanning**, **2 Processing**, **3 Settings**. A finished scan opens Processing, and Processing opens on the sub-tab with results. |
| U-2 | A dark, rounded interface that follows the Windows light/dark setting; list text size A- / A+ and Ctrl + mouse wheel. |
| U-3 | Every inner pane can be resized with a dividing bar, and the Settings cards can be reordered by dragging their title; the layout is remembered and **Reset layout** restores the default. The bottom action section is shorter, with Apply / Undo / Restore on the same row as the left buttons and a draggable divider. |
| U-4 | The INSIDE panel shows Name / Size / Modified columns like Explorer, with user-resizable columns, and previews pictures, text, PDF, audio/video and folders. |
| U-5 | **Deselect on outside click:** when a file is selected in the INSIDE panel, a click anywhere outside that panel unselects it and clears its preview (the preview pane returns to the Space saved donut). Clicks inside the panel, on the preview buttons (Open, Show in Explorer, Bigger preview) and in menus or other windows do not count as outside. Deselecting never changes what is marked for removal. |
| U-6 | **Open files with:** a Settings card chooses the program used by Open, double-click and right-click Open - for all files and optionally per type (pictures, videos, music, documents, text and data). The default is the Windows default. A missing or failing program shows a message and falls back to the Windows default for that open. The path is passed as one quoted argument. The choice is saved. |
| U-7 | Keyboard: F2 / F3 preview, Delete and Enter behave as in the lists; right-click menus offer Open, Open with..., Preview and Show in Explorer. |
| U-8 | The window and taskbar icon (overlapping green-tick and red-cross folders) is built into the exe. |
| U-9 | The app can be run as `DupCleaner.cmd` (script) or as a single `DupCleaner.exe` built by `Build-Exe.ps1` with the C# compiler that ships with Windows. |

---

# Part B - Deletion Safety Intelligence

The specification below is the full target. Part C records what the first version does.

## B1. Product Overview

### B1.1 Purpose

Build an intelligent safety investigation engine that analyzes duplicate folders discovered by the existing scanner and determines whether each individual folder can be safely deleted.

The engine must investigate the relationship between duplicate folders, their associated applications, Windows dependencies, runtime usage, configuration references, and data ownership.

It must produce an understandable safety assessment percentage for every candidate folder, accompanied by:

- A safety classification.
- Evidence supporting the assessment.
- Identified risks.
- Missing information.
- Recommended action.
- Potential disk space recovery.
- A confidence level in the assessment itself.

The system must prioritize data integrity and application stability over disk space recovery.

### B1.2 Core principle

**Identical content does not mean interchangeable purpose.**

Two folders may contain precisely the same files while serving completely different applications, profiles, environments, or runtime contexts.

The system must evaluate each folder independently rather than assuming that one copy is unnecessary.

Example: a Chromium extension exists in Google Chrome's extension directory, in Brave's extension directory, and in an application's embedded Chromium profile. Even if all three copies have identical SHA-256 hashes, all three may be necessary.

---

## B2. Goals and Non-Goals

### B2.1 Goals

1. Determine whether a folder is actively used.
2. Identify applications associated with each folder.
3. Discover references to folders from applications, services, configurations, shortcuts, tasks, and registry entries.
4. Identify application-specific storage and cache conventions.
5. Detect shared dependencies and independently maintained copies.
6. Identify folders that are safe to remove, potentially removable, or must be retained.
7. Calculate a transparent safety assessment percentage.
8. Explain every assessment in human-readable language.
9. Prevent deletion when critical dependencies or uncertainties exist.
10. Provide evidence that can be reviewed before any cleanup operation.

### B2.2 Non-Goals

This module is not responsible for:

- Finding duplicate folders (handled by Module 1).
- Automatically deciding that identical files are redundant.
- Removing application dependencies.
- Uninstalling applications.
- Modifying application configurations to redirect paths.
- Deleting Windows system files.
- Guaranteeing that an application will never need a folder again.
- Replacing Windows security or antivirus functionality.

---

## B3. Core Concepts

The system must distinguish three different concepts.

### B3.1 Content similarity

How similar are two folders? Example: 100% identical file contents.

### B3.2 Deletion safety

How safe is deleting one specific folder while retaining the others? Example: Folder A: 98% estimated deletion safety. Folder B: 15% estimated deletion safety.

### B3.3 Assessment confidence

How reliable is the evidence used to calculate the safety assessment? Example: Safety assessment 98%, assessment confidence 94%.

These metrics must never be combined or presented as interchangeable.

A high similarity score must never automatically increase the deletion safety score.

---

## B4. Safety Investigation Engine

The engine must collect evidence from multiple independent sources.

### B4.1 Process and runtime investigation

Determine whether running processes use, reference, or access the candidate directory.

Investigations:

- Process executable paths.
- Process command-line arguments.
- Parent and child process relationships.
- Open file handles, where accessible.
- Loaded modules and application processes.
- Background services.
- Windows scheduled tasks.
- Application processes with access to the relevant directory.
- Recent file access evidence, when available.

Requirements:

- Identify processes associated with the folder.
- Identify the executable and application owner.
- Distinguish direct references from indirect associations.
- Record inaccessible process information.
- Never interpret missing command-line references as proof that a folder is unused.

Important: a process may access a folder without including its path in its command line. A folder may also be needed only when an application starts again.

### B4.2 Application ownership investigation

Identify which applications own, maintain, or depend on the folder.

Investigate:

- Windows installed applications.
- Microsoft Store applications.
- WindowsApps package directories.
- Application installation directories.
- Application data directories.
- LocalAppData.
- Roaming AppData.
- ProgramData.
- Browser profiles.
- Application caches.
- Extension directories.
- User profiles.
- Portable applications.

Identify the application using:

- Package identity.
- Application manifests.
- Executable metadata.
- File signatures.
- Installation records.
- Configuration references.
- Directory naming conventions.
- Known application-specific folder structures.

Output application ownership as one of: Confirmed, Probable, Unknown, Shared ownership.

Multiple applications may own separate copies of identical data.

### B4.3 Static dependency investigation

Search for references to the candidate folder in relevant files.

Potential sources:

- JSON, XML, INI and YAML configuration files.
- Application manifests.
- Shortcut targets.
- PowerShell scripts and batch files.
- Application launch configurations.
- Registry entries.
- Service configurations.
- Scheduled task definitions.
- Browser extension manifests.
- Application-specific databases.

Requirements:

- Identify references to the full directory path.
- Identify references to parent directories.
- Identify references to application-specific identifiers.
- Distinguish active references from historical references.
- Record the source file and exact location of every discovered reference.

Do not modify configuration files during investigation. Do not execute discovered scripts or configuration contents.

### B4.4 Windows registry investigation

Investigate relevant registry locations for folder references.

Potential sources:

- Installed application records.
- Application-specific configuration keys.
- Uninstall information.
- User-specific application settings.
- Shell folder references.
- Application startup registrations.
- File associations.
- App package registrations.

Requirements:

- Use read-only registry access.
- Record registry key and value names.
- Record matching paths.
- Identify whether the reference appears active, historical, or uncertain.
- Do not interpret every registry reference as an active dependency.

### B4.5 File and directory relationship investigation

Analyze the relationship between candidate folders.

Investigations:

- SHA-256 file hashes.
- Relative file paths.
- File sizes.
- File timestamps.
- Directory structure.
- Version numbers.
- File metadata.
- Manifest identifiers.
- Configuration differences.
- Hidden files.
- Junctions, symbolic links, hard links and reparse points.

Classify relationships:

1. Exact duplicate.
2. Same files, different directory structure.
3. Same application, different versions.
4. Partial duplicate.
5. Shared files, different application purposes.
6. Independent copies.
7. Unknown relationship.

Important: a hard link or symbolic link must not be treated as an ordinary independent copy. The system must inspect the underlying filesystem relationship before calculating recoverable space.

### B4.6 Cache and temporary-data investigation

Identify whether a candidate folder appears to be:

- Temporary application data.
- Rebuildable cache.
- Browser cache.
- Application download cache.
- Extension installation cache.
- Persistent application storage.
- User-generated data.
- Application state.
- Database storage.
- Update package.
- Installer data.
- Backup data.

A folder name containing "cache", "temp", or "backup" is not sufficient evidence that deletion is safe.

The engine must identify the owning application and determine whether the data is reconstructible.

### B4.7 Version and lifecycle investigation

Identify:

- Application version.
- Folder version.
- Extension version.
- Installed version.
- Potentially obsolete versions.
- Update-related directories.
- Currently registered versions.
- Previous versions retained for rollback.

The engine must not assume that older versions are unnecessary. An older version may be required for recovery, rollback, or application compatibility.

---

## B5. Evidence Collection and Storage

Every investigation must produce a structured evidence record.

| Field | Description |
| --- | --- |
| Evidence ID | Unique identifier |
| Candidate folder | Folder being assessed |
| Evidence category | Runtime, ownership, registry, etc. |
| Evidence source | Exact source of observation |
| Finding | What was discovered |
| Result | Positive, negative, or unknown |
| Timestamp | When it was collected |
| Reliability | Evidence reliability |
| Impact | Effect on deletion safety |
| Explanation | Human-readable interpretation |

Evidence must be timestamped and associated with the relevant scan session.

The engine must distinguish:

- **Positive evidence:** a dependency was discovered.
- **Negative evidence:** a specific investigation found no dependency.
- **Unknown evidence:** the investigation could not establish the answer.

An inaccessible source must never be silently interpreted as a negative result.

---

## B6. Safety Assessment Percentage Engine

### B6.1 Main requirement

Every candidate folder must receive a deletion safety percentage between 0% and 100%.

The percentage represents the engine's estimated confidence that deleting this particular folder will not cause data loss, application malfunction, or disruption to dependent software.

It is not a statistical guarantee. It must be evidence-based, explainable, and conservative.

### B6.2 Assessment dimensions

Use a weighted scoring model.

| Assessment dimension | Weight |
| --- | --- |
| Runtime dependency investigation | 20% |
| Application ownership and dependency investigation | 20% |
| Configuration and registry references | 15% |
| Data classification and reconstructibility | 15% |
| Duplicate equivalence and replacement verification | 15% |
| Version and lifecycle analysis | 10% |
| Filesystem relationship and deletion integrity | 5% |
| **Total** | **100%** |

Each dimension receives an evidence-based score from 0 to 100. A score of 100 means the available evidence strongly supports safe removal in that dimension. A score of 0 means the evidence strongly indicates that deletion is unsafe.

An unknown dimension must not receive 100 simply because no problem was discovered.

### B6.3 Calculation

Safety Score = Sum of (Dimension Score x Dimension Weight).

Example:

| Dimension | Score | Weight |
| --- | --- | --- |
| Runtime | 100 | 20% |
| Ownership | 90 | 20% |
| Configuration | 100 | 15% |
| Data classification | 95 | 15% |
| Duplicate verification | 100 | 15% |
| Lifecycle | 80 | 10% |
| Filesystem | 100 | 5% |

Calculated score: 93.25%.

The final score must also apply safety overrides and uncertainty penalties.

### B6.4 Mandatory safety overrides

Certain findings must override the weighted score.

| Finding | Maximum safety score |
| --- | --- |
| Confirmed active application dependency | 10% |
| Confirmed active service dependency | 10% |
| Confirmed required application data | 5% |
| Candidate contains unique user data without a verified backup | 20% |
| Required database or application state | 10% |
| Filesystem relationship cannot be safely resolved | 30% |
| Critical investigation sources inaccessible | 60% |

The most restrictive applicable override wins. These are conservative policy caps, not measured probabilities. The system must support additional override rules.

### B6.5 Missing evidence penalties

Missing information must lower assessment confidence and may lower the safety score.

Examples:

- Unable to inspect running file handles.
- Unable to identify folder ownership.
- Access denied to relevant registry locations.
- Unknown application-specific directory.
- Incomplete filesystem analysis.
- Unknown backup status.
- Inability to establish whether another copy is independently maintained.

The system must distinguish between evidence of danger, absence of evidence, and missing evidence. These are three different conditions.

---

## B7. Safety Classification

| Percentage | Classification | Recommended action |
| --- | --- | --- |
| 95-100% | Very likely safe | Eligible for controlled cleanup after confirmation |
| 85-94% | Likely safe | Review evidence before cleanup |
| 65-84% | Uncertain | Investigate further |
| 35-64% | High risk | Keep unless additional evidence resolves concerns |
| 0-34% | Unsafe | Do not delete |

Mandatory overrides always take precedence over percentage classifications. A folder with a raw calculated score of 98% but a confirmed active dependency must not be classified as safe; it must receive the relevant override and an explicit explanation.

### B7.1 Separate assessment confidence

Each result must also display an assessment confidence percentage, measuring how complete and reliable the investigation was.

- 90-100%: Strong evidence coverage.
- 75-89%: Good evidence coverage.
- 50-74%: Limited evidence coverage.
- 0-49%: Insufficient evidence.

The confidence calculation must reflect source coverage, reliability, freshness, and consistency. It must not simply repeat the safety score.

---

## B8. Candidate Folder Evaluation

Every folder must be assessed individually. A duplicate group must not receive a single shared safety score.

Example: three folders contain identical files.

| Candidate | Safety score | Assessment |
| --- | --- | --- |
| Chrome extension | 12% | Unsafe |
| Brave extension | 12% | Unsafe |
| Application extension copy | 18% | Unsafe |

Even though all three copies are identical, all may be required.

Another example: two copies of an application-generated temporary export exist.

| Candidate | Safety score | Assessment |
| --- | --- | --- |
| Temporary export A | 97% | Very likely safe |
| Temporary export B | 18% | Unsafe |

The difference must be supported by evidence, not arbitrary selection.

---

## B9. User-Facing Assessment Report

Each candidate folder must have a detailed report.

**Folder identification:** full path, folder size, number of files, number of subdirectories, last modified date, application association, duplicate group ID.

**Safety assessment:** deletion safety percentage, classification, assessment confidence, investigation completion status.

**Evidence:** confirmed dependencies, potential dependencies, negative findings, unknown findings, related applications, relevant processes, configuration references, registry references.

**Risks:** potential application failure, user-data loss, profile corruption, update or rollback failure, shared-data disruption.

**Recommendation**, one of: Keep; Keep and investigate; Eligible for controlled cleanup; Eligible for backup and cleanup testing; Not enough information to decide.

**Potential disk recovery:** apparent folder size, estimated unique physical storage, estimated recoverable storage, space shared through hard links or other filesystem mechanisms.

---

## B10. Explanation Engine

Every score must have a human-readable explanation, for low scores and for high scores.

Example (low):

**Safety assessment: 18% - Unsafe**

Why:

- This folder belongs to a registered browser profile.
- Its application-specific extension directory is present.
- The same extension exists in other browser environments.
- Identical contents do not establish interchangeable ownership.
- The application may require this copy during startup.

Recommendation: Keep this folder.

Example (high):

**Safety assessment: 97% - Very likely safe**

Why:

- The candidate is a verified temporary export.
- An identical verified copy exists at another location.
- No unique files were discovered.
- No relevant application dependencies were found in the investigated sources.
- No filesystem links were detected.
- No critical investigation failures were reported.

Recommendation: Eligible for controlled cleanup after user confirmation.

The explanation engine must not invent evidence or make unsupported claims.

---

## B11. User Interface Requirements

### B11.1 Duplicate group overview

Display: duplicate group name, number of copies, total apparent storage, estimated recoverable storage, number of safe, uncertain and unsafe candidates.

### B11.2 Candidate comparison

Display every folder in the group separately.

| Column | Purpose |
| --- | --- |
| Folder path | Full location |
| Application | Associated application |
| Size | Folder size |
| Similarity | Content comparison |
| Safety | Deletion safety percentage |
| Confidence | Evidence confidence |
| Status | Safety classification |
| Recommendation | Suggested action |

### B11.3 Detailed investigation view

Selecting a candidate opens: safety score breakdown, evidence collected, application relationships, dependency findings, risk explanations, missing information, investigation timestamps.

### B11.4 Filtering

Users must be able to filter by: very likely safe, likely safe, uncertain, high risk, unsafe, application-associated folders, non-application folders, unknown ownership, high storage recovery, low assessment confidence.

#### Two percentages, shown side by side

Deletion safety and assessment confidence must be visible next to each other, for example:

- **Deletion safety: 97%** - Very likely safe - estimated safety of deleting this particular folder.
- **Assessment confidence: 68%** - Limited evidence - how complete and reliable the investigation is.

(Illustrative values only.) A folder with 97% safety but only 68% assessment confidence must not be presented as a straightforward deletion recommendation; it should require further investigation.

---

### B11.5 File selection and preview behavior

- **Deselect on outside click:** if a file is selected in the files panel (the INSIDE list), clicking anywhere outside that panel unselects it, and the preview pane no longer shows that file. The preview area returns to its empty state (the Space saved donut).
- Clicking another file inside the panel selects that file and shows its preview as before.
- Clicking a control that acts on the selected file (Open, Show in Explorer, Bigger preview, Preview F3) must not count as an "outside" click, so those actions keep working on the current selection.
- Deselecting must never change what is checked for removal; selection is for viewing only.

### B11.6 Preview opening software

- Add a setting (in Settings) to choose which program opens a file when the user presses **Open** or double-clicks it, instead of always using the Windows default.
- Options: **Windows default** (initial value), or **Choose program...** with a file picker for an .exe; the chosen program and its path are shown and can be reset to default.
- Optionally allow a different program per file type (for example images, documents, video); a type with no override uses the global choice, then the Windows default.
- If the chosen program no longer exists or fails to start, show a clear message and fall back to the Windows default for that open.
- The program is launched with the file path as a single, safely quoted argument; no shell interpretation of the path.
- The choice is saved with the other settings and restored on start.

---

## B12. Investigation Workflow

1. Receive candidate folders from the existing scanner.
2. Normalize folder paths.
3. Identify filesystem links and ownership.
4. Investigate running processes and services.
5. Investigate application ownership.
6. Inspect configuration and registry references.
7. Classify data and reconstructibility.
8. Verify duplicate equivalence.
9. Analyze version and lifecycle relationships.
10. Calculate dimension scores.
11. Apply mandatory safety overrides.
12. Calculate the final safety score.
13. Calculate assessment confidence.
14. Assign classification.
15. Generate explanation and recommendation.
16. Save the investigation report.

Investigation is read-only. The engine must never delete, rename, move, or modify candidate folders during this process.

---

## B13. Technical Requirements

### B13.1 Architecture

Separate the functionality into independent components:

- Dependency Investigation Engine.
- Application Ownership Detector.
- Runtime Analysis Engine.
- Configuration Reference Analyzer.
- Registry Analyzer.
- Filesystem Relationship Analyzer.
- Data Classification Engine.
- Safety Scoring Engine.
- Confidence Scoring Engine.
- Explanation Generator.
- Report Generator.

Each component must return structured evidence. The scoring engine must not rely on free-form AI conclusions.

### B13.2 Deterministic assessment

The same evidence, scoring rules, and policy version must produce the same assessment. The scoring engine is **rule-based and deterministic, not AI-based**: safety decisions are governed by auditable rules, evidence and mandatory protection overrides.

AI may assist with interpreting unfamiliar application structures, explaining technical findings, and suggesting additional investigation steps.

AI must not: override hard safety rules, invent dependency evidence, convert unknown findings into safe findings, authorize deletion independently, or change the deterministic score without recorded evidence.

### B13.3 Permissions

The application must:

- Run without administrator privileges when possible.
- Clearly identify inaccessible sources.
- Request elevated permissions only when needed.
- Never bypass Windows access controls.
- Avoid scanning sensitive user information unnecessarily.
- Store investigation reports securely.

### B13.4 Performance

- Reuse hashes from the existing scanner.
- Avoid recalculating unchanged file hashes.
- Cache application ownership information.
- Support cancellation.
- Support resuming interrupted investigations.
- Show investigation progress.
- Avoid excessive disk activity.
- Avoid interfering with running applications.

---

## B14. Safety and Security Requirements

The system must adopt a fail-safe approach. Mandatory rules:

1. No automatic deletion.
2. No automatic renaming.
3. No automatic application termination.
4. No automatic service termination.
5. No modification of application configuration.
6. No deletion of Windows system directories.
7. No deletion of active application data.
8. No deletion based solely on identical hashes.
9. No deletion based solely on lack of running process references.
10. No safe classification when critical dependencies remain unresolved.

The engine must also detect: junctions and symbolic links, protected Windows directories, application package directories, shared profile directories, active database files, user-generated documents, cloud synchronization directories, backup and recovery directories.

---

## B15. Acceptance Criteria

#### Assessment accuracy

- [ ] Every candidate receives an individual safety score.
- [ ] Every candidate receives an assessment confidence score.
- [ ] Similarity and deletion safety are separate metrics.
- [ ] All score calculations are reproducible.
- [ ] Every score has an explanation.
- [ ] All missing evidence is explicitly reported.
- [ ] Mandatory overrides always take precedence.

#### Dependency investigation

- [ ] Running processes are investigated.
- [ ] Relevant Windows services are investigated.
- [ ] Application ownership is investigated.
- [ ] Configuration references are investigated.
- [ ] Relevant registry references are investigated.
- [ ] Filesystem relationships are investigated.
- [ ] Cache and persistent data are distinguished.
- [ ] Application version relationships are investigated.

#### Safety

- [ ] No folder is modified during investigation.
- [ ] Unknown dependencies cannot be classified as safe by default.
- [ ] Identical application folders are not automatically considered interchangeable.
- [ ] Active dependencies result in an unsafe classification.
- [ ] User data receives appropriate protection.
- [ ] Inaccessible evidence sources are disclosed.

#### User experience

- [ ] Duplicate groups can be reviewed individually.
- [ ] Each candidate has a detailed report.
- [ ] Users can understand why a folder received its score.
- [ ] Users can distinguish safety from assessment confidence.
- [ ] Users can filter and sort results.
- [ ] Clicking outside the files panel unselects the selected file and clears its preview.
- [ ] Actions on the selected file (Open, Show in Explorer, Bigger preview) still work after clicking their buttons.
- [ ] Users can set the program used to open files, reset it to the Windows default, and the choice persists.
- [ ] A missing or failing chosen program falls back to the Windows default with a clear message.

---

## B16. Testing Scenarios

| Scenario | Expected behavior |
| --- | --- |
| Identical Chrome and Brave extensions | Keep both |
| Identical copies in separate application profiles | Investigate independently |
| Verified temporary files with no dependencies | Potentially safe |
| Duplicate personal documents | Require backup and ownership verification |
| Old application version | Investigate rollback and lifecycle |
| Active application database | Unsafe |
| Application cache with documented regeneration | Potentially safe |
| Folder referenced by Windows service | Unsafe |
| Folder with inaccessible ownership information | Uncertain |
| Identical folder containing unique metadata | Investigate metadata |
| Junction pointing to another directory | Protect filesystem integrity |
| Folder not referenced by running processes | Do not assume safe |
| Application installation folder | Protect by default |

Testing must include both positive and negative cases.

---

## B17. Final Product Success Metrics

- Percentage of folders receiving complete investigations.
- Percentage of assessments with sufficient evidence.
- Percentage of recommendations supported by recorded evidence.
- Number of false-safe classifications.
- Number of false-unsafe classifications.
- Number of unresolved dependency cases.
- Average investigation time.
- Estimated recoverable disk space.
- User acceptance of explanations.

The most important metric: **false-safe classification rate is zero in the validated safety test suite.**

The system must prioritize preventing destructive mistakes over maximizing the amount of space recovered.

---

## B18. Final Product Definition

The finished feature is an evidence-driven Windows folder deletion safety intelligence system.

It must answer five questions for every duplicate folder:

1. What is this folder?
2. Which applications or Windows components depend on it?
3. What would potentially happen if it were deleted?
4. How safe is deletion, expressed as a percentage?
5. How reliable is the evidence supporting that percentage?

The final result must be understandable to a non-technical Windows user while retaining sufficient technical evidence for advanced users.

**Product philosophy: Never recommend deleting a folder simply because another copy exists. Recommend deletion only when the specific candidate has been independently investigated and the available evidence supports that decision.**

---

# Part C - Implementation status, gaps and verification

## C1. Status of the safety modules (version 2.0)

| Spec section | Status | What the first version does |
| --- | --- | --- |
| B3 Three separate measures | Done | Similarity (100% for scanner sets), deletion safety, and assessment confidence are separate fields, shown side by side. |
| B4.1 Runtime | Partly | Process list (path and command line), Windows services, scheduled tasks, and an exclusive-open test on up to 40 sample files. Open file handles cannot be listed without extra tools and are reported as **Unknown**. |
| B4.2 Ownership | Partly | By location (Windows, Program Files, WindowsApps, AppData, user folders), registered install locations (Uninstall keys), and folder markers (manifest.json, package.json, .git, exe/dll). Result: Confirmed / Probable / Unknown. Shared ownership is detected when another copy belongs to a different application. No catalog of known application layouts yet. |
| B4.3 Static dependencies | Partly | Read-only search of up to 150 small config files next to the folder, and Start Menu / Desktop / Startup shortcuts. Nothing is executed or modified. Application databases are not searched. |
| B4.4 Registry | Partly | Read-only: Uninstall keys, Run / RunOnce, App Paths, User Shell Folders, service image paths. Active vs. historical is distinguished (installer-source paths are historical). App package registrations and file associations are not inspected and are reported as Unknown. |
| B4.5 Filesystem relationships | Partly | Junctions and symbolic links (not followed), hard links (sampled), hidden files, structure re-check against a kept copy, nested copies. The seven relationship classes are not all labelled separately. |
| B4.6 Cache / temporary data | Partly | Detects rebuildable caches (only when an owning application is found), application state and databases, user documents/media, backups, installer/update packages. A name like "cache" alone is not trusted. |
| B4.7 Version / lifecycle | Partly | Version numbers in folder names, newer sibling versions, update/rollback folder names. |
| B5 Evidence records | Done | Each record has ID, category, source, finding, result (Positive / Negative / Unknown), timestamp, reliability, impact, explanation. Unknown is never treated as safe. |
| B6 Scoring | Done | The seven weighted dimensions (20/20/15/15/15/10/5), a missing-evidence penalty beyond two standing gaps, and mandatory caps: protected Windows folder 2, installation folder 5, active dependency 10, required database/state 10, last remaining copy 10, unique user data without a kept copy 20, independently owned copy 25, unresolved filesystem link 30, cloud-sync folder 60, critical source inaccessible 60. The most restrictive cap wins. |
| B7 Classification and confidence | Done | Five classes by percentage; confidence from evidence reliability and coverage, freshness and consistency; a safe-looking score with confidence below 75 becomes "Keep and investigate". |
| B8 Per-candidate assessment | Done | Every copy is assessed alone, for the current marks (changing the marks invalidates and re-runs the assessment). |
| B9 Report | Done | Folder facts, score, classification, confidence, evidence, risks, missing information, recommendation, and apparent / unique / recoverable space (hard-link aware). Saved to `%LOCALAPPDATA%\DupCleaner\safety-reports.json` and exportable as text. |
| B10 Explanation engine | Done | Explanations are assembled only from recorded evidence; no AI is used and none can change a score. |
| B11 UI | Mostly | Group overview line, per-copy safety text on each card, a **Safety review...** window with the comparison table, score breakdown (including penalties and caps) and the full report, and a filter by class or "Not assessed yet". Not yet: filters for application-associated / unknown ownership / high recovery / low confidence. |
| B12 Workflow | Mostly | Read-only investigation, then scoring, overrides, confidence, classification, explanation, saved report. Cancellation is only available for "Investigate all listed sets" (Esc); interrupted investigations are not resumed. |
| B13 Technical | Mostly | Deterministic rules, shared system snapshot cached for five minutes, scanner hashes reused, runs without administrator rights. No separate processes per component. |
| B14 Safety rules | Done | No automatic deletion, renaming, or termination; Apply and Delete now warn when a copy to be removed was assessed below 65%. |

## C1a. What version 2.0 adds

| Area | Change |
| --- | --- |
| Two scores per set | **Safe to keep only one** (0-100%): how safe it is to delete the extra copies and live with the best remaining one. It does not depend on what is ticked; it is the weakest deleted copy under the best choice of copy to keep. **Risk if you delete all copies** (Low / Moderate / High / Very high): what would be lost if every copy went; user documents and media are always high. Both are shown on the set line, with the reason for the risk. |
| Score colours | List and chart colours: above 90% green, 80-90% orange, below 80% red. |
| Better spread of scores | Personal duplicates no longer all land on 97%: the score considers whether the kept copy is on the same drive, how recently the folder changed, whether it holds scripts / settings / program files, and whether the kept copy sits in a cloud-sync folder (OneDrive, Dropbox, Google Drive, MEGAsync). |
| Automatic investigation | After a scan every duplicate-folder set is scored in the background, the set that frees the most space first (about 0.3 s per set). Esc stops it. Per-copy detail is computed when a set is opened. |
| Safe default | A set that scores below 80% starts with every copy on KEEP (judged once per set, remembered in `safety-judged2.txt`); ticking copies for deletion stays possible. |
| Sorting | "Largest and safest" order and a total score column in the list; the list is re-ordered at most every 2.5 s and only when the order changed, so it does not flicker while scores arrive. |
| Preview donut | When nothing is selected the donut shows space saved so far plus the space still to free, split into the three score colours and "not yet scored". |
| Error log | Errors the program handles quietly are written to `%LOCALAPPDATA%\DupCleaner\errors.log` (time, line, message, and how many times; logged at 1, 10, 100, 1000... occurrences, capped at 5 MB). It found a real fault: quoted install paths from the registry made `GetFullPath` fail thousands of times; paths are now cleaned and remembered. |
| Performance | Folder facts, the system snapshot search index, parent-folder config scans and path normalisation are cached; scoring one set went from about 3 s to about 0.3 s. |
| Privacy | The documentation screenshots use a made-up demo folder; the program writes nothing outside `%LOCALAPPDATA%\DupCleaner` and makes no network connections. |

## C2. Known gaps and next steps

1. Open file handles and AppX/MSIX package registrations are not inspected; they are shown as Unknown evidence and lower confidence.
2. Application-specific storage knowledge (Chrome, Brave, Edge, Office, game launchers) is limited to location rules; a catalog of known layouts would raise accuracy.
3. Remaining filters from B11.4 (application-associated, non-application, unknown ownership, high storage recovery, low confidence).
4. Resume of interrupted investigations and a progress bar for the single-set assessment.
5. A validated safety test suite that measures false-safe and false-unsafe rates (B17); the current checks are the scenario tests listed below.
6. The Settings page keeps the new "Open files with" card at the bottom; very small windows need to scroll to it.

## C3. Verification performed (versions 1.1 and 2.0)

All tests ran on a copy of the program with an isolated data folder and made-up files, never on real data.

| Area | Check | Result |
| --- | --- | --- |
| Outside click | Click inside the files panel, on the preview buttons, and outside it (direct call and a real posted mouse message) | Selection kept / kept / cleared; preview cleared |
| Open with | Per-type categories, JSON save and reload, launch of the chosen program, label per category | Pass |
| Safety: identical Chrome and Brave extension copies | Different owners | 25% Unsafe, "Independently owned copy" cap |
| Safety: running program in the folder | A running copy of a console program | 10% Unsafe, active dependency |
| Safety: Windows folder / Program Files | Protected location | 2% / 5% |
| Safety: last remaining copy | All other copies marked | 10% |
| Safety: verified temporary export | Plain folder, no references | Uncertain (about 76%), not "safe", because ownership is unknown |
| Safety: marks change | Toggle a copy's mark | Assessment invalidated and re-run |
| Safety: filters, review window, assess all, saved report | | Pass |
| Two scores (v2.0) | Photo pairs, program folders, caches, browser extensions and 45 real sets on a copy of the program | Photo pair about 93% keep-one with Very high delete-all risk; program folders 5%; caches about 76% with Low risk; Chrome / Brave extensions 25% |
| Speed (v2.0) | Timing of 12 sets before and after caching | about 3 s to 0.3 s per set, identical scores |
| Error log (v2.0) | Run the app and read `errors.log` | Found and fixed the repeated GetFullPath fault; none logged after the fix |
| Removal protection | Risky removals produce a warning before Apply / Delete now | Implemented; confirmation dialog not automated |
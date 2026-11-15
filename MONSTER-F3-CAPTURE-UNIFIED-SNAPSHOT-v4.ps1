#requires -Version 5.1
<#
MONSTER F3 — unified read-only snapshot collector v4

READ-ONLY GUARANTEE:
- Reads project source, Git status/diffs/index and known backup files.
- Writes only a new timestamped folder and ZIP under the user's Downloads folder.
- Does NOT stage, reset, checkout, clean, commit, alter source files, run tests,
  connect to PostgreSQL, or stop/restart any service.

Designed for Windows PowerShell 5.1.
#>

$ErrorActionPreference = 'Stop'

$Project = 'C:\Users\home\MONSTER-AI-COMMAND-CENTER\frontend'
$Downloads = Join-Path $env:USERPROFILE 'Downloads'
$BackupRoot = 'C:\Users\home\MONSTER-AI-BACKUPS'
$WorkspaceRoot = Join-Path $Project 'workspace'

if (-not (Test-Path -LiteralPath $Project -PathType Container)) {
    throw "Project folder not found: $Project. Nothing was changed."
}
if (-not (Test-Path -LiteralPath (Join-Path $Project '.git'))) {
    throw 'Project .git entry not found. Nothing was changed.'
}
if (-not (Test-Path -LiteralPath $WorkspaceRoot -PathType Container)) {
    throw "Project workspace folder not found: $WorkspaceRoot. Snapshot aborted; no project files were changed."
}
if (-not (Test-Path -LiteralPath $Downloads -PathType Container)) {
    throw "Downloads folder not found: $Downloads. Nothing was changed."
}

$GitCommand = Get-Command git.exe -ErrorAction Stop
$GitExe = $GitCommand.Source
if (-not $GitExe) { $GitExe = $GitCommand.Path }
if (-not $GitExe) { throw 'Could not resolve git.exe. Nothing was changed.' }

# Git commands inherit this variable. Resolve the same index file that Git will use.
$GitIndexOverride = $env:GIT_INDEX_FILE

$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$Root = Join-Path $Downloads "MONSTER-F3-UNIFIED-SNAPSHOT-$Stamp"
$ZipPath = "$Root.zip"
$GitRoot = Join-Path $Root 'git-evidence'
$SourceRoot = Join-Path $Root 'current-source'
$BackupSnapshotRoot = Join-Path $Root 'known-backups'

New-Item -ItemType Directory -Path $GitRoot -Force | Out-Null
New-Item -ItemType Directory -Path $SourceRoot -Force | Out-Null
New-Item -ItemType Directory -Path $BackupSnapshotRoot -Force | Out-Null

function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyString()][string]$Content
    )
    $Parent = Split-Path -Parent $Path
    if ($Parent -and -not (Test-Path -LiteralPath $Parent)) {
        New-Item -ItemType Directory -Path $Parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.Encoding]::UTF8)
}

function Invoke-GitReadOnly {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$AllowNonZero
    )

    $StdoutPath = Join-Path $GitRoot ($Name + '.txt')
    $StderrPath = Join-Path $GitRoot ($Name + '.stderr.txt')

    $StartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $StartInfo.FileName = $GitExe
    $StartInfo.WorkingDirectory = $Project
    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow = $true
    $StartInfo.RedirectStandardOutput = $true
    $StartInfo.RedirectStandardError = $true
    $StartInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $StartInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $StartInfo.EnvironmentVariables['GIT_OPTIONAL_LOCKS'] = '0'
    $StartInfo.Arguments = ($Arguments -join ' ')

    $Process = New-Object System.Diagnostics.Process
    $Process.StartInfo = $StartInfo

    try {
        [void]$Process.Start()
        $StdoutTask = $Process.StandardOutput.ReadToEndAsync()
        $StderrTask = $Process.StandardError.ReadToEndAsync()
        $Process.WaitForExit()
        $Stdout = $StdoutTask.Result
        $Stderr = $StderrTask.Result
        $ExitCode = $Process.ExitCode
    }
    finally {
        $Process.Dispose()
    }

    Write-Utf8File -Path $StdoutPath -Content $Stdout
    Write-Utf8File -Path $StderrPath -Content $Stderr

    if (($ExitCode -ne 0) -and (-not $AllowNonZero)) {
        throw "Read-only Git command '$Name' failed with exit code $ExitCode. See $StderrPath. No project files were changed."
    }

    return [pscustomobject]@{
        Name = $Name
        ExitCode = $ExitCode
        Stdout = $Stdout
        Stderr = $Stderr
    }
}

function Get-RelativeProjectPath {
    param([Parameter(Mandatory = $true)][string]$FullName)
    $Prefix = $Project.TrimEnd('\') + '\'
    if ($FullName.StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $FullName.Substring($Prefix.Length).Replace('\', '/')
    }
    return $FullName.Replace('\', '/')
}

# Capture repository identity and resolve Git metadata paths before sampling status.
$Top = Invoke-GitReadOnly -Arguments @('rev-parse', '--show-toplevel') -Name 'start-repository-root'
$Branch = Invoke-GitReadOnly -Arguments @('branch', '--show-current') -Name 'start-branch'
$Head = Invoke-GitReadOnly -Arguments @('rev-parse', 'HEAD') -Name 'start-head'
$GitDirResult = Invoke-GitReadOnly -Arguments @('rev-parse', '--absolute-git-dir') -Name 'git-dir'
$GitCommonDirResult = Invoke-GitReadOnly -Arguments @('rev-parse', '--git-common-dir') -Name 'git-common-dir'
$IndexPathResult = Invoke-GitReadOnly -Arguments @('rev-parse', '--git-path', 'index') -Name 'index-path'
$SharedIndexResult = Invoke-GitReadOnly -Arguments @('rev-parse', '--shared-index-path') -Name 'shared-index-path'

if ($Top.Stdout.Trim().Replace('\', '/') -ne $Project.Replace('\', '/')) {
    throw "Git root mismatch. Expected '$Project' but got '$($Top.Stdout.Trim())'. Snapshot aborted."
}
if (-not $Head.Stdout.Trim()) { throw 'Could not resolve HEAD. Snapshot aborted.' }

$GitDir = $GitDirResult.Stdout.Trim()
if (-not [System.IO.Path]::IsPathRooted($GitDir)) {
    $GitDir = [System.IO.Path]::GetFullPath((Join-Path $Project $GitDir))
}
$GitCommonDir = $GitCommonDirResult.Stdout.Trim()
if (-not [System.IO.Path]::IsPathRooted($GitCommonDir)) {
    $CommonCandidates = @(
        [System.IO.Path]::GetFullPath((Join-Path $Project $GitCommonDir)),
        [System.IO.Path]::GetFullPath((Join-Path $GitDir $GitCommonDir))
    )
    $ResolvedCommon = $CommonCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -First 1
    if (-not $ResolvedCommon) { throw "Could not resolve Git common directory '$GitCommonDir'. Snapshot aborted." }
    $GitCommonDir = $ResolvedCommon
}

if (-not [string]::IsNullOrWhiteSpace($GitIndexOverride)) {
    if ([System.IO.Path]::IsPathRooted($GitIndexOverride)) {
        $IndexPath = [System.IO.Path]::GetFullPath($GitIndexOverride)
    }
    else {
        $IndexPath = [System.IO.Path]::GetFullPath((Join-Path $Project $GitIndexOverride))
    }
}
else {
    $IndexPath = $IndexPathResult.Stdout.Trim()
    if (-not [System.IO.Path]::IsPathRooted($IndexPath)) {
        $IndexCandidates = @(
            [System.IO.Path]::GetFullPath((Join-Path $Project $IndexPath)),
            [System.IO.Path]::GetFullPath((Join-Path $GitDir $IndexPath))
        )
        $ResolvedIndex = $IndexCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if (-not $ResolvedIndex) { throw "Git index file not found from '$IndexPath'. Snapshot aborted." }
        $IndexPath = $ResolvedIndex
    }
}
if (-not (Test-Path -LiteralPath $IndexPath -PathType Leaf)) {
    throw "Git index file not found at '$IndexPath'. Snapshot aborted."
}

# The lock belongs beside the exact index path (including a custom GIT_INDEX_FILE).
$IndexLockPath = $IndexPath + '.lock'
if (Test-Path -LiteralPath $IndexLockPath) {
    throw "Git index lock exists: $IndexLockPath. A Git operation may be active. Snapshot aborted without changing project files."
}

# Resolve and hash the shared-index companion BEFORE the first status read.
# This detects changes to either half of a split index during the capture window.
$SharedIndexRawPath = $SharedIndexResult.Stdout.Trim()
$SharedIndexPath = $null
$SharedIndexHashBefore = 'NOT_IN_USE'
$SharedIndexHashCopied = 'NOT_IN_USE'
if ($SharedIndexRawPath) {
    if ([System.IO.Path]::IsPathRooted($SharedIndexRawPath)) {
        $SharedCandidates = @($SharedIndexRawPath)
    }
    else {
        $SharedCandidates = @(
            [System.IO.Path]::GetFullPath((Join-Path $Project $SharedIndexRawPath)),
            [System.IO.Path]::GetFullPath((Join-Path $GitDir $SharedIndexRawPath)),
            [System.IO.Path]::GetFullPath((Join-Path $GitCommonDir $SharedIndexRawPath)),
            (Join-Path $GitCommonDir (Split-Path -Leaf $SharedIndexRawPath))
        )
    }
    $SharedIndexPath = $SharedCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $SharedIndexPath) {
        throw "Git reports a split-index file '$SharedIndexRawPath' but it could not be resolved. Snapshot aborted."
    }
    $SharedIndexHashBefore = (Get-FileHash -LiteralPath $SharedIndexPath -Algorithm SHA256).Hash
}

# Hash index components BEFORE the first status read. This detects staging or
# split-index changes even when porcelain status letters would remain unchanged.
$IndexHashBefore = (Get-FileHash -LiteralPath $IndexPath -Algorithm SHA256).Hash
$StatusStart = Invoke-GitReadOnly -Arguments @('status', '--porcelain=v2', '--branch', '--untracked-files=all') -Name 'status-start'

# Capture the exact index bytes without modifying the real index.
$IndexImageDir = Join-Path $GitRoot 'index-image'
New-Item -ItemType Directory -Path $IndexImageDir -Force | Out-Null
$IndexCopyPath = Join-Path $IndexImageDir (Split-Path -Leaf $IndexPath)
Copy-Item -LiteralPath $IndexPath -Destination $IndexCopyPath
$IndexHashCopied = (Get-FileHash -LiteralPath $IndexCopyPath -Algorithm SHA256).Hash
if ($IndexHashCopied -ne $IndexHashBefore) {
    throw 'Git index changed while it was being copied. Snapshot aborted as inconsistent.'
}

if ($SharedIndexPath) {
    # Preserve the original split-index filename beside the captured main index.
    $SharedIndexCopyPath = Join-Path $IndexImageDir (Split-Path -Leaf $SharedIndexPath)
    Copy-Item -LiteralPath $SharedIndexPath -Destination $SharedIndexCopyPath
    $SharedIndexHashCopied = (Get-FileHash -LiteralPath $SharedIndexCopyPath -Algorithm SHA256).Hash
    $SharedIndexHashAfterCopy = (Get-FileHash -LiteralPath $SharedIndexPath -Algorithm SHA256).Hash
    if ($SharedIndexHashBefore -ne $SharedIndexHashCopied -or $SharedIndexHashCopied -ne $SharedIndexHashAfterCopy) {
        throw 'Git shared-index file changed while it was being copied. Snapshot aborted as inconsistent.'
    }
    $SharedIndexHash = $SharedIndexHashCopied
}
else {
    $SharedIndexHash = 'NOT_IN_USE'
}

# Complete tracked/index/worktree evidence. Stdout and stderr are kept separate;
# LF/CRLF warnings can never be mixed into patch files.
[void](Invoke-GitReadOnly -Arguments @('--version') -Name 'git-version')
[void](Invoke-GitReadOnly -Arguments @('rev-parse', '--show-object-format') -Name 'git-object-format' -AllowNonZero)
[void](Invoke-GitReadOnly -Arguments @('ls-files', '--stage') -Name 'index-entries')
[void](Invoke-GitReadOnly -Arguments @('ls-files', '--others', '--exclude-standard') -Name 'untracked-files')
[void](Invoke-GitReadOnly -Arguments @('diff', '--cached', '--binary', '--no-ext-diff', '--no-color') -Name 'tracked-staged-patch')
[void](Invoke-GitReadOnly -Arguments @('diff', '--binary', '--no-ext-diff', '--no-color') -Name 'tracked-worktree-patch')
[void](Invoke-GitReadOnly -Arguments @('diff', '--cached', '--stat', '--no-color') -Name 'tracked-staged-stat')
[void](Invoke-GitReadOnly -Arguments @('diff', '--stat', '--no-color') -Name 'tracked-worktree-stat')
[void](Invoke-GitReadOnly -Arguments @('diff', '--cached', '--name-status', '--no-color') -Name 'tracked-staged-name-status')
[void](Invoke-GitReadOnly -Arguments @('diff', '--name-status', '--no-color') -Name 'tracked-worktree-name-status')

# Copy application source under selected roots, plus the COMPLETE project-root workspace.
# The project-root workspace is a first-class part of this project and is never excluded wholesale.
# For workspace/, include every regular file regardless of extension and include hidden files.
# Only secret-named files and filesystem reparse points are omitted and explicitly reported.
$SourceRoots = @('lib', 'app', 'components', 'scripts', 'db', 'tests', 'test', 'qa', 'types', 'src')
$AllowedExtensions = @('.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs', '.sql', '.ps1', '.py', '.sh', '.bat', '.cmd', '.json', '.yaml', '.yml', '.toml')
$ExcludedDirectoryPattern = '[\\/](\.git|node_modules|\.next|dist|coverage|\.turbo|\.cache|\.vercel|\.output)[\\/]'
$ExcludedSensitiveFilePattern = '(?i)(^|[\\/])(\.env([.]|$)|[^\\/]*(secret|credential|service-account)[^\\/]*[.](json|ya?ml|toml)$|id_(rsa|ed25519)([.]|$)|[^\\/]*[.](pem|pfx|p12|key)$)'
$script:WorkspaceExcludedPaths = New-Object System.Collections.Generic.List[string]
$ExplicitFiles = @(
    'middleware.ts',
    'instrumentation.ts',
    'next-env.d.ts',
    'package.json',
    'package-lock.json',
    'tsconfig.json',
    'next.config.js',
    'next.config.mjs',
    'next.config.ts',
    'compose.yaml',
    '.gitignore',
    'postcss.config.js',
    'postcss.config.mjs',
    'eslint.config.js',
    'eslint.config.mjs',
    'vitest.config.ts',
    'jest.config.ts',
    'playwright.config.ts',
    'AGENTS.md',
    'README.md'
)

function Get-ReviewSourceInventory {
    $Files = New-Object System.Collections.Generic.List[object]
    # Reset exclusions for each inventory pass so initial/final comparisons are exact.
    $script:WorkspaceExcludedPaths = New-Object System.Collections.Generic.List[string]

    foreach ($RelativeRoot in $SourceRoots) {
        $AbsoluteRoot = Join-Path $Project $RelativeRoot
        if (-not (Test-Path -LiteralPath $AbsoluteRoot -PathType Container)) { continue }

        $Discovered = Get-ChildItem -LiteralPath $AbsoluteRoot -Recurse -File -Force
        foreach ($File in $Discovered) {
            if ($AllowedExtensions -notcontains $File.Extension.ToLowerInvariant()) { continue }
            if ($File.FullName -match $ExcludedDirectoryPattern) { continue }
            if ($File.FullName -match $ExcludedSensitiveFilePattern) { continue }
            $Files.Add($File)
        }
    }

    # Preserve the complete project-root workspace tree. Do not apply the source
    # extension allow-list or generated-directory filters to this tree: project
    # assets, custom formats, hidden files, and nested project files are included.
    # Reparse points are skipped to avoid following links outside the project or loops.
    $PendingWorkspaceDirectories = New-Object System.Collections.Stack
    $PendingWorkspaceDirectories.Push($WorkspaceRoot)
    while ($PendingWorkspaceDirectories.Count -gt 0) {
        $CurrentDirectory = [string]$PendingWorkspaceDirectories.Pop()
        $Children = Get-ChildItem -LiteralPath $CurrentDirectory -Force
        foreach ($Child in $Children) {
            $IsReparsePoint = (($Child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
            if ($IsReparsePoint) {
                $script:WorkspaceExcludedPaths.Add((Get-RelativeProjectPath -FullName $Child.FullName) + ' [REPARSE_POINT_SKIPPED]')
                continue
            }
            if ($Child.PSIsContainer) {
                $PendingWorkspaceDirectories.Push($Child.FullName)
                continue
            }
            if ($Child.FullName -match $ExcludedSensitiveFilePattern) {
                $script:WorkspaceExcludedPaths.Add((Get-RelativeProjectPath -FullName $Child.FullName) + ' [SENSITIVE_NAME_SKIPPED]')
                continue
            }
            $Files.Add($Child)
        }
    }

    foreach ($RelativeFile in $ExplicitFiles) {
        $AbsoluteFile = Join-Path $Project $RelativeFile
        if (Test-Path -LiteralPath $AbsoluteFile -PathType Leaf) {
            $Files.Add((Get-Item -LiteralPath $AbsoluteFile))
        }
    }

    $Unique = @{}
    foreach ($File in $Files) {
        $Key = $File.FullName.ToLowerInvariant()
        if (-not $Unique.ContainsKey($Key)) { $Unique[$Key] = $File }
    }
    return @($Unique.Values | Sort-Object FullName)
}

$InitialSourceInventory = @(Get-ReviewSourceInventory)
$InitialWorkspaceExclusions = @($script:WorkspaceExcludedPaths | Sort-Object)
$UniqueSourceFiles = @{}
foreach ($File in $InitialSourceInventory) {
    $UniqueSourceFiles[$File.FullName.ToLowerInvariant()] = $File
}

$SourceManifest = New-Object System.Collections.Generic.List[object]
if ($UniqueSourceFiles.Count -eq 0) { throw 'No review source files were found. Snapshot aborted.' }
foreach ($File in ($UniqueSourceFiles.Values | Sort-Object FullName)) {
    $RelativePath = Get-RelativeProjectPath -FullName $File.FullName
    $Destination = Join-Path $SourceRoot ($RelativePath -replace '/', '\')
    $DestinationParent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $DestinationParent -Force | Out-Null

    $Before = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash
    Copy-Item -LiteralPath $File.FullName -Destination $Destination
    $Copied = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
    $After = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash
    $Length = (Get-Item -LiteralPath $Destination).Length

    $SourceManifest.Add([pscustomobject]@{
        RelativePath = $RelativePath
        SHA256Before = $Before
        SHA256Copy = $Copied
        SHA256AfterCopy = $After
        Length = $Length
        StableDuringCopy = ($Before -eq $Copied -and $Copied -eq $After)
    })
}

# Include known F3 checkpoints, only when the exact expected relative path exists.
# This is a read-only copy of selected baseline files, not a restore operation.
$BackupSpecs = @(
    [pscustomobject]@{ Name = 'P1'; Path = (Join-Path $BackupRoot 'MONSTER-F3-P1-BACKUP-20261113-223341-900') },
    [pscustomobject]@{ Name = 'P2'; Path = (Join-Path $BackupRoot 'MONSTER-F3-P1-P2-BACKUP-20261113-231344-857') },
    [pscustomobject]@{ Name = 'REMAINING-3'; Path = (Join-Path $BackupRoot 'MONSTER-F3-P1-REMAINING-3-BACKUP-20261113-233125-412') }
)
$BaselinePaths = @(
    'lib/agents/runtime.ts',
    'lib/ai/tool-executor.ts',
    'lib/ai/tool-policy.ts',
    'lib/tasks/queue.ts',
    'lib/memory/store.ts',
    'lib/workspace/tools.ts',
    'lib/tasks/orchestrator.ts',
    'lib/tasks/lease-recovery.ts',
    'lib/tasks/retry-policy.ts',
    'scripts/task-worker.ts',
    'scripts/test-cross-tool-side-effect-identity.ts',
    'scripts/test-researcher-web-search.ts',
    'scripts/test-f3-p1.ts',
    'scripts/test-f3-p2-runtime-identity.ts',
    'scripts/test-enqueue-task-wrapper.ts',
    'scripts/test-workspace-replay-post-effect-crash.ts',
    'scripts/test-worker-lease-recovery-guard.ts',
    'scripts/test-worker-retry-guard.ts',
    'scripts/test-retry-policy.ts',
    'scripts/test-workspace-replay.ts'
)
$BackupManifest = New-Object System.Collections.Generic.List[object]

foreach ($Backup in $BackupSpecs) {
    foreach ($RelativePath in $BaselinePaths) {
        $RelativeWindows = $RelativePath -replace '/', '\'
        $Candidates = @(
            (Join-Path $Backup.Path $RelativeWindows),
            (Join-Path (Join-Path $Backup.Path 'frontend') $RelativeWindows),
            (Join-Path (Join-Path $Backup.Path 'MONSTER-AI-COMMAND-CENTER\frontend') $RelativeWindows),
            (Join-Path (Join-Path $Backup.Path 'project\frontend') $RelativeWindows),
            (Join-Path (Join-Path $Backup.Path 'source') $RelativeWindows)
        )
        $Found = $null
        foreach ($Candidate in $Candidates) {
            if (Test-Path -LiteralPath $Candidate -PathType Leaf) {
                $Found = $Candidate
                break
            }
        }

        if ($Found) {
            $Destination = Join-Path (Join-Path $BackupSnapshotRoot $Backup.Name) $RelativeWindows
            $DestinationParent = Split-Path -Parent $Destination
            New-Item -ItemType Directory -Path $DestinationParent -Force | Out-Null
            $Before = (Get-FileHash -LiteralPath $Found -Algorithm SHA256).Hash
            Copy-Item -LiteralPath $Found -Destination $Destination
            $Copied = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
            $After = (Get-FileHash -LiteralPath $Found -Algorithm SHA256).Hash
            $BackupManifest.Add([pscustomobject]@{
                Backup = $Backup.Name
                RelativePath = $RelativePath
                Status = $(if ($Before -eq $Copied -and $Copied -eq $After) { 'COPIED_STABLE' } else { 'CHANGED_DURING_COPY' })
                SHA256 = $Copied
                SourcePath = $Found
            })
        }
        else {
            $BackupManifest.Add([pscustomobject]@{
                Backup = $Backup.Name
                RelativePath = $RelativePath
                Status = $(if (Test-Path -LiteralPath $Backup.Path -PathType Container) { 'NOT_FOUND_IN_BACKUP_LAYOUT' } else { 'BACKUP_FOLDER_NOT_FOUND' })
                SHA256 = ''
                SourcePath = ''
            })
        }
    }
}

# Re-enumerate source paths as well as hashes. This catches added/deleted files even
# when an ignored file would not alter `git status`.
$FinalSourceInventory = @(Get-ReviewSourceInventory)
$FinalWorkspaceExclusions = @($script:WorkspaceExcludedPaths | Sort-Object)
$WorkspaceExclusionDelta = @(Compare-Object -ReferenceObject $InitialWorkspaceExclusions -DifferenceObject $FinalWorkspaceExclusions)
$InitialInventoryKeys = @($UniqueSourceFiles.Keys | Sort-Object)
$FinalInventoryKeys = @($FinalSourceInventory | ForEach-Object { $_.FullName.ToLowerInvariant() } | Sort-Object)
$InventoryDelta = @(Compare-Object -ReferenceObject $InitialInventoryKeys -DifferenceObject $FinalInventoryKeys)

# Re-hash all copied project sources to detect edits during the capture window.
$Drift = New-Object System.Collections.Generic.List[string]
if ($InventoryDelta.Count -gt 0) {
    $Drift.Add('SOURCE_FILE_INVENTORY_CHANGED_DURING_SNAPSHOT')
}
if ($WorkspaceExclusionDelta.Count -gt 0) {
    $Drift.Add('WORKSPACE_EXCLUSION_INVENTORY_CHANGED_DURING_SNAPSHOT')
}
foreach ($Record in $SourceManifest) {
    $AbsoluteFile = Join-Path $Project ($Record.RelativePath -replace '/', '\')
    if (-not (Test-Path -LiteralPath $AbsoluteFile -PathType Leaf)) {
        $Drift.Add("MISSING_AFTER_COPY: $($Record.RelativePath)")
        continue
    }
    $EndHash = (Get-FileHash -LiteralPath $AbsoluteFile -Algorithm SHA256).Hash
    if ($EndHash -ne $Record.SHA256Copy) {
        $Drift.Add("CHANGED_DURING_SNAPSHOT: $($Record.RelativePath)")
    }
}

# Capture final Git state and verify repository identity did not move.
$StatusEnd = Invoke-GitReadOnly -Arguments @('status', '--porcelain=v2', '--branch', '--untracked-files=all') -Name 'status-end'
$HeadEnd = Invoke-GitReadOnly -Arguments @('rev-parse', 'HEAD') -Name 'end-head'
$BranchEnd = Invoke-GitReadOnly -Arguments @('branch', '--show-current') -Name 'end-branch'
$IndexHashAfter = (Get-FileHash -LiteralPath $IndexPath -Algorithm SHA256).Hash
$SharedIndexHashAfter = if ($SharedIndexPath) { (Get-FileHash -LiteralPath $SharedIndexPath -Algorithm SHA256).Hash } else { 'NOT_IN_USE' }
$IndexLockExistsAtEnd = (Test-Path -LiteralPath $IndexLockPath)

if ($IndexLockExistsAtEnd) { $Drift.Add('GIT_INDEX_LOCK_EXISTS_AT_END') }
if ($HeadEnd.Stdout.Trim() -ne $Head.Stdout.Trim()) { $Drift.Add('GIT_HEAD_CHANGED_DURING_SNAPSHOT') }
if ($BranchEnd.Stdout.Trim() -ne $Branch.Stdout.Trim()) { $Drift.Add('GIT_BRANCH_CHANGED_DURING_SNAPSHOT') }
if ($IndexHashAfter -ne $IndexHashBefore) { $Drift.Add('GIT_INDEX_CHANGED_DURING_SNAPSHOT') }
if ($SharedIndexHashAfter -ne $SharedIndexHashBefore) { $Drift.Add('GIT_SHARED_INDEX_CHANGED_DURING_SNAPSHOT') }
if ($StatusEnd.Stdout -ne $StatusStart.Stdout) { $Drift.Add('GIT_STATUS_CHANGED_DURING_SNAPSHOT') }
if (@($SourceManifest | Where-Object { -not $_.StableDuringCopy }).Count -gt 0) {
    $Drift.Add('ONE_OR_MORE_SOURCE_FILES_CHANGED_WHILE_BEING_COPIED')
}
if (@($BackupManifest | Where-Object { $_.Status -eq 'CHANGED_DURING_COPY' }).Count -gt 0) {
    $Drift.Add('ONE_OR_MORE_BACKUP_FILES_CHANGED_WHILE_BEING_COPIED')
}

foreach ($BackupRecord in ($BackupManifest | Where-Object { $_.Status -eq 'COPIED_STABLE' })) {
    if (-not (Test-Path -LiteralPath $BackupRecord.SourcePath -PathType Leaf)) {
        $Drift.Add("BACKUP_FILE_MISSING_AFTER_COPY: $($BackupRecord.Backup)/$($BackupRecord.RelativePath)")
        continue
    }
    $BackupEndHash = (Get-FileHash -LiteralPath $BackupRecord.SourcePath -Algorithm SHA256).Hash
    if ($BackupEndHash -ne $BackupRecord.SHA256) {
        $Drift.Add("BACKUP_FILE_CHANGED_DURING_SNAPSHOT: $($BackupRecord.Backup)/$($BackupRecord.RelativePath)")
    }
}

$SourceManifest | Export-Csv -LiteralPath (Join-Path $Root 'source-manifest.csv') -NoTypeInformation -Encoding UTF8
$BackupManifest | Export-Csv -LiteralPath (Join-Path $Root 'backup-manifest.csv') -NoTypeInformation -Encoding UTF8
$InitialWorkspaceExclusions | Set-Content -LiteralPath (Join-Path $Root 'workspace-exclusions.txt') -Encoding UTF8
$Drift | Set-Content -LiteralPath (Join-Path $Root 'snapshot-drift.txt') -Encoding UTF8

$SnapshotStatus = if ($Drift.Count -eq 0) { 'CONSISTENT' } else { 'INCONSISTENT_REVIEW_ONLY' }
$Summary = @"
MONSTER F3 — UNIFIED READ-ONLY SNAPSHOT v4
Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Snapshot status: $SnapshotStatus
Project: $Project
Repository root: $($Top.Stdout.Trim())
Branch at start: $($Branch.Stdout.Trim())
HEAD at start: $($Head.Stdout.Trim())
Branch at end: $($BranchEnd.Stdout.Trim())
HEAD at end: $($HeadEnd.Stdout.Trim())
Git index path: $IndexPath
GIT_INDEX_FILE override: $(if ($GitIndexOverride) { $GitIndexOverride } else { 'NOT_SET' })
Git index SHA256 before: $IndexHashBefore
Git index copy path: $IndexCopyPath
Git index SHA256 copied: $IndexHashCopied
Git index SHA256 after: $IndexHashAfter
Git shared-index original path: $SharedIndexPath
Git shared-index SHA256 before/copy/after: $SharedIndexHashBefore / $SharedIndexHash / $SharedIndexHashAfter
Git index.lock path: $IndexLockPath
Git index.lock exists at end: $IndexLockExistsAtEnd
Shared index SHA256: $SharedIndexHash
Source files captured: $($SourceManifest.Count)
Workspace files captured: $(@($SourceManifest | Where-Object { $_.RelativePath.StartsWith('workspace/', [System.StringComparison]::OrdinalIgnoreCase) }).Count)
Workspace exclusions recorded: $($InitialWorkspaceExclusions.Count)
Backup file entries recorded: $($BackupManifest.Count)
Drift findings: $($Drift.Count)

Contents:
- git-evidence/ : start/end status, branch, HEAD, Git version/object format, exact staged and unstaged patches,
  index entries, untracked inventory, separate stderr logs, and index-image/ (the exact index plus its
  shared-index companion side-by-side when split-index is active).
- current-source/ : source code from lib/, app/, components/, scripts/, db/, tests/, qa/, types/, src/, plus selected root configs.
  The entire project-root workspace/ tree is included recursively, with every file type,
  hidden files, assets, and custom project formats. Secret-named files and filesystem
  reparse points are excluded and listed in workspace-exclusions.txt.
- known-backups/ : matching selected files from known P1/P2/remaining-three backup folders.
- source-manifest.csv : SHA256 and copy-stability record for every source file.
- backup-manifest.csv : which historical checkpoint files were found and captured.
- snapshot-drift.txt : any detected changes during capture.

Safety:
This collector performs read-only Git queries and file copies only.
It does not stage, reset, checkout, clean, commit, edit project source,
run tests, access PostgreSQL, or stop/restart services. The ZIP uses .NET ZipFile
so dotfiles such as .gitignore are retained.
Known .env files, secret/credential-named files, private-key files, and filesystem reparse
points inside workspace/ are excluded and listed. The workspace tree itself is NOT excluded.
Application source roots still exclude standard dependency/build/cache directories. This is not a complete secret scanner;
review the archive for hard-coded credentials before uploading it to another service.

Interpretation:
Use this as one capture window only when Snapshot status is CONSISTENT and
snapshot-drift.txt is empty. If status is INCONSISTENT_REVIEW_ONLY, do not use it
as the final authoritative baseline; repeat after project editing/Git operations stop.
"@
Write-Utf8File -Path (Join-Path $Root 'README.txt') -Content $Summary

# Create and verify the archive. ZipFile includes hidden/dot files; Compress-Archive
# can omit hidden files when passed a wildcard path.
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $Root,
    $ZipPath,
    [System.IO.Compression.CompressionLevel]::Optimal,
    $false
)
if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
    throw 'ZIP creation failed. The project itself was not modified.'
}
$ZipItem = Get-Item -LiteralPath $ZipPath
$ZipHash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash

$ZipHandle = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
try {
    $EntryCount = $ZipHandle.Entries.Count
    if ($EntryCount -lt 10) { throw "ZIP verification failed: only $EntryCount entries found." }
    $Buffer = New-Object byte[] 65536
    foreach ($Entry in $ZipHandle.Entries) {
        if ($Entry.FullName.EndsWith('/')) { continue }
        $EntryStream = $Entry.Open()
        try {
            while ($EntryStream.Read($Buffer, 0, $Buffer.Length) -gt 0) { }
        }
        finally {
            $EntryStream.Dispose()
        }
    }
}
finally {
    $ZipHandle.Dispose()
}

Write-Host ''
Write-Host '========== MONSTER F3 UNIFIED SNAPSHOT ==========' -ForegroundColor Cyan
Write-Host "SNAPSHOT_STATUS=$SnapshotStatus"
Write-Host "SOURCE_FILES=$($SourceManifest.Count)"
Write-Host "WORKSPACE_FILES=$(@($SourceManifest | Where-Object { $_.RelativePath.StartsWith('workspace/', [System.StringComparison]::OrdinalIgnoreCase) }).Count)"
Write-Host "WORKSPACE_EXCLUSIONS=$($InitialWorkspaceExclusions.Count)"
Write-Host "SOURCE_INVENTORY_DELTA=$($InventoryDelta.Count)"
Write-Host "BACKUP_MATCHES=$(@($BackupManifest | Where-Object { $_.Status -eq 'COPIED_STABLE' }).Count)"
Write-Host "DRIFT_FINDINGS=$($Drift.Count)"
Write-Host "GIT_INDEX_LOCK_AT_END=$IndexLockExistsAtEnd"
Write-Host "ZIP_ENTRIES=$EntryCount"
Write-Host "ZIP_LENGTH=$($ZipItem.Length)"
Write-Host "ZIP_SHA256=$ZipHash"
Write-Host "ZIP_PATH=$ZipPath" -ForegroundColor Green
if ($Drift.Count -gt 0) {
    Write-Host 'SNAPSHOT_DRIFT:' -ForegroundColor Yellow
    $Drift | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
}
Write-Host 'The entire project-root workspace/ was included (except explicitly listed secret-named files and reparse points).
No project source, Git index, database, or service was modified.'
Write-Host '=================================================' -ForegroundColor Cyan

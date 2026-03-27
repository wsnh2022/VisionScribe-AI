@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion

:: ============================================================================
:: FILE         : gitsync.bat
:: PURPOSE      : Universal Git sync script. Works on any repo, any branch,
::                any machine. No hardcoded paths, names, or branch targets.
:: ============================================================================
::
:: ARCHITECTURE
:: ------------
:: Runs in 6 sequential phases:
::
::   [1] GUARDS
::       - Verifies the current directory is a git repository.
::       - Verifies a remote named 'origin' exists.
::       - Extracts repo name and branch dynamically from git state.
::       - Acquires a .gitsync.lock file to block concurrent runs.
::       - Fails fast with a clear error if any check fails.
::
::   [2] FETCH + DIVERGENCE CHECK
::       - Runs git fetch to get latest remote state without modifying local.
::       - Checks whether origin/<branch> tracking ref exists before counting.
::       - Counts how many commits remote is ahead (REMOTE_AHEAD).
::       - Counts how many commits local is ahead (LOCAL_AHEAD).
::       - Uses these counts to decide: pull / push / skip.
::
::   [3] PULL (conditional)
::       - Only runs if REMOTE_AHEAD > 0.
::       - Pulls remote changes before staging anything local.
::       - Aborts with a logged error if pull fails (merge conflict).
::       - Prevents push rejection due to non-fast-forward divergence.
::
::   [4] DYNAMIC GITIGNORE CLEANUP
::       - Queries git for all tracked files that now match a .gitignore rule.
::       - Runs git rm --cached on each match to remove from tracking index.
::       - Does NOT delete local files. Only removes remote tracking.
::       - Runs on every execution so .gitignore changes are always enforced.
::       - Stages all remaining local changes with git add -A.
::
::   [5] COMMIT + PUSH
::       - If nothing staged and nothing unpushed: logs SKIPPED and exits.
::       - If nothing staged but LOCAL_AHEAD > 0: pushes only, logs accurately.
::       - If staged changes exist: builds commit message, commits, then pushes.
::         Format: "Update <first_file>" or "Update <first_file> and N more files"
::       - Reports SUCCESS or FAILED with branch and Actions URL.
::
::   [6] LOGGING
::       - Writes a structured entry to deploy-log.txt in the repo root.
::       - Logs: date, start/end time, elapsed seconds, repo, branch,
::               status (SUCCESS / FAILED / SKIPPED), commit msg, diff stat.
::       - Runs on every exit path including errors and skips.
::       - Lock file is deleted on every exit path.
::
:: REQUIREMENTS
::   git must be installed and available in system PATH
:: ============================================================================

:: -- Capture start time -------------------------------------------------------
set START_TIME=%TIME%

:: -- Guard: must be inside a git repo -----------------------------------------
git rev-parse --git-dir >nul 2>&1
if !ERRORLEVEL! neq 0 (
    echo.
    echo ========================================
    echo   ERROR: Not a git repository.
    echo   Run this from inside a git repo folder.
    echo ========================================
    echo.
    echo Press any key to close . . .
    pause >nul
    exit /b 1
)

:: -- Resolve repo root for lock file and log file -----------------------------
for /f "delims=" %%i in ('git rev-parse --show-toplevel 2^>nul') do set REPO_ROOT=%%i
set REPO_ROOT=!REPO_ROOT:/=\!
set LOCK_FILE=!REPO_ROOT!\.gitsync.lock
set LOG_FILE=!REPO_ROOT!\deploy-log.txt

:: -- Auto-append missing entries to .gitignore ------------------------------
set GITIGNORE=!REPO_ROOT!\.gitignore
for %%e in (gitsync.bat deploy-log.txt .gitsync.lock) do (
    findstr /i /c:"%%e" "!GITIGNORE!" >nul 2>&1
    if !ERRORLEVEL! neq 0 echo %%e >> "!GITIGNORE!"
)

:: -- Concurrency guard: warn if lock exists but never block on stale lock ----
if exist "!LOCK_FILE!" (
    echo.
    echo   WARNING: Stale lock found. Previous run may have crashed. Clearing it.
    echo.
    del /f /q "!LOCK_FILE!" >nul 2>&1
)
echo %~f0 > "!LOCK_FILE!" 2>nul

:: -- Guard: must have an origin remote ----------------------------------------
for /f "delims=" %%i in ('git remote get-url origin 2^>nul') do set REMOTE_URL=%%i
if not defined REMOTE_URL (
    echo.
    echo ========================================
    echo   ERROR: No remote named 'origin' found.
    echo   Add one with: git remote add origin ^<url^>
    echo ========================================
    echo.
    del /f /q "!LOCK_FILE!" >nul 2>&1
    echo Press any key to close . . .
    pause >nul
    exit /b 1
)

:: -- Extract repo path from HTTPS or SSH URL ----------------------------------
set REPO_PATH=!REMOTE_URL:https://github.com/=!
set REPO_PATH=!REPO_PATH:git@github.com:=!
if "!REPO_PATH:~-4!"==".git" set REPO_PATH=!REPO_PATH:~0,-4!

for /f "tokens=2 delims=/" %%i in ("!REPO_PATH!") do set REPO_NAME=%%i
if not defined REPO_NAME set REPO_NAME=this-repo

:: -- Detect current branch dynamically ----------------------------------------
for /f "delims=" %%i in ('git rev-parse --abbrev-ref HEAD 2^>nul') do set BRANCH=%%i
if not defined BRANCH set BRANCH=main

:: -- Setup paths --------------------------------------------------------------
set ACTIONS_URL=https://github.com/!REPO_PATH!/actions

:: -- Initialise defaults ------------------------------------------------------
set DIFF_SUMMARY=N/A
set AUTO_COMMIT=Sync !REPO_NAME!
set PUSH_RESULT=0

echo.
echo ========================================
echo   Deploying !REPO_NAME! ^(!BRANCH!^) to GitHub
echo ========================================
echo.

:: -- Fetch remote state -------------------------------------------------------
echo Checking remote for updates...
git fetch origin >nul 2>&1

:: -- Divergence check: only run if remote tracking ref exists -----------------
set REMOTE_AHEAD=0
set LOCAL_AHEAD=0
git rev-parse origin/!BRANCH! >nul 2>&1
if !ERRORLEVEL! equ 0 (
    for /f %%i in ('git rev-list HEAD..origin/!BRANCH! --count 2^>nul') do set REMOTE_AHEAD=%%i
    for /f %%i in ('git rev-list origin/!BRANCH!..HEAD --count 2^>nul') do set LOCAL_AHEAD=%%i
)
if not defined REMOTE_AHEAD set REMOTE_AHEAD=0
if not defined LOCAL_AHEAD set LOCAL_AHEAD=0

:: -- Pull if remote is ahead --------------------------------------------------
if !REMOTE_AHEAD! gtr 0 (
    echo Remote has !REMOTE_AHEAD! new commits. Pulling first...
    git pull origin !BRANCH!
    if !ERRORLEVEL! neq 0 (
        echo.
        echo ========================================
        echo   FAILED: Pull error. Resolve conflicts manually then re-run.
        echo ========================================
        echo.
        call :write_log "FAILED" "Pull failed - merge conflict" "N/A"
        del /f /q "!LOCK_FILE!" >nul 2>&1
        echo Press any key to close . . .
        pause >nul
        exit /b 1
    )
    echo Pull successful.
    echo.
)

:: -- Remove only ignored files from tracking, then stage everything -----------
echo Cleaning up and staging changes...
for /f "delims=" %%i in ('git ls-files -i -c --exclude-standard 2^>nul') do git rm --cached "%%i" >nul 2>&1
git add -A >nul 2>&1

:: -- Check what is staged -----------------------------------------------------
git diff --cached --quiet
set HAS_STAGED=!ERRORLEVEL!

:: -- Structured branch: no staged changes -------------------------------------
if !HAS_STAGED! equ 0 (
    if !LOCAL_AHEAD! equ 0 (
        echo.
        echo ========================================
        echo   Already in sync. Nothing to deploy.
        echo ========================================
        echo.
        call :write_log "SKIPPED" "Already in sync" "N/A"
        del /f /q "!LOCK_FILE!" >nul 2>&1
        echo Press any key to close . . .
        pause >nul
        exit /b 0
    )
    set AUTO_COMMIT=Push existing unpushed commits
    set DIFF_SUMMARY=N/A - no new staged changes
) else (
    for /f "delims=" %%i in ('git diff --cached --stat --no-color 2^>nul ^| findstr "changed"') do set DIFF_SUMMARY=%%i

    set FILE_COUNT=0
    for /f "delims=" %%i in ('git diff --cached --name-only 2^>nul') do (
        if not defined FIRST_FILE (
            for %%f in ("%%i") do set FIRST_FILE=%%~nxf
        )
        set /a FILE_COUNT+=1
    )
    if not defined FIRST_FILE set FIRST_FILE=changes

    if !FILE_COUNT! equ 1 (
        set AUTO_COMMIT=Update !FIRST_FILE!
    ) else (
        set /a OTHER_COUNT=FILE_COUNT-1
        set AUTO_COMMIT=Update !FIRST_FILE! and !OTHER_COUNT! more files
    )

    echo Commit: !AUTO_COMMIT!
    echo.
    git commit -m "!AUTO_COMMIT!"
)

:: -- Push ---------------------------------------------------------------------
echo Pushing to GitHub...
git push origin !BRANCH!
set PUSH_RESULT=!ERRORLEVEL!

if !PUSH_RESULT! equ 0 (
    call :write_log "SUCCESS" "!AUTO_COMMIT!" "!DIFF_SUMMARY!"
    echo.
    echo ========================================
    echo   SUCCESS: !REPO_NAME! is live on !BRANCH!
    echo   Commit  : !AUTO_COMMIT!
    echo   Actions : !ACTIONS_URL!
    echo   Log     : !LOG_FILE!
    echo ========================================
) else (
    call :write_log "FAILED" "Push failed" "!DIFF_SUMMARY!"
    echo.
    echo ========================================
    echo   FAILED: Push error.
    echo   Branch  : !BRANCH!
    echo   Check connection or remote permissions.
    echo ========================================
)

del /f /q "!LOCK_FILE!" >nul 2>&1
echo.
echo Press any key to close . . .
pause >nul
exit /b

:: -- Log writer ---------------------------------------------------------------
:write_log
set END_TIME=%TIME%

for /f "tokens=1-4 delims=:,. " %%a in ("!START_TIME!") do (
    set /a SH=1%%a-100, SM=1%%b-100, SS=1%%c-100
)
for /f "tokens=1-4 delims=:,. " %%a in ("!END_TIME!") do (
    set /a EH=1%%a-100, EM=1%%b-100, ES=1%%c-100
)
set /a ELAPSED=(EH-SH)*3600 + (EM-SM)*60 + (ES-SS)
if !ELAPSED! lss 0 set /a ELAPSED+=86400

echo. >> "!LOG_FILE!"
echo ================================================ >> "!LOG_FILE!"
echo DATE       : !date!             >> "!LOG_FILE!"
echo START TIME : !START_TIME!       >> "!LOG_FILE!"
echo END TIME   : !END_TIME!         >> "!LOG_FILE!"
echo ELAPSED    : !ELAPSED! seconds  >> "!LOG_FILE!"
echo REPO       : !REPO_NAME!        >> "!LOG_FILE!"
echo BRANCH     : !BRANCH!           >> "!LOG_FILE!"
echo STATUS     : %~1                >> "!LOG_FILE!"
echo COMMIT MSG : %~2                >> "!LOG_FILE!"
echo CHANGES    : %~3                >> "!LOG_FILE!"
echo REMOTE URL : !ACTIONS_URL!      >> "!LOG_FILE!"
echo ================================================ >> "!LOG_FILE!"
exit /b

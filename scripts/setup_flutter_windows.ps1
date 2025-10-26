<#
Setup script for Windows (PowerShell)
What it does:
 - Installs Git and Eclipse Temurin OpenJDK 17 via winget if available
 - Clones Flutter (stable) into C:\dev\flutter if not present
 - Adds Flutter and Java bin to the current session PATH
 - Persists PATH and JAVA_HOME at user scope (if not present)
 - Runs `flutter --version` and `flutter doctor`
 - Runs Gradle build: `gradlew.bat assembleDebug --stacktrace`

Run as: open PowerShell (Admin recommended) and execute:
  Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process -Force; .\scripts\setup_flutter_windows.ps1

Note: This script uses winget when available. If you don't have winget it will skip auto-install and ask you to install Git/JDK manually.
#>

function Abort($msg){
    Write-Error $msg
    exit 1
}

Write-Host "== Setup Flutter & JDK (Windows) script started =="

# Helper to run a command and fail on error
function Run-Checked($cmd){
    Write-Host "> $cmd"
    & cmd /c $cmd
    if ($LASTEXITCODE -ne 0) {
        Abort "Command failed: $cmd (exit $LASTEXITCODE)"
    }
}

# 1) Use winget to install Git and Temurin 17 if winget exists
$winget = Get-Command winget -ErrorAction SilentlyContinue
if ($winget) {
    Write-Host "winget found: will attempt to install Git and Temurin (OpenJDK 17) if missing"
    # Install Git
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "Installing Git via winget..."
        Run-Checked 'winget install --id Git.Git -e --silent'
    } else { Write-Host "Git already installed" }

    # Install Temurin 17
    if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
        Write-Host "Installing Eclipse Temurin JDK 17 via winget..."
        # Try known package id
        $installIds = @('EclipseAdoptium.Temurin.17','Microsoft.OpenJDK.17')
        $installed = $false
        foreach ($id in $installIds) {
            try {
                Write-Host "Trying winget install $id"
                & cmd /c "winget install --id $id -e --silent"
                if ($LASTEXITCODE -eq 0) { $installed = $true; break }
            } catch {
                # continue
            }
        }
        if (-not $installed) { Write-Warning "winget couldn't install a JDK automatically. Please install OpenJDK 17 or Temurin 17 manually and re-run the script." }
    } else { Write-Host "Java (java) already in PATH" }
} else {
    Write-Warning "winget not found: skipping automatic install of Git/JDK. Please install Git and a JDK (17) manually if missing." 
}

# 2) Ensure Git is available
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Abort "Git is required but was not found. Install Git (https://git-scm.com/) and re-run this script."
}

# 3) Clone Flutter stable into C:\dev\flutter if missing
$flutterRoot = 'C:\dev\flutter'
if (-not (Test-Path $flutterRoot)) {
    Write-Host "Creating C:\dev and cloning Flutter (stable) into $flutterRoot"
    New-Item -ItemType Directory -Force -Path 'C:\dev' | Out-Null
    Run-Checked "git clone https://github.com/flutter/flutter.git -b stable C:\\dev\\flutter"
} else {
    Write-Host "Flutter folder already exists at $flutterRoot"
}

# 4) Ensure Flutter bin is in current session PATH
$env:Path = "$flutterRoot\bin;" + $env:Path
Write-Host "Added $flutterRoot\bin to current session PATH"

# 5) Detect java and set JAVA_HOME for session and user
$javaCmd = Get-Command java -ErrorAction SilentlyContinue
if ($null -eq $javaCmd) {
    Write-Warning "java not found in PATH. If you installed a JDK just now, open a NEW terminal and re-run this script."
} else {
    $jdkBin = Split-Path $javaCmd.Source -Parent
    $javaHome = Split-Path $jdkBin -Parent
    Write-Host "Detected JDK home: $javaHome"
    # Set for current session
    $env:JAVA_HOME = $javaHome
    $env:Path = $javaHome + '\\bin;' + $env:Path
    # Persist to user variables if not already present
    $curJavaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME','User')
    if ($curJavaHome -ne $javaHome) {
        [Environment]::SetEnvironmentVariable('JAVA_HOME',$javaHome,'User')
        Write-Host "Set JAVA_HOME for current user to: $javaHome"
    } else { Write-Host "JAVA_HOME already set to $javaHome (user scope)" }
    # Add java bin to user PATH if absent
    $userPath = [Environment]::GetEnvironmentVariable('Path','User')
    if ($userPath -notlike "*$($javaHome)\\bin*") {
        [Environment]::SetEnvironmentVariable('Path',$userPath + ';' + ($javaHome + '\\bin'),'User')
        Write-Host "Appended Java bin to user PATH"
    } else { Write-Host "Java bin already in user PATH" }
}

# 6) Ensure flutter.tools gradle folder exists
$gradlePluginPath = Join-Path $flutterRoot 'packages\flutter_tools\gradle'
if (-not (Test-Path $gradlePluginPath)) {
    Write-Error "Flutter gradle plugin not found at: $gradlePluginPath"
    Write-Error "If Flutter is installed in another location, update android/local.properties -> flutter.sdk=..."
    Exit 1
} else { Write-Host "Found Flutter gradle plugin at: $gradlePluginPath" }

# 7) Run flutter doctor
Write-Host "Running flutter doctor (may take a while)..."
& "$flutterRoot\bin\flutter.bat" doctor
if ($LASTEXITCODE -ne 0) { Write-Warning "flutter doctor returned non-zero exit code ($LASTEXITCODE)" }

# 8) Accept Android licenses optionally (interactive)
Write-Host "If you need to accept Android SDK licenses, run: flutter doctor --android-licenses"

# 9) Run Gradle build with stacktrace
$projAndroid = Join-Path (Get-Location).Path '..\android'
# Ensure we are in project root
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$repoRoot = Resolve-Path "$scriptDir\.." | Select-Object -ExpandProperty Path
$androidDir = Join-Path $repoRoot 'android'
if (-not (Test-Path $androidDir)) { Write-Warning "android folder not found at $androidDir; ensure you run this script from repo root" }
else {
    Push-Location $androidDir
    Write-Host "Running gradlew assembleDebug --stacktrace in $androidDir"
    & .\gradlew.bat assembleDebug --stacktrace
    $code = $LASTEXITCODE
    Pop-Location
    if ($code -ne 0) { Abort "gradlew failed with exit code $code" } else { Write-Host "Gradle build finished successfully." }
}

Write-Host "== Setup script finished =="
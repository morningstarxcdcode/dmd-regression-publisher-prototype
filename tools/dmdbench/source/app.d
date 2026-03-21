module app;

import core.thread;
import core.stdc.stdlib : exit;
import std.algorithm;
import std.algorithm.comparison : max, min;
import std.range : repeat;
import std.array;
import std.conv;
import std.datetime.stopwatch;
import std.datetime.systime : Clock;
import std.datetime.timezone : UTC;
import std.exception;
import std.file;
import std.format;
import std.getopt;
import std.json;
import std.math;
import std.path;
import std.process;
import std.random;
import std.regex;
import std.socket;
import std.stdio;
import std.string;
import std.typecons;

void main(string[] args)
{
    if (args.length < 2)
    {
        usage();
        return;
    }

    auto cmd = args[1];
    auto subArgs = args[2 .. $];

    switch (cmd)
    {
        case "sweep":
            runSweep(subArgs);
            break;
        case "analyze":
            runAnalyze(subArgs);
            break;
        case "trace":
            runTrace(subArgs);
            break;
        case "switch-scale":
            runSwitchScale(subArgs);
            break;
        case "not-done":
            runNotDone(subArgs);
            break;
        case "parser-compare":
            runParserCompare(subArgs);
            break;
        case "perf-probe":
            runPerfProbe(subArgs);
            break;
        case "linux-gap-close":
            runLinuxGapClose(subArgs);
            break;
        case "help":
        case "--help":
        case "-h":
            usage();
            break;
        default:
            stderr.writeln("Unknown command: ", cmd);
            usage();
            return;
    }
}

void usage()
{
    writeln("dmdbench <command> [options]\n");
    writeln("Commands:");
    writeln("  sweep           Run release benchmark sweeps");
    writeln("  analyze         Analyze sweep CSVs and emit reports");
    writeln("  trace           Run -ftime-trace and summarize phases");
    writeln("  switch-scale    Switch-case scaling experiment");
    writeln("  not-done        Run the not-done experiment suite");
    writeln("  parser-compare  Compare parser threading scaling");
    writeln("  perf-probe      Linux perf tooling probe");
    writeln("  linux-gap-close Linux closure workflow");
    writeln("  help            Show this help");
}

struct SweepOptions
{
    string track = "both"; // latest20 | compatible20 | both
    string versionsFile = "versions_compatible20.txt";
    string latestFile = "versions_latest20.txt";
    string latestSource = "snapshot"; // snapshot | refresh | file
    string archiveSource = "cache"; // cache | bootstrap
    bool resolveLatestOnly = false;
    bool prepareCacheOnly = false;
    string benchmark = "benchmark.d";
    int runs = 7;
    int warmups = 2;
    int timeoutSec = 120;
    string cacheDir = ".cache/dmd-releases";
    string trackOutDir = "artifacts";
    string outCsv = ""; // only for single-track
    string dmdArchiveFlavor = "";
    string benchSuite = ""; // optional: core|ctfe|templates|semantics|mixed
}

void runSweep(string[] args)
{
    auto originalArgs = args.dup;
    SweepOptions opt;
    auto help = getopt(
        args,
        "track", &opt.track,
        "versions-file", &opt.versionsFile,
        "latest-file", &opt.latestFile,
        "latest-source", &opt.latestSource,
        "archive-source", &opt.archiveSource,
        "resolve-latest-only", &opt.resolveLatestOnly,
        "prepare-cache-only", &opt.prepareCacheOnly,
        "benchmark", &opt.benchmark,
        "bench-suite", &opt.benchSuite,
        "runs", &opt.runs,
        "warmups", &opt.warmups,
        "timeout-sec", &opt.timeoutSec,
        "cache-dir", &opt.cacheDir,
        "track-out-dir", &opt.trackOutDir,
        "out-csv", &opt.outCsv,
        "archive-flavor", &opt.dmdArchiveFlavor
    );
    enforce(help.helpWanted == false, "");

    string rawValue;
    if (tryGetLongOption(originalArgs, "track", rawValue)) opt.track = rawValue;
    if (tryGetLongOption(originalArgs, "versions-file", rawValue)) opt.versionsFile = rawValue;
    if (tryGetLongOption(originalArgs, "latest-file", rawValue)) opt.latestFile = rawValue;
    if (tryGetLongOption(originalArgs, "latest-source", rawValue)) opt.latestSource = rawValue;
    if (tryGetLongOption(originalArgs, "archive-source", rawValue)) opt.archiveSource = rawValue;
    if (tryGetLongOption(originalArgs, "benchmark", rawValue)) opt.benchmark = rawValue;
    if (tryGetLongOption(originalArgs, "bench-suite", rawValue)) opt.benchSuite = rawValue;
    if (tryGetLongOption(originalArgs, "cache-dir", rawValue)) opt.cacheDir = rawValue;
    if (tryGetLongOption(originalArgs, "track-out-dir", rawValue)) opt.trackOutDir = rawValue;
    if (tryGetLongOption(originalArgs, "out-csv", rawValue)) opt.outCsv = rawValue;
    if (tryGetLongOption(originalArgs, "archive-flavor", rawValue)) opt.dmdArchiveFlavor = rawValue;
    if (tryGetLongOption(originalArgs, "runs", rawValue)) opt.runs = to!int(rawValue);
    if (tryGetLongOption(originalArgs, "warmups", rawValue)) opt.warmups = to!int(rawValue);
    if (tryGetLongOption(originalArgs, "timeout-sec", rawValue)) opt.timeoutSec = to!int(rawValue);
    if (hasLongOption(originalArgs, "latest-file") && !hasLongOption(originalArgs, "latest-source"))
    {
        opt.latestSource = "file";
    }

    if (opt.benchSuite.length)
    {
        opt.benchmark = resolveBenchSuite(opt.benchSuite);
    }

    if (!opt.dmdArchiveFlavor.length)
    {
        opt.dmdArchiveFlavor = resolveArchiveFlavor();
    }

    if (opt.dmdArchiveFlavor.length == 0)
    {
        stderr.writeln("Unsupported host OS for sweep");
        exit(1);
    }

    if (opt.latestSource != "snapshot" && opt.latestSource != "refresh" && opt.latestSource != "file")
    {
        stderr.writeln("Invalid --latest-source: ", opt.latestSource);
        exit(1);
    }

    if (opt.archiveSource != "cache" && opt.archiveSource != "bootstrap")
    {
        stderr.writeln("Invalid --archive-source: ", opt.archiveSource);
        exit(1);
    }

    if ((opt.track == "latest20" || opt.track == "both" || opt.resolveLatestOnly) && !ensureLatestVersionsReady(opt.latestFile, opt.latestSource))
    {
        stderr.writeln("Failed to prepare latest20 versions list");
        exit(1);
    }

    if (opt.resolveLatestOnly)
    {
        writeln(opt.latestFile);
        return;
    }

    if (opt.prepareCacheOnly)
    {
        int rc = 0;
        if (opt.track == "latest20" || opt.track == "both")
        {
            if (prepareTrackCache("latest20", opt.latestFile, opt) != 0) rc = 1;
        }
        if (opt.track == "compatible20" || opt.track == "both")
        {
            if (prepareTrackCache("compatible20", opt.versionsFile, opt) != 0) rc = 1;
        }
        if (rc != 0) exit(3);
        return;
    }

    int rc = 0;
    if (opt.track == "latest20")
    {
        string outCsv = opt.outCsv.length ? opt.outCsv : buildPath(opt.trackOutDir, "latest20", "results_raw.csv");
        if (runTrack("latest20", opt.latestFile, outCsv, opt) != 0) rc = 1;
    }
    else if (opt.track == "compatible20")
    {
        string outCsv = opt.outCsv.length ? opt.outCsv : buildPath(opt.trackOutDir, "compatible20", "results_raw.csv");
        if (runTrack("compatible20", opt.versionsFile, outCsv, opt) != 0) rc = 1;
    }
    else if (opt.track == "both")
    {
        if (runTrack("latest20", opt.latestFile, buildPath(opt.trackOutDir, "latest20", "results_raw.csv"), opt) != 0) rc = 1;
        if (runTrack("compatible20", opt.versionsFile, buildPath(opt.trackOutDir, "compatible20", "results_raw.csv"), opt) != 0) rc = 1;
    }
    else
    {
        stderr.writeln("Invalid --track: ", opt.track);
        exit(1);
    }

    if (rc != 0)
    {
        exit(3);
    }
}

string resolveBenchSuite(string suite)
{
    auto lower = suite.toLower();
    string base = buildPath("benchmarks", "d");
    switch (lower)
    {
        case "core":
            return "benchmark.d";
        case "ctfe":
            return buildPath(base, "ctfe.d");
        case "templates":
            return buildPath(base, "templates.d");
        case "semantics":
            return buildPath(base, "semantics.d");
        case "mixed":
            return buildPath(base, "mixed.d");
        default:
            stderr.writeln("Unknown bench suite: ", suite, " (using benchmark.d)");
            return "benchmark.d";
    }
}

string resolveArchiveFlavor()
{
    version (OSX)
    {
        return "osx";
    }
    else version (Linux)
    {
        return "linux";
    }
    else
    {
        return "";
    }
}

bool refreshLatestVersions(string outputFile)
{
    auto url = "https://downloads.dlang.org/releases/2.x/";
    auto tmpPath = buildPath(tempDir(), "dmdbench_latest_versions.txt");
    if (runCommand(["curl", "-fsSL", url, "-o", tmpPath]).status != 0)
    {
        return false;
    }

    auto text = readText(tmpPath);
    auto regex = regex(r"2\.\d+\.\d+");
    string[] versions;
    foreach (m; matchAll(text, regex))
    {
        versions ~= m.hit;
    }
    versions = versions.array.sort.uniq.array;
    versions.sort!((a, b) => versionLess(a, b));
    if (versions.length < 20)
    {
        return false;
    }
    auto latest = versions[$ - 20 .. $];
    auto content = [
        "# Pinned latest 20 DMD releases snapshot",
        "# Generated: " ~ utcNowStamp(),
        "# Source: https://downloads.dlang.org/releases/2.x/",
        "# Refresh: ./tools/dmdbench/bin/dmdbench sweep --track latest20 --latest-source refresh --resolve-latest-only",
        latest.join("\n")
    ].join("\n") ~ "\n";
    writeText(outputFile, content);
    return true;
}

bool ensureLatestVersionsReady(string outputFile, string sourceMode)
{
    switch (sourceMode)
    {
        case "snapshot":
        case "file":
            if (exists(outputFile)) return true;
            stderr.writeln("Latest versions file not found: ", outputFile);
            stderr.writeln("Run dmdbench sweep --track latest20 --latest-source refresh --resolve-latest-only to refresh it.");
            return false;
        case "refresh":
            if (refreshLatestVersions(outputFile)) return true;
            stderr.writeln("Failed to refresh latest versions snapshot: ", outputFile);
            return false;
        default:
            stderr.writeln("Invalid --latest-source: ", sourceMode);
            return false;
    }
}

struct ExecResult
{
    int status;
    string output;
}

struct CommandResult
{
    int status;
    string output;
    string error;
}

void writeText(string path, string content)
{
    std.file.write(path, content);
}

ExecResult safeExecute(string[] cmd)
{
    try
    {
        auto result = execute(cmd);
        return ExecResult(result.status, result.output);
    }
    catch (Exception)
    {
        return ExecResult(1, "");
    }
}

CommandResult runCommand(string[] cmd)
{
    auto res = safeExecute(cmd);
    return CommandResult(res.status, res.output, "");
}

int[] versionKey(string versionText)
{
    int[] parts;
    foreach (p; versionText.split("."))
    {
        try parts ~= to!int(p);
        catch (Exception) parts ~= 0;
    }
    while (parts.length < 3) parts ~= 0;
    return parts[0 .. 3];
}

bool versionLess(string a, string b)
{
    auto ka = versionKey(a);
    auto kb = versionKey(b);
    foreach (i; 0 .. 3)
    {
        if (ka[i] < kb[i]) return true;
        if (ka[i] > kb[i]) return false;
    }
    return a < b;
}

string[] loadVersions(string path)
{
    if (!exists(path)) return [];
    string[] lines = readText(path).splitLines();
    string[] versions;
    foreach (line; lines)
    {
        auto trimmed = line.strip;
        if (!trimmed.length || trimmed.startsWith("#")) continue;
        versions ~= trimmed;
    }
    return versions;
}

string resolveExtractedDmdPath(string extractDir, string flavor)
{
    string[] candidates;
    if (flavor == "osx")
    {
        candidates = [buildPath(extractDir, "osx", "bin", "dmd"), buildPath(extractDir, "osx", "bin64", "dmd")];
    }
    else if (flavor == "linux")
    {
        candidates = [buildPath(extractDir, "linux", "bin64", "dmd"), buildPath(extractDir, "linux", "bin", "dmd")];
    }

    foreach (c; candidates)
    {
        if (exists(c)) return c;
    }

    return "";
}

string cpuBrand()
{
    version (OSX)
    {
        auto res = safeExecute(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"]);
        auto text = res.output.strip;
        if (text.length && !text.startsWith("sysctl:") && !text.canFind("Operation not permitted")) return text;
    }
    version (Linux)
    {
        if (exists("/proc/cpuinfo"))
        {
            foreach (line; readText("/proc/cpuinfo").splitLines())
            {
                if (line.startsWith("model name"))
                {
                    auto parts = line.split(":");
                    if (parts.length >= 2) return parts[1].strip;
                }
            }
        }
    }
    return "unknown-cpu";
}

string osValue()
{
    auto res = safeExecute(["uname", "-a"]);
    return res.output.strip;
}

string hostName()
{
    auto res = safeExecute(["hostname"]);
    auto text = res.output.strip;
    if (text.length) return text;
    return "unknown-host";
}

string csvEscape(string value)
{
    auto escaped = value.replace("\"", "\"\"");
    return "\"" ~ escaped ~ "\"";
}

void appendRow(string outCsv, string[] fields)
{
    auto line = fields.map!csvEscape.join(",") ~ "\n";
    append(outCsv, line);
}

string classifyFailure(int exitCode, string errorHint)
{
    if (exitCode == 124) return "timeout";
    if (exitCode == -11 || exitCode == 139 || exitCode == 134 || errorHint.canFind("Segmentation fault"))
        return "runtime_crash";
    if (errorHint.canFind("unrecognized switch")) return "unsupported_switch";
    if (errorHint.canFind("linker exited")) return "linker_error";
    if (errorHint.canFind("download failed")) return "download_fail";
    if (errorHint.canFind("archive extraction failed")) return "extract_fail";
    return "compile_error";
}

struct CompileResult
{
    long elapsedMs;
    int exitCode;
    long artifactSize;
    string errorHint;
}

CompileResult measureCompile(string dmdBin, string benchmarkPath, string outObj, int timeoutSec)
{
    string[] cmd = [dmdBin, benchmarkPath, "-of=" ~ outObj, "-O", "-c"];
    auto sw = StopWatch(AutoStart.yes);
    auto proc = spawnProcess(cmd);

    shared bool done = false;
    shared int exitCode = -1;

    auto t = new Thread({
        try
        {
            exitCode = proc.wait();
        }
        catch (Exception)
        {
            exitCode = -1;
        }
        done = true;
    });
    t.start();

    auto start = MonoTime.currTime;
    while (!done)
    {
        if ((MonoTime.currTime - start).total!"seconds" > timeoutSec)
        {
            terminateProcess(proc);
            exitCode = 124;
            done = true;
            break;
        }
        Thread.sleep(dur!"msecs"(25));
    }

    t.join();
    sw.stop();

    auto elapsedMs = cast(long) sw.peek.total!"msecs";
    string hint = "";

    long size = -1;
    if (exitCode == 0 && exists(outObj))
    {
        size = cast(long) getSize(outObj);
    }

    return CompileResult(elapsedMs, exitCode, size, hint);
}

void terminateProcess(Pid pid)
{
    version (Posix)
    {
        import core.sys.posix.signal : kill, SIGKILL;
        kill(pid.osHandle, SIGKILL);
    }
    else
    {
        // Best-effort no-op for unsupported platforms.
    }
}

int ensureArchiveCached(string versionText, string tarball, string url, string archiveSource)
{
    if (exists(tarball)) return 0;
    if (archiveSource != "bootstrap")
    {
        stderr.writeln("Cache miss for ", versionText, ": ", tarball);
        stderr.writeln("Run bootstrap_external_cache.sh or rerun with --archive-source bootstrap.");
        return 1;
    }

    mkdirRecurse(dirName(tarball));
    auto dl = runCommand(["curl", "-fL", "--retry", "3", "--retry-delay", "2", "-o", tarball, url]);
    return dl.status == 0 ? 0 : 2;
}

int prepareTrackCache(string trackName, string versionsFile, SweepOptions opt)
{
    auto versions = loadVersions(versionsFile);
    if (!versions.length)
    {
        stderr.writeln("No versions found in ", versionsFile);
        return 1;
    }

    int rc = 0;
    foreach (ver; versions)
    {
        auto tarball = buildPath(opt.cacheDir, format("dmd.%s.%s.tar.xz", ver, opt.dmdArchiveFlavor));
        auto url = format("https://downloads.dlang.org/releases/2.x/%s/dmd.%s.%s.tar.xz", ver, ver, opt.dmdArchiveFlavor);
        if (ensureArchiveCached(ver, tarball, url, opt.archiveSource) != 0)
        {
            rc = 1;
        }
    }
    return rc;
}

int runTrack(string trackName, string versionsFile, string outCsv, SweepOptions opt)
{
    auto versions = loadVersions(versionsFile);
    if (!versions.length)
    {
        stderr.writeln("No versions found in ", versionsFile);
        return 1;
    }

    mkdirRecurse(dirName(outCsv));
    writeText(outCsv, "track,version,run_idx,is_warmup,time_ms,artifact_kind,artifact_size_bytes,ok,error_code,failure_kind,error_hint,hostname,cpu_brand,os,timestamp\n");

    auto host = hostName();
    auto cpu = cpuBrand();
    auto osVal = osValue();
    int envFail = 0;

    foreach (ver; versions)
    {
        auto tarball = buildPath(opt.cacheDir, format("dmd.%s.%s.tar.xz", ver, opt.dmdArchiveFlavor));
        auto extractDir = buildPath(opt.cacheDir, format("dmd-%s-%s", ver, opt.dmdArchiveFlavor));
        auto url = format("https://downloads.dlang.org/releases/2.x/%s/dmd.%s.%s.tar.xz", ver, ver, opt.dmdArchiveFlavor);

        auto dmdBin = resolveExtractedDmdPath(extractDir, opt.dmdArchiveFlavor);
        if (!dmdBin.length)
        {
            auto archiveRc = ensureArchiveCached(ver, tarball, url, opt.archiveSource);
            if (archiveRc != 0)
            {
                auto hint = archiveRc == 1 ? "release archive cache miss; run bootstrap_external_cache.sh" : "download failed";
                auto kind = archiveRc == 1 ? "cache_miss" : "download_fail";
                auto code = archiveRc == 1 ? "CACHE_MISS" : "DL_FAIL";
                appendRow(outCsv, [trackName, ver, "-1", "0", "0", "object", "-1", "0", code, kind, hint, host, cpu, osVal, utcNowStamp()]);
                envFail = 1;
                continue;
            }

            if (exists(extractDir)) rmdirRecurse(extractDir);
            mkdirRecurse(extractDir);
            auto ex = runCommand(["tar", "-xf", tarball, "-C", extractDir, "--strip-components=1"]);
            if (ex.status != 0)
            {
                appendRow(outCsv, [trackName, ver, "-1", "0", "0", "object", "-1", "0", "EXTRACT_FAIL", "extract_fail", "archive extraction failed", host, cpu, osVal, utcNowStamp()]);
                envFail = 1;
                continue;
            }
        }

        dmdBin = resolveExtractedDmdPath(extractDir, opt.dmdArchiveFlavor);
        if (!dmdBin.length)
        {
            appendRow(outCsv, [trackName, ver, "-1", "0", "0", "object", "-1", "0", "BIN_NOT_FOUND", "binary_not_found", "unable to locate dmd executable", host, cpu, osVal, utcNowStamp()]);
            envFail = 1;
            continue;
        }

        int totalRuns = opt.warmups + opt.runs;
        foreach (runNo; 1 .. totalRuns + 1)
        {
            int isWarmup = runNo <= opt.warmups ? 1 : 0;
            int csvRunIdx = isWarmup ? runNo : runNo - opt.warmups;

            auto outObj = buildPath(opt.trackOutDir, format(".tmp_%s_%s_%s.o", trackName, ver.replace(".", "_"), runNo));
            auto res = measureCompile(dmdBin, opt.benchmark, outObj, opt.timeoutSec);

            int ok = res.exitCode == 0 ? 1 : 0;
            string failureKind = "";
            string errorHint = res.errorHint;
            if (!ok)
            {
                failureKind = classifyFailure(res.exitCode, errorHint);
            }
            else
            {
                errorHint = "";
            }

            appendRow(outCsv, [trackName, ver, to!string(csvRunIdx), to!string(isWarmup), to!string(res.elapsedMs), "object", to!string(res.artifactSize), to!string(ok), to!string(res.exitCode), failureKind, errorHint, host, cpu, osVal, utcNowStamp()]);
            if (exists(outObj)) remove(outObj);
        }
    }

    return envFail;
}

string utcNowStamp()
{
    return Clock.currTime(UTC()).toISOString();
}

struct VersionStats
{
    string versionLabel;
    int nRuns;
    int nOk;
    int nFail;
    double medianMs;
    double madMs;
    double meanMs;
    double ciLowMs;
    double ciHighMs;
    double artifactSize;
    bool hasTiming;
    bool hasSize;
}

struct Methodology
{
    string benchmarkLabel;
    string benchmarkDescription;
    string compileCommand;
    int measuredRuns;
    int warmupRuns;
    string hostname;
    string cpuBrand;
    string osValue;
    string traceCompilerLabel;
}

struct TrackResult
{
    string track;
    VersionStats[] summary;
    RegressionRow[] regressions;
    AdvancedRegressionRow[] advanced;
    int[string] failureCounts;
    int totalRows;
    Methodology methodology;
}

void runAnalyze(string[] args)
{
    string input = "";
    string inputDir = "artifacts";
    string tracks = "compatible20";
    string outDir = "artifacts";
    string summaryCsv = "results_summary.csv";
    string regressionCsv = "regression_table.csv";
    string regressionAdvancedCsv = "regression_table_advanced.csv";
    string reportName = "report.md";
    int bootstrapSamples = 2000;
    double regressionThreshold = 10.0;
    int advancedWindow = 3;
    double advancedZThreshold = 2.0;
    double advancedScoreThreshold = 2.5;
    double advancedCusumThreshold = 3.0;
    double advancedCusumK = 0.5;
    int changepointWindow = 3;
    double changepointThreshold = 4.0;
    double consensusVarianceThreshold = 1.5;
    int consensusPhaseBuckets = 3;
    int consensusPhaseTop = 5;
    string tracePhaseSummary = "artifacts/trace_phase_summary.csv";
    string traceSummaryCsv = "artifacts/trace_phase_summary.csv";
    string granularityCsv = "artifacts/trace_granularity_sweep.csv";
    bool noPlot = false;
    string benchmarkLabel = "benchmark.d";
    string benchmarkDescription = "synthetic template/CTFE-heavy D source";
    string compileCommand = "dmd benchmark.d -O -c -of=<temp>.o";
    string traceCompilerLabel = "nightly DMD build";

    auto help = getopt(
        args,
        "input", &input,
        "input-dir", &inputDir,
        "tracks", &tracks,
        "out-dir", &outDir,
        "summary-csv", &summaryCsv,
        "regression-csv", &regressionCsv,
        "regression-advanced-csv", &regressionAdvancedCsv,
        "report", &reportName,
        "bootstrap-samples", &bootstrapSamples,
        "regression-threshold", &regressionThreshold,
        "advanced-window", &advancedWindow,
        "advanced-z", &advancedZThreshold,
        "advanced-score", &advancedScoreThreshold,
        "advanced-cusum-threshold", &advancedCusumThreshold,
        "advanced-cusum-k", &advancedCusumK,
        "changepoint-window", &changepointWindow,
        "changepoint-threshold", &changepointThreshold,
        "consensus-variance-threshold", &consensusVarianceThreshold,
        "consensus-phase-buckets", &consensusPhaseBuckets,
        "consensus-phase-top", &consensusPhaseTop,
        "trace-phase-summary", &tracePhaseSummary,
        "trace-summary", &traceSummaryCsv,
        "granularity-csv", &granularityCsv,
        "no-plot", &noPlot,
        "benchmark-label", &benchmarkLabel,
        "benchmark-description", &benchmarkDescription,
        "compile-command", &compileCommand,
        "trace-compiler-label", &traceCompilerLabel
    );
    enforce(help.helpWanted == false, "");

    string[] trackList;
    TrackResult[string] trackResults;
    if (input.length)
    {
        auto result = analyzeSingle(input, outDir, "", summaryCsv, regressionCsv, regressionAdvancedCsv, reportName, bootstrapSamples, regressionThreshold, advancedWindow, advancedZThreshold, advancedScoreThreshold, advancedCusumThreshold, advancedCusumK, changepointWindow, changepointThreshold, benchmarkLabel, benchmarkDescription, compileCommand, traceCompilerLabel, noPlot);
        trackResults["single"] = result;
        writeMultiTrackReport(buildPath(outDir, reportName), trackResults, traceSummaryCsv, granularityCsv);
        return;
    }

    trackList = tracks.split(',').map!(a => a.strip).filter!(a => a.length).array;
    foreach (track; trackList)
    {
        auto csvPath = buildPath(inputDir, track, "results_raw.csv");
        if (!exists(csvPath))
        {
            stderr.writeln("Missing input CSV: ", csvPath);
            continue;
        }
        auto result = analyzeSingle(csvPath, buildPath(outDir, track), track, summaryCsv, regressionCsv, regressionAdvancedCsv, reportName, bootstrapSamples, regressionThreshold, advancedWindow, advancedZThreshold, advancedScoreThreshold, advancedCusumThreshold, advancedCusumK, changepointWindow, changepointThreshold, benchmarkLabel, benchmarkDescription, compileCommand, traceCompilerLabel, noPlot);
        trackResults[track] = result;
    }

    if (trackList.length > 1)
    {
        writeConsensusAdvanced(outDir, trackList, regressionAdvancedCsv, tracePhaseSummary, consensusVarianceThreshold, consensusPhaseBuckets, consensusPhaseTop);
        copyCompatibleArtifacts(outDir, summaryCsv, regressionCsv, regressionAdvancedCsv, noPlot);
    }
    if (trackResults.length)
    {
        writeMultiTrackReport(buildPath(outDir, reportName), trackResults, traceSummaryCsv, granularityCsv);
    }
}

TrackResult analyzeSingle(
    string inputCsv,
    string outDir,
    string track,
    string summaryCsv,
    string regressionCsv,
    string regressionAdvancedCsv,
    string reportName,
    int bootstrapSamples,
    double regressionThreshold,
    int advancedWindow,
    double advancedZThreshold,
    double advancedScoreThreshold,
    double advancedCusumThreshold,
    double advancedCusumK,
    int changepointWindow,
    double changepointThreshold,
    string benchmarkLabel,
    string benchmarkDescription,
    string compileCommand,
    string traceCompilerLabel,
    bool noPlot)
{
    auto rows = loadCsv(inputCsv);
    if (!rows.length)
    {
        stderr.writeln("No rows found in ", inputCsv);
        return TrackResult();
    }

    auto summary = summarizeVersions(rows, bootstrapSamples);
    auto regressions = regressionScan(summary, regressionThreshold, track);
    auto advancedRegressions = regressionScanAdvanced(summary, regressionThreshold, track, advancedWindow, advancedZThreshold, advancedScoreThreshold, advancedCusumThreshold, advancedCusumK, changepointWindow, changepointThreshold);
    auto failureCounts = summarizeFailures(rows);
    auto methodology = inferMethodology(rows, benchmarkLabel, benchmarkDescription, compileCommand, traceCompilerLabel);

    mkdirRecurse(outDir);
    writeSummaryCsv(buildPath(outDir, summaryCsv), summary, track);
    writeRegressionCsv(buildPath(outDir, regressionCsv), regressions, track);
    writeSummaryJson(buildPath(outDir, "results_summary.json"), summary, track);
    writeRegressionJson(buildPath(outDir, "regression_table.json"), regressions, track);
    writeAdvancedRegressionCsv(buildPath(outDir, regressionAdvancedCsv), advancedRegressions, track);
    writeAdvancedRegressionJson(buildPath(outDir, "regression_table_advanced.json"), advancedRegressions, track);
    writeReport(buildPath(outDir, reportName), summary, regressions, advancedRegressions, track, benchmarkLabel, benchmarkDescription, compileCommand, traceCompilerLabel);
    if (!noPlot)
    {
        writeCompilePlotSvg(buildPath(outDir, "compile_time_trend.svg"), summary, regressions, methodology, format("DMD Compile Wall Time for %s (%s)", benchmarkLabel, track.length ? track : "single"));
        writeArtifactPlotSvg(buildPath(outDir, "artifact_size_trend.svg"), summary, methodology, format("DMD Compile-Only Object Size for %s (%s)", benchmarkLabel, track.length ? track : "single"));
    }
    writeManifest(buildPath(outDir, "manifest.json"), track);

    TrackResult result;
    result.track = track;
    result.summary = summary;
    result.regressions = regressions;
    result.advanced = advancedRegressions;
    result.failureCounts = failureCounts;
    result.totalRows = cast(int) rows.length;
    result.methodology = methodology;
    return result;
}

struct CsvRow
{
    string[string] data;
}

CsvRow[] loadCsv(string path)
{
    auto lines = readText(path).splitLines();
    if (!lines.length) return [];
    auto headers = parseCsvLine(lines[0]);
    CsvRow[] rows;
    foreach (line; lines[1 .. $])
    {
        if (!line.length) continue;
        auto fields = parseCsvLine(line.stripRight("\r"));
        if (fields.length == 0) continue;
        string[string] row;
        foreach (i, header; headers)
        {
            if (i < fields.length) row[header] = fields[i];
        }
        rows ~= CsvRow(row);
    }
    return rows;
}

string[] parseCsvLine(string line)
{
    string[] fields;
    string current;
    bool inQuotes = false;
    for (size_t i = 0; i < line.length; i++)
    {
        auto c = line[i];
        if (inQuotes)
        {
            if (c == '"')
            {
                if (i + 1 < line.length && line[i + 1] == '"')
                {
                    current ~= '"';
                    i++;
                }
                else
                {
                    inQuotes = false;
                }
            }
            else
            {
                current ~= c;
            }
        }
        else
        {
            if (c == ',')
            {
                fields ~= current;
                current = "";
            }
            else if (c == '"')
            {
                inQuotes = true;
            }
            else
            {
                current ~= c;
            }
        }
    }
    fields ~= current;
    return fields;
}

string mostCommonField(CsvRow[] rows, string key, string fallback)
{
    int[string] counts;
    foreach (row; rows)
    {
        auto value = row.data.get(key, "").strip;
        if (!value.length) continue;
        counts[value] = counts.get(value, 0) + 1;
    }
    string best = fallback;
    int bestCount = -1;
    foreach (k, v; counts)
    {
        if (v > bestCount)
        {
            best = k;
            bestCount = v;
        }
    }
    return best;
}

Methodology inferMethodology(
    CsvRow[] rows,
    string benchmarkLabel,
    string benchmarkDescription,
    string compileCommand,
    string traceCompilerLabel)
{
    int[string] warmCounts;
    int[string] measuredCounts;
    foreach (row; rows)
    {
        auto ver = row.data.get("version", "").strip;
        if (!ver.length) continue;
        auto isWarmup = row.data.get("is_warmup", "0");
        if (isWarmup == "1")
            warmCounts[ver] = warmCounts.get(ver, 0) + 1;
        else
            measuredCounts[ver] = measuredCounts.get(ver, 0) + 1;
    }

    int warmups = 0;
    int measured = 0;
    foreach (ver, count; measuredCounts)
    {
        measured = count;
        warmups = warmCounts.get(ver, 0);
        break;
    }

    Methodology m;
    m.benchmarkLabel = benchmarkLabel;
    m.benchmarkDescription = benchmarkDescription;
    m.compileCommand = compileCommand;
    m.measuredRuns = measured;
    m.warmupRuns = warmups;
    m.hostname = mostCommonField(rows, "hostname", "unknown-host");
    m.cpuBrand = mostCommonField(rows, "cpu_brand", "unknown-cpu");
    m.osValue = mostCommonField(rows, "os", "unknown-os");
    m.traceCompilerLabel = traceCompilerLabel;
    return m;
}

int[string] summarizeFailures(CsvRow[] rows)
{
    int[string] counts;
    foreach (row; rows)
    {
        auto ok = row.data.get("ok", "0") == "1";
        if (ok) continue;
        auto kind = row.data.get("failure_kind", "unknown").strip;
        if (!kind.length) kind = "unknown";
        counts[kind] = counts.get(kind, 0) + 1;
    }
    return counts;
}

VersionStats[] summarizeVersions(CsvRow[] rows, int bootstrapSamples)
{
    string[string] nRuns;
    string[string] nOk;
    string[string] nFail;
    double[][string] times;
    double[][string] sizes;

    foreach (row; rows)
    {
        auto ver = row.data.get("version", "").strip;
        if (!ver.length) continue;
        if (row.data.get("is_warmup", "0") != "0") continue;

        nRuns[ver] = to!string(to!int(nRuns.get(ver, "0")) + 1);
        auto ok = row.data.get("ok", "0") == "1";
        if (ok)
        {
            nOk[ver] = to!string(to!int(nOk.get(ver, "0")) + 1);
        }
        else
        {
            nFail[ver] = to!string(to!int(nFail.get(ver, "0")) + 1);
        }

        if (ok)
        {
            auto t = to!double(row.data.get("time_ms", "0"));
            if (t > 0) times[ver] ~= t;
            auto size = to!double(row.data.get("artifact_size_bytes", "-1"));
            if (size > 0) sizes[ver] ~= size;
        }
    }

    string[] versionList = (times.keys ~ nRuns.keys).array.uniq.array;
    versionList.sort!((a, b) => versionLess(a, b));

    VersionStats[] summary;
    foreach (ver; versionList)
    {
        auto vTimes = times.get(ver, []);
        auto vSizes = sizes.get(ver, []);

        VersionStats stat;
        stat.versionLabel = ver;
        stat.nRuns = to!int(nRuns.get(ver, "0"));
        stat.nOk = to!int(nOk.get(ver, "0"));
        stat.nFail = to!int(nFail.get(ver, "0"));

        if (vTimes.length)
        {
            stat.medianMs = median(vTimes);
            stat.madMs = mad(vTimes);
            stat.meanMs = mean(vTimes);
            auto ci = bootstrapCi(vTimes, bootstrapSamples);
            stat.ciLowMs = ci[0];
            stat.ciHighMs = ci[1];
            stat.hasTiming = true;
        }
        else
        {
            stat.hasTiming = false;
        }

        if (vSizes.length)
        {
            stat.artifactSize = median(vSizes);
            stat.hasSize = true;
        }
        else
        {
            stat.hasSize = false;
        }

        summary ~= stat;
    }

    return summary;
}

struct RegressionRow
{
    string fromVersion;
    string toVersion;
    string pctChangeCompileMs;
    string pctChangeArtifactSize;
    int ciSeparated;
    int compileRegression;
    int sizeRegression;
    string flagReason;
}

struct AdvancedRegressionRow
{
    string fromVersion;
    string toVersion;
    string baselineCount;
    string baselineMedianMs;
    string baselineMadMs;
    string pctChangeBaseline;
    string robustZ;
    string trendSlopePct;
    string cusumScore;
    string cusumScoreDown;
    string baselineNoiseRatio;
    string noiseRatio;
    string varianceShiftRatio;
    string changepointScore;
    int changepointFlag;
    string advancedScore;
    int advancedRegression;
    string improvementScore;
    int advancedImprovement;
    string signals;
}

RegressionRow[] regressionScan(VersionStats[] summary, double threshold, string track)
{
    RegressionRow[] rows;
    foreach (i; 1 .. summary.length)
    {
        auto prev = summary[i - 1];
        auto curr = summary[i];

        string pctChange = "";
        bool ciSeparated = false;
        bool compileRegression = false;

        if (prev.hasTiming && curr.hasTiming && prev.medianMs != 0)
        {
            auto pct = ((curr.medianMs - prev.medianMs) / prev.medianMs) * 100.0;
            pctChange = format("%.3f", pct);
            ciSeparated = curr.ciLowMs > prev.ciHighMs;
            compileRegression = pct >= threshold && ciSeparated;
        }

        string sizeChange = "";
        bool sizeRegression = false;
        if (prev.hasSize && curr.hasSize && prev.artifactSize != 0)
        {
            auto pct = ((curr.artifactSize - prev.artifactSize) / prev.artifactSize) * 100.0;
            sizeChange = format("%.3f", pct);
            sizeRegression = pct >= 5.0;
        }

        string[] reasons;
        if (compileRegression) reasons ~= "compile_time_jump";
        if (sizeRegression) reasons ~= "artifact_size_jump";

        rows ~= RegressionRow(
            prev.versionLabel,
            curr.versionLabel,
            pctChange,
            sizeChange,
            ciSeparated ? 1 : 0,
            compileRegression ? 1 : 0,
            sizeRegression ? 1 : 0,
            reasons.join(";")
        );
    }
    return rows;
}

double[] baselineMedians(VersionStats[] summary, size_t idx, int window)
{
    double[] values;
    if (window <= 0 || idx == 0) return values;
    int remaining = window;
    for (long i = cast(long)idx - 1; i >= 0 && remaining > 0; i--)
    {
        auto stat = summary[cast(size_t)i];
        if (!stat.hasTiming) continue;
        values ~= stat.medianMs;
        remaining--;
    }
    return values;
}

double linearSlope(double[] values)
{
    auto n = values.length;
    if (n < 2) return double.nan;
    double sumX = 0;
    double sumY = 0;
    double sumXY = 0;
    double sumXX = 0;
    foreach (i, v; values)
    {
        double x = cast(double)i;
        sumX += x;
        sumY += v;
        sumXY += x * v;
        sumXX += x * x;
    }
    auto denom = n * sumXX - sumX * sumX;
    if (denom == 0) return double.nan;
    return (n * sumXY - sumX * sumY) / denom;
}

double[] changePointWindowMedians(VersionStats[] summary, size_t idx, int window, bool leftSide)
{
    double[] values;
    if (window <= 0) return values;
    if (leftSide)
    {
        int remaining = window;
        for (long i = cast(long)idx - 1; i >= 0 && remaining > 0; i--)
        {
            auto stat = summary[cast(size_t)i];
            if (!stat.hasTiming) continue;
            values ~= stat.medianMs;
            remaining--;
        }
    }
    else
    {
        int remaining = window;
        for (size_t i = idx; i < summary.length && remaining > 0; i++)
        {
            auto stat = summary[i];
            if (!stat.hasTiming) continue;
            values ~= stat.medianMs;
            remaining--;
        }
    }
    return values;
}

double segmentBic(double[] values)
{
    auto n = values.length;
    if (n < 2) return double.nan;
    auto mu = mean(values);
    double rss = 0;
    foreach (v; values)
    {
        auto diff = v - mu;
        rss += diff * diff;
    }
    if (rss <= 0) rss = 1e-9;
    auto k = 2.0; // mean + variance
    auto nDouble = cast(double) n;
    return nDouble * log(rss / nDouble) + k * log(nDouble);
}

double changePointBicScore(double[] left, double[] right)
{
    if (left.length < 2 || right.length < 2) return double.nan;
    double[] combined;
    combined ~= left;
    combined ~= right;
    auto bicSingle = segmentBic(combined);
    auto bicSplit = segmentBic(left) + segmentBic(right);
    if (isNaN(bicSingle) || isNaN(bicSplit)) return double.nan;
    return bicSingle - bicSplit;
}

AdvancedRegressionRow[] regressionScanAdvanced(
    VersionStats[] summary,
    double pctThreshold,
    string track,
    int window,
    double zThreshold,
    double scoreThreshold,
    double cusumThreshold,
    double cusumK,
    int changepointWindow,
    double changepointThreshold)
{
    AdvancedRegressionRow[] rows;
    double cusumPos = 0;
    double cusumNeg = 0;
    foreach (i; 1 .. summary.length)
    {
        auto prev = summary[i - 1];
        auto curr = summary[i];

        auto baseline = baselineMedians(summary, i, window);
        double baselineMedian = double.nan;
        double baselineMad = double.nan;
        if (baseline.length)
        {
            baselineMedian = median(baseline);
            baselineMad = mad(baseline);
        }

        double pctChange = double.nan;
        double robustZ = double.nan;
        double baselineNoise = double.nan;
        double noiseRatio = double.nan;
        double varianceShift = double.nan;
        double trendSlope = double.nan;
        double cusumScore = cusumPos;
        double cusumScoreDown = cusumNeg;
        double changepointScore = double.nan;
        bool changepointFlag = false;
        double advancedScore = double.nan;
        bool advancedRegression = false;
        double improvementScore = double.nan;
        bool advancedImprovement = false;
        string[] signals;

        if (curr.hasTiming && baseline.length && baselineMedian > 0)
        {
            pctChange = ((curr.medianMs - baselineMedian) / baselineMedian) * 100.0;
            auto scale = max(baselineMad, baselineMedian * 0.01);
            robustZ = (curr.medianMs - baselineMedian) / scale;
            noiseRatio = curr.madMs / curr.medianMs;
            trendSlope = linearSlope(baseline);
            baselineNoise = baselineMad / baselineMedian;
            if (baselineNoise > 0) varianceShift = noiseRatio / baselineNoise;

            auto standardized = (curr.medianMs - baselineMedian) / scale;
            cusumPos = max(0.0, cusumPos + standardized - cusumK);
            cusumNeg = min(0.0, cusumNeg + standardized + cusumK);
            cusumScore = cusumPos;
            cusumScoreDown = cusumNeg;

            auto leftWindow = changePointWindowMedians(summary, i, changepointWindow, true);
            auto rightWindow = changePointWindowMedians(summary, i, changepointWindow, false);
            changepointScore = changePointBicScore(leftWindow, rightWindow);
            if (!isNaN(changepointScore) && changepointScore >= changepointThreshold)
            {
                changepointFlag = true;
                signals ~= "change_point";
            }

            auto pctScore = max(0.0, pctChange / pctThreshold);
            auto zScore = max(0.0, robustZ / zThreshold);
            auto ciSignal = (prev.hasTiming && curr.hasTiming && curr.ciLowMs > prev.ciHighMs) ? 1.0 : 0.0;
            auto cusumSignal = cusumPos > cusumThreshold ? 1.0 : 0.0;
            auto cpSignal = changepointFlag ? 1.0 : 0.0;
            auto noisePenalty = 1.0 + max(0.0, noiseRatio - 0.05) * 2.0;
            advancedScore = (pctScore + zScore + ciSignal + cusumSignal + cpSignal) / noisePenalty;

            if (pctChange >= pctThreshold) signals ~= "pct_jump";
            if (robustZ >= zThreshold) signals ~= "robust_z";
            if (ciSignal > 0.0) signals ~= "ci_sep";
            if (cusumSignal > 0.0) signals ~= "cusum";
            if (!isNaN(varianceShift) && varianceShift >= 1.5) signals ~= "variance_shift";
            if (trendSlope > 0 && baselineMedian > 0)
            {
                auto slopePct = (trendSlope / baselineMedian) * 100.0;
                if (slopePct > 0.5) signals ~= "trend_up";
            }

            advancedRegression = advancedScore >= scoreThreshold && pctChange >= pctThreshold && robustZ >= zThreshold;

            auto pctImproveScore = max(0.0, (-pctChange) / pctThreshold);
            auto zImproveScore = max(0.0, (-robustZ) / zThreshold);
            auto ciImproveSignal = (prev.hasTiming && curr.hasTiming && curr.ciHighMs < prev.ciLowMs) ? 1.0 : 0.0;
            auto cusumImproveSignal = cusumNeg < -cusumThreshold ? 1.0 : 0.0;
            improvementScore = (pctImproveScore + zImproveScore + ciImproveSignal + cusumImproveSignal + cpSignal) / noisePenalty;
            if (pctChange <= -pctThreshold) signals ~= "pct_drop";
            if (robustZ <= -zThreshold) signals ~= "robust_z_down";
            if (ciImproveSignal > 0.0) signals ~= "ci_sep_down";
            if (cusumImproveSignal > 0.0) signals ~= "cusum_down";
            if (trendSlope < 0 && baselineMedian > 0)
            {
                auto slopePct = (trendSlope / baselineMedian) * 100.0;
                if (slopePct < -0.5) signals ~= "trend_down";
            }
            advancedImprovement = improvementScore >= scoreThreshold && pctChange <= -pctThreshold && robustZ <= -zThreshold;
        }

        rows ~= AdvancedRegressionRow(
            prev.versionLabel,
            curr.versionLabel,
            baseline.length ? to!string(baseline.length) : "",
            isNaN(baselineMedian) ? "" : format("%.3f", baselineMedian),
            isNaN(baselineMad) ? "" : format("%.3f", baselineMad),
            isNaN(pctChange) ? "" : format("%.3f", pctChange),
            isNaN(robustZ) ? "" : format("%.3f", robustZ),
            isNaN(trendSlope) || isNaN(baselineMedian) ? "" : format("%.3f", (trendSlope / baselineMedian) * 100.0),
            isNaN(cusumScore) ? "" : format("%.3f", cusumScore),
            isNaN(cusumScoreDown) ? "" : format("%.3f", cusumScoreDown),
            isNaN(baselineNoise) ? "" : format("%.3f", baselineNoise),
            isNaN(noiseRatio) ? "" : format("%.3f", noiseRatio),
            isNaN(varianceShift) ? "" : format("%.3f", varianceShift),
            isNaN(changepointScore) ? "" : format("%.3f", changepointScore),
            changepointFlag ? 1 : 0,
            isNaN(advancedScore) ? "" : format("%.3f", advancedScore),
            advancedRegression ? 1 : 0,
            isNaN(improvementScore) ? "" : format("%.3f", improvementScore),
            advancedImprovement ? 1 : 0,
            signals.join(";")
        );
    }
    return rows;
}

void writeSummaryCsv(string path, VersionStats[] summary, string track)
{
    string header = "track,version,n_runs,n_ok,n_fail,median_ms,mad_ms,mean_ms,ci_low_ms,ci_high_ms,artifact_size_bytes\n";
    writeText(path, header);
    foreach (stat; summary)
    {
        string line = format(
            "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n",
            track,
            stat.versionLabel,
            stat.nRuns,
            stat.nOk,
            stat.nFail,
            stat.hasTiming ? format("%.3f", stat.medianMs) : "",
            stat.hasTiming ? format("%.3f", stat.madMs) : "",
            stat.hasTiming ? format("%.3f", stat.meanMs) : "",
            stat.hasTiming ? format("%.3f", stat.ciLowMs) : "",
            stat.hasTiming ? format("%.3f", stat.ciHighMs) : "",
            stat.hasSize ? format("%.3f", stat.artifactSize) : ""
        );
        append(path, line);
    }
}

void writeRegressionCsv(string path, RegressionRow[] rows, string track)
{
    string header = "track,from_version,to_version,pct_change_compile_ms,pct_change_artifact_size,ci_separated,compile_regression,size_regression,flag_reason\n";
    writeText(path, header);
    foreach (row; rows)
    {
        string line = format(
            "%s,%s,%s,%s,%s,%s,%s,%s,%s\n",
            track,
            row.fromVersion,
            row.toVersion,
            row.pctChangeCompileMs,
            row.pctChangeArtifactSize,
            row.ciSeparated,
            row.compileRegression,
            row.sizeRegression,
            row.flagReason
        );
        append(path, line);
    }
}

void writeAdvancedRegressionCsv(string path, AdvancedRegressionRow[] rows, string track)
{
    string header = "track,from_version,to_version,baseline_count,baseline_median_ms,baseline_mad_ms,pct_change_baseline,robust_z,trend_slope_pct,cusum_score,cusum_score_down,baseline_noise_ratio,noise_ratio,variance_shift_ratio,changepoint_score,changepoint_flag,advanced_score,advanced_regression,improvement_score,advanced_improvement,signals\n";
    writeText(path, header);
    foreach (row; rows)
    {
        string line = format(
            "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n",
            track,
            row.fromVersion,
            row.toVersion,
            row.baselineCount,
            row.baselineMedianMs,
            row.baselineMadMs,
            row.pctChangeBaseline,
            row.robustZ,
            row.trendSlopePct,
            row.cusumScore,
            row.cusumScoreDown,
            row.baselineNoiseRatio,
            row.noiseRatio,
            row.varianceShiftRatio,
            row.changepointScore,
            row.changepointFlag,
            row.advancedScore,
            row.advancedRegression,
            row.improvementScore,
            row.advancedImprovement,
            row.signals
        );
        append(path, line);
    }
}

void writeSummaryJson(string path, VersionStats[] summary, string track)
{
    JSONValue[] rows;
    foreach (stat; summary)
    {
        auto row = [
            "track": JSONValue(track),
            "version": JSONValue(stat.versionLabel),
            "n_runs": JSONValue(stat.nRuns),
            "n_ok": JSONValue(stat.nOk),
            "n_fail": JSONValue(stat.nFail),
            "median_ms": stat.hasTiming ? JSONValue(stat.medianMs) : JSONValue(),
            "mad_ms": stat.hasTiming ? JSONValue(stat.madMs) : JSONValue(),
            "mean_ms": stat.hasTiming ? JSONValue(stat.meanMs) : JSONValue(),
            "ci_low_ms": stat.hasTiming ? JSONValue(stat.ciLowMs) : JSONValue(),
            "ci_high_ms": stat.hasTiming ? JSONValue(stat.ciHighMs) : JSONValue(),
            "artifact_size_bytes": stat.hasSize ? JSONValue(stat.artifactSize) : JSONValue()
        ];
        rows ~= JSONValue(row);
    }
    auto payload = JSONValue([
        "track": JSONValue(track),
        "rows": JSONValue(rows)
    ]);
    writeText(path, payload.toPrettyString());
}

void writeRegressionJson(string path, RegressionRow[] rows, string track)
{
    JSONValue[] data;
    foreach (row; rows)
    {
        auto entry = [
            "track": JSONValue(track),
            "from_version": JSONValue(row.fromVersion),
            "to_version": JSONValue(row.toVersion),
            "pct_change_compile_ms": JSONValue(row.pctChangeCompileMs),
            "pct_change_artifact_size": JSONValue(row.pctChangeArtifactSize),
            "ci_separated": JSONValue(row.ciSeparated),
            "compile_regression": JSONValue(row.compileRegression),
            "size_regression": JSONValue(row.sizeRegression),
            "flag_reason": JSONValue(row.flagReason)
        ];
        data ~= JSONValue(entry);
    }
    auto payload = JSONValue([
        "track": JSONValue(track),
        "rows": JSONValue(data)
    ]);
    writeText(path, payload.toPrettyString());
}

void writeAdvancedRegressionJson(string path, AdvancedRegressionRow[] rows, string track)
{
    JSONValue[] data;
    foreach (row; rows)
    {
        auto entry = [
            "track": JSONValue(track),
            "from_version": JSONValue(row.fromVersion),
            "to_version": JSONValue(row.toVersion),
            "baseline_count": JSONValue(row.baselineCount),
            "baseline_median_ms": JSONValue(row.baselineMedianMs),
            "baseline_mad_ms": JSONValue(row.baselineMadMs),
            "pct_change_baseline": JSONValue(row.pctChangeBaseline),
            "robust_z": JSONValue(row.robustZ),
            "trend_slope_pct": JSONValue(row.trendSlopePct),
            "cusum_score": JSONValue(row.cusumScore),
            "cusum_score_down": JSONValue(row.cusumScoreDown),
            "baseline_noise_ratio": JSONValue(row.baselineNoiseRatio),
            "noise_ratio": JSONValue(row.noiseRatio),
            "variance_shift_ratio": JSONValue(row.varianceShiftRatio),
            "changepoint_score": JSONValue(row.changepointScore),
            "changepoint_flag": JSONValue(row.changepointFlag),
            "advanced_score": JSONValue(row.advancedScore),
            "advanced_regression": JSONValue(row.advancedRegression),
            "improvement_score": JSONValue(row.improvementScore),
            "advanced_improvement": JSONValue(row.advancedImprovement),
            "signals": JSONValue(row.signals)
        ];
        data ~= JSONValue(entry);
    }
    auto payload = JSONValue([
        "track": JSONValue(track),
        "rows": JSONValue(data)
    ]);
    writeText(path, payload.toPrettyString());
}

void writeReport(
    string path,
    VersionStats[] summary,
    RegressionRow[] regressions,
    AdvancedRegressionRow[] advancedRegressions,
    string track,
    string benchmarkLabel,
    string benchmarkDescription,
    string compileCommand,
    string traceCompilerLabel)
{
    string[] lines;
    auto trackLabel = track.length ? track : "single";
    lines ~= format("# DMD regression report (%s)", track.length ? track : "single");
    lines ~= "";
    lines ~= format("Generated: %s", utcNowStamp());
    lines ~= "";
    lines ~= format("This report keeps the `%s` release lane separate so the raw series, derived flags, and reader summary stay easy to audit.", trackLabel);
    lines ~= "";
    lines ~= "## Report topology";
    lines ~= "";
    appendMermaid(lines, [
        "flowchart TD",
        format("    A[\"%s/results_raw.csv\"] --> B[\"summarize versions\"]", trackLabel),
        "    B --> C[\"results_summary.csv\"]",
        "    B --> D[\"regression scan\"]",
        "    D --> E[\"regression_table.csv\"]",
        "    D --> F[\"regression_table_advanced.csv\"]",
        "    C --> G[\"report.md\"]",
        "    E --> G",
        "    F --> G"
    ]);
    lines ~= "";
    lines ~= "## Methodology";
    lines ~= format("- Benchmark: %s (%s)", benchmarkLabel, benchmarkDescription);
    lines ~= format("- Command: %s", compileCommand);
    lines ~= format("- Trace compiler: %s", traceCompilerLabel);
    lines ~= "";
    lines ~= "## Summary";
    lines ~= format("- Versions analyzed: %s", summary.length);

    auto flagged = regressions.filter!(r => r.compileRegression == 1 || r.sizeRegression == 1).array;
    lines ~= format("- Regression flags: %s", flagged.length);
    lines ~= "";

    if (flagged.length)
    {
        lines ~= "## Regression flags";
        lines ~= "| From | To | Compile % | Size % | Reasons |";
        lines ~= "|---|---|---|---|---|";
        foreach (row; flagged)
        {
            lines ~= format("| %s | %s | %s | %s | %s |", row.fromVersion, row.toVersion, row.pctChangeCompileMs, row.pctChangeArtifactSize, row.flagReason);
        }
        lines ~= "";
    }

    auto advancedFlagged = advancedRegressions.filter!(r => r.advancedRegression == 1).array;
    if (advancedFlagged.length)
    {
        lines ~= "## Advanced regression flags";
        lines ~= "| From | To | Baseline % | Robust z | Score | Signals |";
        lines ~= "|---|---|---|---|---|---|";
        foreach (row; advancedFlagged)
        {
            lines ~= format("| %s | %s | %s | %s | %s | %s |", row.fromVersion, row.toVersion, row.pctChangeBaseline, row.robustZ, row.advancedScore, row.signals);
        }
        lines ~= "";
    }

    auto advancedImprovements = advancedRegressions.filter!(r => r.advancedImprovement == 1).array;
    if (advancedImprovements.length)
    {
        lines ~= "## Advanced improvements";
        lines ~= "| From | To | Baseline % | Robust z | Score | Signals |";
        lines ~= "|---|---|---|---|---|---|";
        foreach (row; advancedImprovements)
        {
            lines ~= format("| %s | %s | %s | %s | %s | %s |", row.fromVersion, row.toVersion, row.pctChangeBaseline, row.robustZ, row.improvementScore, row.signals);
        }
        lines ~= "";
    }

    writeText(path, lines.join("\n") ~ "\n");
}

string formatOpt(double value, int digits = 3)
{
    if (isNaN(value)) return "";
    return format("%.*f", digits, value);
}

void writeCompilePlotSvg(string path, VersionStats[] summary, RegressionRow[] regressions, Methodology methodology, string title)
{
    if (!summary.length) return;
    double maxVal = 0;
    foreach (s; summary)
    {
        if (s.hasTiming && s.ciHighMs > maxVal) maxVal = s.ciHighMs;
        else if (s.hasTiming && s.medianMs > maxVal) maxVal = s.medianMs;
    }
    if (maxVal <= 0) return;

    int width = 1100;
    int height = 520;
    int marginLeft = 70;
    int marginRight = 30;
    int marginTop = 40;
    int marginBottom = 120;
    double scaleX = (width - marginLeft - marginRight) / (summary.length > 1 ? cast(double)(summary.length - 1) : 1.0);
    double scaleY = (height - marginTop - marginBottom) / maxVal;

    bool[string] flagged;
    foreach (r; regressions)
    {
        if (r.compileRegression == 1) flagged[r.toVersion] = true;
    }

    string[] svg;
    svg ~= format("<svg xmlns='http://www.w3.org/2000/svg' width='%s' height='%s' viewBox='0 0 %s %s'>", width, height, width, height);
    svg ~= "<style>text{font-family:Arial, sans-serif; font-size:12px; fill:#0f172a;} .title{font-size:16px; font-weight:bold;} .axis{stroke:#94a3b8; stroke-width:1;} .line{stroke:#0f766e; fill:none; stroke-width:2;} .ci{stroke:#94d2bd; stroke-width:2;} .flag{fill:#b91c1c;} .pt{fill:#0f766e;}</style>";
    svg ~= format("<text class='title' x='%s' y='%s'>%s</text>", marginLeft, 24, title);

    int x0 = marginLeft;
    int y0 = height - marginBottom;
    int x1 = width - marginRight;
    int y1 = marginTop;
    svg ~= format("<line class='axis' x1='%s' y1='%s' x2='%s' y2='%s'/>", x0, y0, x1, y0);
    svg ~= format("<line class='axis' x1='%s' y1='%s' x2='%s' y2='%s'/>", x0, y0, x0, y1);

    // CI bars + line path
    string linePath = "";
    foreach (i, s; summary)
    {
        if (!s.hasTiming) continue;
        int x = marginLeft + cast(int) (i * scaleX);
        int y = y0 - cast(int) (s.medianMs * scaleY);
        linePath ~= (linePath.length ? " L " : "M ") ~ format("%s %s", x, y);

        if (!isNaN(s.ciLowMs) && !isNaN(s.ciHighMs))
        {
            int yLow = y0 - cast(int) (s.ciLowMs * scaleY);
            int yHigh = y0 - cast(int) (s.ciHighMs * scaleY);
            svg ~= format("<line class='ci' x1='%s' y1='%s' x2='%s' y2='%s'/>", x, yLow, x, yHigh);
        }
    }
    if (linePath.length) svg ~= format("<path class='line' d='%s'/>", linePath);

    foreach (i, s; summary)
    {
        if (!s.hasTiming) continue;
        int x = marginLeft + cast(int) (i * scaleX);
        int y = y0 - cast(int) (s.medianMs * scaleY);
        if (flagged.get(s.versionLabel, false))
            svg ~= format("<circle class='flag' cx='%s' cy='%s' r='4'/>", x, y);
        else
            svg ~= format("<circle class='pt' cx='%s' cy='%s' r='3'/>", x, y);

        auto label = s.versionLabel;
        svg ~= format("<text transform='translate(%s,%s) rotate(45)'>%s</text>", x - 6, y0 + 18, label);
    }

    auto note = format("%s | %s | median of %s measured after %s warmups | %s | %s",
        methodology.benchmarkLabel,
        methodology.compileCommand,
        methodology.measuredRuns,
        methodology.warmupRuns,
        methodology.cpuBrand,
        methodology.osValue);
    svg ~= format("<text x='%s' y='%s'>%s</text>", marginLeft, height - 20, note);

    svg ~= "</svg>";
    writeText(path, svg.join("\n") ~ "\n");
}

void writeArtifactPlotSvg(string path, VersionStats[] summary, Methodology methodology, string title)
{
    if (!summary.length) return;
    double maxVal = 0;
    foreach (s; summary)
    {
        if (s.hasSize && s.artifactSize > maxVal) maxVal = s.artifactSize;
    }
    if (maxVal <= 0) return;

    int width = 1100;
    int height = 460;
    int marginLeft = 70;
    int marginRight = 30;
    int marginTop = 40;
    int marginBottom = 120;
    double scaleX = (width - marginLeft - marginRight) / (summary.length > 0 ? cast(double) summary.length : 1.0);
    double scaleY = (height - marginTop - marginBottom) / maxVal;

    string[] svg;
    svg ~= format("<svg xmlns='http://www.w3.org/2000/svg' width='%s' height='%s' viewBox='0 0 %s %s'>", width, height, width, height);
    svg ~= "<style>text{font-family:Arial, sans-serif; font-size:12px; fill:#0f172a;} .title{font-size:16px; font-weight:bold;} .axis{stroke:#94a3b8; stroke-width:1;} .bar{fill:#0a9396;}</style>";
    svg ~= format("<text class='title' x='%s' y='%s'>%s</text>", marginLeft, 24, title);

    int x0 = marginLeft;
    int y0 = height - marginBottom;
    int x1 = width - marginRight;
    int y1 = marginTop;
    svg ~= format("<line class='axis' x1='%s' y1='%s' x2='%s' y2='%s'/>", x0, y0, x1, y0);
    svg ~= format("<line class='axis' x1='%s' y1='%s' x2='%s' y2='%s'/>", x0, y0, x0, y1);

    foreach (i, s; summary)
    {
        if (!s.hasSize) continue;
        int x = marginLeft + cast(int) (i * scaleX);
        int barW = cast(int) (scaleX * 0.7);
        int barH = cast(int) (s.artifactSize * scaleY);
        int y = y0 - barH;
        svg ~= format("<rect class='bar' x='%s' y='%s' width='%s' height='%s'/>", x, y, barW, barH);
        svg ~= format("<text transform='translate(%s,%s) rotate(45)'>%s</text>", x - 6, y0 + 18, s.versionLabel);
    }

    auto note = format("%s | %s | %s", methodology.benchmarkLabel, methodology.compileCommand, methodology.osValue);
    svg ~= format("<text x='%s' y='%s'>%s</text>", marginLeft, height - 20, note);
    svg ~= "</svg>";
    writeText(path, svg.join("\n") ~ "\n");
}

void writeMultiTrackReport(string path, TrackResult[string] trackResults, string traceSummaryCsv, string granularityCsv)
{
    if (!trackResults.length) return;
    auto traceRows = readCsvIfExists(traceSummaryCsv);
    auto granRows = readCsvIfExists(granularityCsv);
    bool hasLatest = ("latest20" in trackResults) !is null;
    bool hasCompatible = ("compatible20" in trackResults) !is null;
    string singleOther;
    if (trackResults.length == 1 && !hasLatest && !hasCompatible)
    {
        foreach (track, _result; trackResults)
        {
            singleOther = track;
            break;
        }
    }

    string[] topology = ["flowchart TD"];
    if (hasLatest)
        topology ~= "    A[\"latest20/results_raw.csv\"] --> C[\"summarize + regression scan\"]";
    if (hasCompatible)
        topology ~= "    B[\"compatible20/results_raw.csv\"] --> C[\"summarize + regression scan\"]";
    if (singleOther.length)
        topology ~= format("    A[\"%s/results_raw.csv\"] --> C[\"summarize + regression scan\"]", singleOther);
    if (traceRows.length)
        topology ~= "    D[\"trace summaries\"] --> F[\"report.md\"]";
    if (granRows.length)
        topology ~= "    E[\"granularity sweep\"] --> F[\"report.md\"]";
    topology ~= "    C --> G[\"results_summary.csv + regression_table.csv\"]";
    topology ~= "    C --> H[\"plots\"]";
    topology ~= "    G --> F[\"report.md\"]";
    topology ~= "    H --> F[\"report.md\"]";

    string[] lines;
    lines ~= "# DMD Performance Regression Study";
    lines ~= "";
    lines ~= format("Generated: %s", utcNowStamp());
    lines ~= "";
    if (hasLatest && hasCompatible)
        lines ~= "This report keeps the availability story and the regression-scoring story separate on purpose.";
    else if (hasLatest)
        lines ~= "This report focuses on the `latest20` lane so the literal latest-release story stays easy to audit.";
    else if (hasCompatible)
        lines ~= "This report focuses on the `compatible20` lane so the regression-scoring series stays easy to audit.";
    else if (singleOther.length)
        lines ~= format("This report focuses on the `%s` lane so its raw series and findings stay easy to audit.", singleOther);
    else
        lines ~= "This report summarizes the selected release-analysis lanes for this host.";
    lines ~= "";
    lines ~= "## Report topology";
    lines ~= "";
    appendMermaid(lines, topology);
    lines ~= "";
    lines ~= "## Setup Snapshot";
    lines ~= "";

    foreach (track, result; trackResults)
    {
        int totalRuns = 0;
        int totalFail = 0;
        foreach (s; result.summary)
        {
            totalRuns += s.nRuns;
            totalFail += s.nFail;
        }
        auto label = track == "single" ? "single" : track;
        lines ~= format("- **%s**: versions=%s runs=%s failures=%s", label, result.summary.length, totalRuns, totalFail);
    }

    lines ~= "";
    lines ~= "## Data Collection Methodology";
    lines ~= "";
    Methodology m;
    bool got = false;
    foreach (track, result; trackResults)
    {
        m = result.methodology;
        got = true;
        break;
    }
    if (!got)
    {
        writeText(path, lines.join("\n") ~ "\n");
        return;
    }
    lines ~= format("- Benchmark: `%s` (%s).", m.benchmarkLabel, m.benchmarkDescription);
    lines ~= format("- Release-sweep command: `%s`.", m.compileCommand);
    lines ~= "- Plotted `compile time` means wall-clock time for the compile-only command above; linking is excluded.";
    lines ~= format("- Sampling policy: %s warmups + %s measured runs per release; plot and CSV use the median of measured runs.", m.warmupRuns, m.measuredRuns);
    lines ~= format("- Machine: `%s` / `%s` / `%s`.", m.hostname, m.cpuBrand, m.osValue);
    lines ~= format("- Phase attribution (`-ftime-trace`) was collected separately with `%s`.", m.traceCompilerLabel);

    lines ~= "";
    lines ~= hasLatest && hasCompatible ? "## Track Comparison" : "## Track Notes";
    lines ~= "";
    if (hasLatest && hasCompatible)
    {
        lines ~= "- `latest20` is used to stay literal with latest-release direction, even if host compatibility causes failures.";
        lines ~= "- `compatible20` is used for stable regression scoring on this machine.";
        lines ~= "- Artifact size represents compile-only object output (`-c`), not final linked executable size.";
    }
    else if (hasLatest)
    {
        lines ~= "- `latest20` keeps the newest release window visible on this machine, including failures.";
        lines ~= "- This lane is useful for availability and breakage review, not only regression scoring.";
        lines ~= "- Artifact size represents compile-only object output (`-c`), not final linked executable size.";
    }
    else if (hasCompatible)
    {
        lines ~= "- `compatible20` is the stable regression-scoring lane on this machine.";
        lines ~= "- This lane filters toward releases that can be measured consistently on the current host.";
        lines ~= "- Artifact size represents compile-only object output (`-c`), not final linked executable size.";
    }
    else
    {
        lines ~= format("- `%s` is the selected analysis lane for this report.", singleOther.length ? singleOther : "selected");
        lines ~= "- The report keeps the raw series, derived flags, and trace context together in one place.";
        lines ~= "- Artifact size represents compile-only object output (`-c`), not final linked executable size.";
    }

    if ("latest20" in trackResults)
    {
        auto latest = trackResults["latest20"];
        lines ~= "";
        lines ~= "## latest20 Availability";
        lines ~= "";
        if (latest.failureCounts.length)
        {
            lines ~= "| Failure kind | Count |";
            lines ~= "|---|---:|";
            foreach (kind, count; latest.failureCounts)
            {
                lines ~= format("| %s | %s |", kind, count);
            }
        }
        else
        {
            lines ~= "No failures were recorded in latest20 measured runs.";
        }
    }

    if ("compatible20" in trackResults)
    {
        auto comp = trackResults["compatible20"];
        auto compileRegs = comp.regressions.filter!(r => r.compileRegression == 1).array;
        auto improvements = comp.regressions.filter!(r => r.pctChangeCompileMs.length && to!double(r.pctChangeCompileMs) <= -10.0).array;

        lines ~= "";
        lines ~= "## compatible20 Key Regressions";
        lines ~= "";
        if (compileRegs.length)
        {
            lines ~= "| From | To | Compile change | CI separated |";
            lines ~= "|---|---:|---:|---:|";
            auto limitRegs = compileRegs.length < 8 ? compileRegs.length : 8;
            foreach (row; compileRegs[0 .. limitRegs])
            {
                lines ~= format("| %s | %s | %s%% | %s |", row.fromVersion, row.toVersion, row.pctChangeCompileMs, row.ciSeparated);
            }
        }
        else
        {
            lines ~= "No compile-time regressions passed the threshold + CI separation rule.";
        }

        lines ~= "";
        lines ~= "## compatible20 Notable Improvements";
        lines ~= "";
        if (improvements.length)
        {
            lines ~= "| From | To | Compile change |";
            lines ~= "|---|---:|---:|";
            auto limitImprovements = improvements.length < 6 ? improvements.length : 6;
            foreach (row; improvements[0 .. limitImprovements])
            {
                lines ~= format("| %s | %s | %s%% |", row.fromVersion, row.toVersion, row.pctChangeCompileMs);
            }
        }
        else
        {
            lines ~= "No improvements exceeded -10% on median compile time.";
        }
    }

    lines ~= "";
    lines ~= "## Phase-Level Trace Signals";
    lines ~= "";
    if (traceRows.length)
    {
        lines ~= "| Phase | Total ms | Share | Event count |";
        lines ~= "|---|---:|---:|---:|";
        auto limit = traceRows.length < 6 ? traceRows.length : 6;
        foreach (i; 0 .. limit)
        {
            auto row = traceRows[i];
            lines ~= format("| %s | %s | %s%% | %s |", row.data.get("phase", ""), row.data.get("total_ms", ""), row.data.get("percent", ""), row.data.get("event_count", ""));
        }
    }
    else
    {
        lines ~= "No trace summary found. Run `./run_trace.sh` or `dmdbench trace` to generate phase attribution.";
    }

    lines ~= "";
    lines ~= "## Granularity Sweep";
    lines ~= "";
    if (granRows.length)
    {
        lines ~= "| Granularity | Trace size (bytes) | Timed events | Dominant phase | Dominant share |";
        lines ~= "|---|---:|---:|---|---:|";
        foreach (row; granRows)
        {
            lines ~= format("| %s | %s | %s | %s | %s%% |", row.data.get("granularity", ""), row.data.get("trace_size_bytes", ""), row.data.get("timed_events", ""), row.data.get("dominant_phase", ""), row.data.get("dominant_phase_pct", ""));
        }
    }
    else
    {
        lines ~= "No granularity sweep data found. Use `--granularity-sweep` in `dmdbench trace`.";
    }

    lines ~= "";
    lines ~= "## Recommended Metrics for Publisher v1";
    lines ~= "";
    lines ~= "- End-to-end compile median (warmups excluded)";
    lines ~= "- Noise indicators: MAD and CI width";
    lines ~= "- Regression trigger: percent jump + non-overlapping CIs";
    lines ~= "- Phase buckets from `-ftime-trace` (semantic/template/codegen)";

    writeText(path, lines.join("\n") ~ "\n");
}

CsvRow[] readCsvIfExists(string path)
{
    if (!exists(path)) return [];
    return loadCsv(path);
}

void copyIfExists(string src, string dst)
{
    if (!exists(src)) return;
    copy(src, dst);
}

void copyCompatibleArtifacts(string outDir, string summaryCsv, string regressionCsv, string regressionAdvancedCsv, bool noPlot)
{
    auto base = buildPath(outDir, "compatible20");
    copyIfExists(buildPath(base, summaryCsv), buildPath(outDir, summaryCsv));
    copyIfExists(buildPath(base, regressionCsv), buildPath(outDir, regressionCsv));
    copyIfExists(buildPath(base, regressionAdvancedCsv), buildPath(outDir, regressionAdvancedCsv));
    if (!noPlot)
    {
        copyIfExists(buildPath(base, "compile_time_trend.svg"), buildPath(outDir, "compile_time_trend.svg"));
        copyIfExists(buildPath(base, "artifact_size_trend.svg"), buildPath(outDir, "artifact_size_trend.svg"));
    }
}

struct AdvancedConsensusRow
{
    string fromVersion;
    string toVersion;
    string consensusType;
    string pctChangeLatest;
    string pctChangeCompatible;
    string scoreLatest;
    string scoreCompatible;
    string dominantPhase;
    string dominantPhasePercent;
    string weightedScoreLatest;
    string weightedScoreCompatible;
    string signalsLatest;
    string signalsCompatible;
}

struct AdvancedConsensusReport
{
    AdvancedConsensusRow[] rows;
    int regressionCount;
    int improvementCount;
    int filteredByVariance;
}

struct PhaseWeight
{
    string phase;
    double percent;
    bool ok;
}

double parseOptionalDouble(string value)
{
    if (!value.length) return double.nan;
    try
    {
        return to!double(value);
    }
    catch (Exception)
    {
        return double.nan;
    }
}

PhaseWeight loadPhaseWeight(string path)
{
    if (!exists(path)) return PhaseWeight("", double.nan, false);
    auto rows = loadCsv(path);
    if (!rows.length) return PhaseWeight("", double.nan, false);

    double best = -1.0;
    string phaseName = "";
    foreach (row; rows)
    {
        auto phase = row.data.get("phase", "").strip;
        auto percentRaw = row.data.get("percent", "").strip;
        auto pct = parseOptionalDouble(percentRaw);
        if (phase.length && !isNaN(pct) && pct > best)
        {
            best = pct;
            phaseName = phase;
        }
    }

    if (best < 0) return PhaseWeight("", double.nan, false);
    return PhaseWeight(phaseName, best, true);
}

PhaseWeight[] loadPhaseSummary(string path)
{
    PhaseWeight[] phases;
    if (!exists(path)) return phases;
    auto rows = loadCsv(path);
    foreach (row; rows)
    {
        auto phase = row.data.get("phase", "").strip;
        auto percentRaw = row.data.get("percent", "").strip;
        auto pct = parseOptionalDouble(percentRaw);
        if (!phase.length || isNaN(pct)) continue;
        phases ~= PhaseWeight(phase, pct, true);
    }
    phases.sort!((a, b) => a.percent > b.percent);
    return phases;
}

AdvancedConsensusReport buildConsensusAdvanced(CsvRow[] latestRows, CsvRow[] compatibleRows)
{
    CsvRow[string] latestByKey;
    CsvRow[string] compatibleByKey;
    foreach (row; latestRows)
    {
        auto from = row.data.get("from_version", "").strip;
        auto to = row.data.get("to_version", "").strip;
        if (!from.length || !to.length) continue;
        latestByKey[from ~ "->" ~ to] = row;
    }
    foreach (row; compatibleRows)
    {
        auto from = row.data.get("from_version", "").strip;
        auto to = row.data.get("to_version", "").strip;
        if (!from.length || !to.length) continue;
        compatibleByKey[from ~ "->" ~ to] = row;
    }

    AdvancedConsensusReport report;
    foreach (key, row; latestByKey)
    {
        auto compPtr = key in compatibleByKey;
        if (compPtr is null) continue;
        auto comp = *compPtr;

        auto from = row.data.get("from_version", "").strip;
        auto to = row.data.get("to_version", "").strip;
        auto latestReg = row.data.get("advanced_regression", "0") == "1";
        auto latestImp = row.data.get("advanced_improvement", "0") == "1";
        auto compReg = comp.data.get("advanced_regression", "0") == "1";
        auto compImp = comp.data.get("advanced_improvement", "0") == "1";

        if (latestReg && compReg)
        {
            report.rows ~= AdvancedConsensusRow(
                from,
                to,
                "regression",
                row.data.get("pct_change_baseline", ""),
                comp.data.get("pct_change_baseline", ""),
                row.data.get("advanced_score", ""),
                comp.data.get("advanced_score", ""),
                "",
                "",
                "",
                "",
                row.data.get("signals", ""),
                comp.data.get("signals", "")
            );
            report.regressionCount++;
        }
        if (latestImp && compImp)
        {
            report.rows ~= AdvancedConsensusRow(
                from,
                to,
                "improvement",
                row.data.get("pct_change_baseline", ""),
                comp.data.get("pct_change_baseline", ""),
                row.data.get("improvement_score", ""),
                comp.data.get("improvement_score", ""),
                "",
                "",
                "",
                "",
                row.data.get("signals", ""),
                comp.data.get("signals", "")
            );
            report.improvementCount++;
        }
    }

    return report;
}

double averageScore(string a, string b)
{
    auto v1 = parseOptionalDouble(a);
    auto v2 = parseOptionalDouble(b);
    if (!isNaN(v1) && !isNaN(v2)) return (v1 + v2) / 2.0;
    if (!isNaN(v1)) return v1;
    if (!isNaN(v2)) return v2;
    return double.nan;
}

void writeConsensusAdvanced(
    string outDir,
    string[] trackList,
    string regressionAdvancedCsv,
    string tracePhaseSummary,
    double varianceThreshold,
    int phaseBuckets,
    int phaseTop)
{
    if (!trackList.canFind("latest20") || !trackList.canFind("compatible20"))
    {
        return;
    }

    auto latestPath = buildPath(outDir, "latest20", regressionAdvancedCsv);
    auto compatiblePath = buildPath(outDir, "compatible20", regressionAdvancedCsv);
    if (!exists(latestPath) || !exists(compatiblePath)) return;

    auto latestRows = loadCsv(latestPath);
    auto compatibleRows = loadCsv(compatiblePath);
    if (!latestRows.length || !compatibleRows.length) return;

    auto report = buildConsensusAdvanced(latestRows, compatibleRows);
    auto phaseWeight = loadPhaseWeight(tracePhaseSummary);
    auto phases = loadPhaseSummary(tracePhaseSummary);

    CsvRow[string] latestByKey;
    CsvRow[string] compatibleByKey;
    foreach (r; latestRows)
    {
        auto from = r.data.get("from_version", "").strip;
        auto to = r.data.get("to_version", "").strip;
        if (!from.length || !to.length) continue;
        latestByKey[from ~ "->" ~ to] = r;
    }
    foreach (r; compatibleRows)
    {
        auto from = r.data.get("from_version", "").strip;
        auto to = r.data.get("to_version", "").strip;
        if (!from.length || !to.length) continue;
        compatibleByKey[from ~ "->" ~ to] = r;
    }

    AdvancedConsensusRow[] filtered;
    foreach (row; report.rows)
    {
        auto key = row.fromVersion ~ "->" ~ row.toVersion;
        auto lPtr = key in latestByKey;
        auto cPtr = key in compatibleByKey;
        if (lPtr is null || cPtr is null) continue;
        auto lVar = parseOptionalDouble((*lPtr).data.get("variance_shift_ratio", ""));
        auto cVar = parseOptionalDouble((*cPtr).data.get("variance_shift_ratio", ""));
        bool unstable = (!isNaN(lVar) && lVar > varianceThreshold) || (!isNaN(cVar) && cVar > varianceThreshold);
        if (unstable)
        {
            report.filteredByVariance++;
            continue;
        }
        filtered ~= row;
    }
    report.rows = filtered;
    report.regressionCount = 0;
    report.improvementCount = 0;
    foreach (row; report.rows)
    {
        if (row.consensusType == "regression") report.regressionCount++;
        if (row.consensusType == "improvement") report.improvementCount++;
    }
    foreach (ref row; report.rows)
    {
        if (!phaseWeight.ok) continue;
        row.dominantPhase = phaseWeight.phase;
        row.dominantPhasePercent = format("%.2f", phaseWeight.percent);
        auto weight = phaseWeight.percent / 100.0;
        auto sLatest = parseOptionalDouble(row.scoreLatest);
        auto sCompat = parseOptionalDouble(row.scoreCompatible);
        if (!isNaN(sLatest)) row.weightedScoreLatest = format("%.3f", sLatest * weight);
        if (!isNaN(sCompat)) row.weightedScoreCompatible = format("%.3f", sCompat * weight);
    }

    auto outCsv = buildPath(outDir, "regression_consensus_advanced.csv");
    string header = "from_version,to_version,consensus_type,pct_change_latest,pct_change_compatible,score_latest,score_compatible,dominant_phase,dominant_phase_percent,weighted_score_latest,weighted_score_compatible,signals_latest,signals_compatible\n";
    writeText(outCsv, header);
    foreach (row; report.rows)
    {
        string line = format(
            "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n",
            row.fromVersion,
            row.toVersion,
            row.consensusType,
            row.pctChangeLatest,
            row.pctChangeCompatible,
            row.scoreLatest,
            row.scoreCompatible,
            row.dominantPhase,
            row.dominantPhasePercent,
            row.weightedScoreLatest,
            row.weightedScoreCompatible,
            row.signalsLatest,
            row.signalsCompatible
        );
        append(outCsv, line);
    }

    auto outMd = buildPath(outDir, "report_consensus.md");
    string[] md;
    md ~= "# Advanced Consensus Report";
    md ~= "";
    md ~= "This report joins the latest-release story, the compatible scoring story, and the trace-weight view.";
    md ~= "";
    md ~= "## Consensus topology";
    md ~= "";
    appendMermaid(md, [
        "flowchart TD",
        "    A[\"latest20 regression table\"] --> C[\"consensus scorer\"]",
        "    B[\"compatible20 regression table\"] --> C",
        "    D[\"trace phase weights\"] --> C",
        "    C --> E[\"regression_consensus_advanced.csv\"]",
        "    C --> F[\"report_consensus.md\"]"
    ]);
    md ~= "";
    md ~= format("- Consensus regressions: %s", report.regressionCount);
    md ~= format("- Consensus improvements: %s", report.improvementCount);
    md ~= format("- Filtered for variance shift: %s", report.filteredByVariance);
    if (phaseWeight.ok)
    {
        md ~= format("- Dominant trace phase: %s (%0.2f%%)", phaseWeight.phase, phaseWeight.percent);
    }
    md ~= "";
    if (report.rows.length)
    {
        md ~= "| From | To | Type | Latest % | Compatible % | Score (latest) | Score (compatible) | Weighted (latest) | Weighted (compatible) |";
        md ~= "|---|---|---|---:|---:|---:|---:|---:|---:|";
        foreach (row; report.rows)
        {
            md ~= format("| %s | %s | %s | %s | %s | %s | %s | %s | %s |", row.fromVersion, row.toVersion, row.consensusType, row.pctChangeLatest, row.pctChangeCompatible, row.scoreLatest, row.scoreCompatible, row.weightedScoreLatest, row.weightedScoreCompatible);
        }
    }
    else
    {
        md ~= "No consensus signals found across latest20 + compatible20.";
    }

    if (phases.length && report.rows.length)
    {
        int bucketCount = phaseBuckets < cast(int) phases.length ? phaseBuckets : cast(int) phases.length;
        foreach (idx; 0 .. bucketCount)
        {
            auto phase = phases[idx];
            md ~= "";
            md ~= format("## Phase Bucket: %s (%0.2f%%)", phase.phase, phase.percent);
            struct ScoredRow
            {
                AdvancedConsensusRow row;
                double score;
            }
            ScoredRow[] scored;
            foreach (row; report.rows)
            {
                auto baseScore = averageScore(row.scoreLatest, row.scoreCompatible);
                if (isNaN(baseScore)) continue;
                auto weighted = baseScore * (phase.percent / 100.0);
                scored ~= ScoredRow(row, weighted);
            }
            scored.sort!((a, b) => a.score > b.score);
            if (!scored.length)
            {
                md ~= "No consensus rows with numeric scores for this phase.";
                continue;
            }
            md ~= "| From | To | Type | Weighted Score |";
            md ~= "|---|---|---|---:|";
            auto limit = phaseTop < cast(int) scored.length ? phaseTop : cast(int) scored.length;
            foreach (i; 0 .. limit)
            {
                auto entry = scored[i];
                md ~= format("| %s | %s | %s | %.3f |", entry.row.fromVersion, entry.row.toVersion, entry.row.consensusType, entry.score);
            }
        }
    }
    writeText(outMd, md.join("\n") ~ "\n");
}

void writeManifest(string path, string track)
{
    auto payload = JSONValue([
        "tool": JSONValue("dmdbench"),
        "track": JSONValue(track),
        "generated": JSONValue(utcNowStamp()),
        "hostname": JSONValue(hostName()),
        "cpu": JSONValue(cpuBrand()),
        "os": JSONValue(osValue())
    ]);
    writeText(path, payload.toPrettyString());
}

// --- Stats helpers ---

double median(double[] values)
{
    auto v = values.dup;
    v.sort;
    auto n = v.length;
    if (n == 0) return double.nan;
    if (n % 2 == 1) return v[n / 2];
    return (v[n / 2 - 1] + v[n / 2]) / 2.0;
}

double mad(double[] values)
{
    auto med = median(values);
    double[] devs;
    devs.length = values.length;
    foreach (i, v; values) devs[i] = fabs(v - med);
    return median(devs);
}

double mean(double[] values)
{
    if (!values.length) return double.nan;
    double sum = 0;
    foreach (v; values) sum += v;
    return sum / values.length;
}

Tuple!(double, double) bootstrapCi(double[] values, int samples)
{
    if (values.length == 0) return tuple(double.nan, double.nan);
    if (values.length == 1) return tuple(values[0], values[0]);

    auto rng = Random(42);
    double[] medians;
    medians.length = samples;
    auto n = values.length;
    foreach (i; 0 .. samples)
    {
        double[] sample;
        sample.length = n;
        foreach (j; 0 .. n)
        {
            auto idx = uniform(0, cast(int) n, rng);
            sample[j] = values[idx];
        }
        medians[i] = median(sample);
    }
    medians.sort;
    return tuple(percentile(medians, 0.025), percentile(medians, 0.975));
}

double percentile(double[] sortedValues, double fraction)
{
    if (!sortedValues.length) return double.nan;
    if (sortedValues.length == 1) return sortedValues[0];
    auto pos = (sortedValues.length - 1) * fraction;
    auto low = cast(int) floor(pos);
    auto high = cast(int) ceil(pos);
    if (low == high) return sortedValues[low];
    auto lowVal = sortedValues[low];
    auto highVal = sortedValues[high];
    return lowVal + (highVal - lowVal) * (pos - low);
}

// --- Trace ---
struct TraceOptions
{
    string dmdBin = "dmd";
    string benchmark = "benchmark.d";
    string outDir = "artifacts";
    string traceName = "trace.json";
    int granularity = 1;
    string granularitySweep = "";
    string sweepCsv = "";
    string phaseCsv = "trace_phase_summary.csv";
    string eventCsv = "trace_event_summary.csv";
    string plotSvg = "trace_phase_bar.svg";
    int topEvents = 25;
    bool noPlot = false;
}

void runTrace(string[] args)
{
    TraceOptions opt;
    auto help = getopt(
        args,
        "dmd-bin", &opt.dmdBin,
        "benchmark", &opt.benchmark,
        "out-dir", &opt.outDir,
        "trace-name", &opt.traceName,
        "granularity", &opt.granularity,
        "granularity-sweep", &opt.granularitySweep,
        "sweep-csv", &opt.sweepCsv,
        "phase-csv", &opt.phaseCsv,
        "event-csv", &opt.eventCsv,
        "plot-svg", &opt.plotSvg,
        "top-events", &opt.topEvents,
        "no-plot", &opt.noPlot
    );
    enforce(help.helpWanted == false, "");

    mkdirRecurse(opt.outDir);
    auto tracePath = buildPath(opt.outDir, opt.traceName);
    auto outObj = buildPath(opt.outDir, ".trace_build.o");

    runTraceCompile(opt.dmdBin, opt.benchmark, tracePath, outObj, opt.granularity);
    if (exists(outObj)) remove(outObj);

    if (!exists(tracePath) || getSize(tracePath) == 0)
    {
        stderr.writeln("Trace file not created: ", tracePath);
        return;
    }

    auto summary = summarizeTraceData(tracePath, opt.topEvents);
    auto phaseCsv = buildPath(opt.outDir, opt.phaseCsv);
    auto eventCsv = buildPath(opt.outDir, opt.eventCsv);
    writeTracePhaseCsv(phaseCsv, summary.phases);
    writeTraceEventCsv(eventCsv, summary.events);
    if (!opt.noPlot)
    {
        auto plotPath = buildPath(opt.outDir, opt.plotSvg);
        writeTracePhaseSvg(plotPath, summary.phases);
    }

    if (opt.granularitySweep.length)
    {
        auto sweepCsv = opt.sweepCsv.length ? opt.sweepCsv : buildPath(opt.outDir, "trace_granularity_sweep.csv");
        writeText(sweepCsv, "granularity,trace_size_bytes,timed_events,dominant_phase,dominant_phase_pct\n");
        foreach (raw; opt.granularitySweep.split(','))
        {
            auto g = raw.strip;
            if (!g.length) continue;
            int gran = to!int(g);
            auto sweepTrace = buildPath(opt.outDir, format(".trace_g%s.json", g));
            auto sweepObj = buildPath(opt.outDir, format(".trace_g%s.o", g));
            runTraceCompile(opt.dmdBin, opt.benchmark, sweepTrace, sweepObj, gran);
            if (exists(sweepObj)) remove(sweepObj);
            if (!exists(sweepTrace) || getSize(sweepTrace) == 0)
            {
                append(sweepCsv, format("%s,0,0,missing,0\n", g));
                continue;
            }
            auto phasePath = buildPath(opt.outDir, format(".trace_g%s_phase.csv", g));
            auto eventPath = buildPath(opt.outDir, format(".trace_g%s_events.csv", g));
            auto sweepSummary = summarizeTraceData(sweepTrace, opt.topEvents);
            writeTracePhaseCsv(phasePath, sweepSummary.phases);
            writeTraceEventCsv(eventPath, sweepSummary.events);

            auto dominant = dominantPhaseFromRows(sweepSummary.phases);
            auto sizeBytes = getSize(sweepTrace);
            auto timedEvents = sweepSummary.timedEvents;
            append(sweepCsv, format("%s,%s,%s,%s,%s\n", g, sizeBytes, timedEvents, dominant[0], dominant[1]));

            if (exists(sweepTrace)) remove(sweepTrace);
            if (exists(phasePath)) remove(phasePath);
            if (exists(eventPath)) remove(eventPath);
        }
    }
}

void runTraceCompile(string dmdBin, string benchmark, string tracePath, string outObj, int granularity)
{
    string[] cmd = [
        dmdBin,
        benchmark,
        "-of=" ~ outObj,
        "-c",
        "-ftime-trace",
        "-ftime-trace-file=" ~ tracePath,
        "-ftime-trace-granularity=" ~ to!string(granularity)
    ];

    auto res = safeExecute(cmd);
    if (res.status != 0)
    {
        string[] fallback = [
            dmdBin,
            benchmark,
            "-of=" ~ outObj,
            "-c",
            "-ftime-trace=" ~ tracePath,
            "-ftime-trace-granularity=" ~ to!string(granularity)
        ];
        safeExecute(fallback);
    }
}

struct PhaseRow
{
    string phase;
    double totalUs;
    double totalMs;
    double percent;
    int eventCount;
}

struct EventRow
{
    string name;
    double totalUs;
    double totalMs;
    double percent;
}

struct TraceSummary
{
    PhaseRow[] phases;
    EventRow[] events;
    size_t timedEvents;
}

TraceSummary summarizeTraceData(string tracePath, int topEvents)
{
    auto traceText = readText(tracePath);
    auto payload = parseJSON(traceText);
    JSONValue[] events;

    if (payload.type == JSONType.object)
    {
        auto obj = payload.object;
        if ("traceEvents" in obj)
        {
            events = obj["traceEvents"].array;
        }
        else
        {
            stderr.writeln("Trace format not recognized: ", tracePath);
            return TraceSummary();
        }
    }
    else if (payload.type == JSONType.array)
    {
        events = payload.array;
    }
    else
    {
        stderr.writeln("Trace format not recognized: ", tracePath);
        return TraceSummary();
    }

    double[string] phaseTotals;
    int[string] phaseCounts;
    double[string] eventTotals;
    size_t timedEvents = 0;

    foreach (event; events)
    {
        if (event.type != JSONType.object) continue;
        auto obj = event.object;
        auto ph = obj.get("ph", JSONValue(""));
        if (ph.type != JSONType.string) continue;
        if (ph.str != "X" && ph.str != "") continue;

        auto dur = obj.get("dur", JSONValue(0));
        double durVal = dur.type == JSONType.float_ ? dur.floating : (dur.type == JSONType.integer ? dur.integer : 0);
        if (durVal <= 0) continue;

        auto name = obj.get("name", JSONValue("<unnamed>")).str;
        auto phase = normalizePhase(name);
        phaseTotals[phase] += durVal;
        phaseCounts[phase] = phaseCounts.get(phase, 0) + 1;
        eventTotals[name] += durVal;
        timedEvents++;
    }

    double total = 0;
    foreach (v; phaseTotals.values) total += v;
    if (total == 0) total = 1.0;

    PhaseRow[] phaseRows;
    auto phasePairs = phaseTotals.keys.array.map!(p => tuple(p, phaseTotals[p])).array;
    phasePairs.sort!((a, b) => a[1] > b[1]);
    foreach (pair; phasePairs)
    {
        auto phase = pair[0];
        auto totalUs = pair[1];
        auto pct = (totalUs / total) * 100.0;
        phaseRows ~= PhaseRow(phase, totalUs, totalUs / 1000.0, pct, phaseCounts.get(phase, 0));
    }

    EventRow[] eventRows;
    auto sortedEvents = eventTotals.keys.array;
    sortedEvents.sort!((a, b) => eventTotals[a] > eventTotals[b]);
    auto limit = topEvents < cast(int) sortedEvents.length ? topEvents : cast(int) sortedEvents.length;
    foreach (idx; 0 .. limit)
    {
        auto name = sortedEvents[idx];
        auto totalUs = eventTotals[name];
        auto pct = (totalUs / total) * 100.0;
        eventRows ~= EventRow(name, totalUs, totalUs / 1000.0, pct);
    }

    return TraceSummary(phaseRows, eventRows, timedEvents);
}

void writeTracePhaseCsv(string outCsv, PhaseRow[] rows)
{
    string[] lines;
    lines ~= "phase,total_us,total_ms,percent,event_count";
    foreach (row; rows)
    {
        lines ~= format("%s,%.3f,%.3f,%.2f,%s", row.phase, row.totalUs, row.totalMs, row.percent, row.eventCount);
    }
    writeText(outCsv, lines.join("\n") ~ "\n");
}

void writeTraceEventCsv(string outCsv, EventRow[] rows)
{
    string[] lines;
    lines ~= "event,total_us,total_ms,percent";
    foreach (row; rows)
    {
        lines ~= format("%s,%.3f,%.3f,%.2f", row.name, row.totalUs, row.totalMs, row.percent);
    }
    writeText(outCsv, lines.join("\n") ~ "\n");
}

void writeTracePhaseSvg(string outSvg, PhaseRow[] rows)
{
    if (!rows.length) return;
    double maxMs = 0;
    foreach (row; rows) if (row.totalMs > maxMs) maxMs = row.totalMs;
    if (maxMs <= 0) return;

    int width = 900;
    int marginLeft = 200;
    int marginRight = 40;
    int marginTop = 40;
    int barHeight = 20;
    int gap = 8;
    int height = marginTop + (barHeight + gap) * cast(int) rows.length + 40;
    double scale = (width - marginLeft - marginRight) / maxMs;

    string[] svg;
    svg ~= format("<svg xmlns='http://www.w3.org/2000/svg' width='%s' height='%s' viewBox='0 0 %s %s'>", width, height, width, height);
    svg ~= "<style>text{font-family:Arial, sans-serif; font-size:12px; fill:#0f172a;} .title{font-size:16px; font-weight:bold;} .bar{fill:#3a86ff;}</style>";
    svg ~= format("<text class='title' x='%s' y='%s'>DMD -ftime-trace: Phase Time Distribution</text>", marginLeft, 24);
    foreach (i, row; rows)
    {
        int y = marginTop + cast(int) i * (barHeight + gap);
        int barW = cast(int) (row.totalMs * scale);
        svg ~= format("<text x='%s' y='%s'>%s</text>", 12, y + barHeight - 4, row.phase);
        svg ~= format("<rect class='bar' x='%s' y='%s' width='%s' height='%s'/>", marginLeft, y, barW, barHeight);
        svg ~= format("<text x='%s' y='%s'>%.1f ms (%.1f%%)</text>", marginLeft + barW + 6, y + barHeight - 4, row.totalMs, row.percent);
    }
    svg ~= "</svg>";
    writeText(outSvg, svg.join("\n") ~ "\n");
}

string normalizePhase(string name)
{
    auto n = name.toLower();
    if (n.canFind("semantic") || n.startsWith("sem")) return "semantic_analysis";
    if (n.canFind("template") || n.canFind("instantiat")) return "template_instantiation";
    if (n.canFind("ctfe") || n.canFind("interpret")) return "ctfe";
    if (n.canFind("parse") || n.canFind("syntax")) return "parsing";
    if (n.canFind("lex") || n.canFind("token")) return "lexing";
    if (n.canFind("codegen") || n.canFind("backend") || n.canFind("emit") || n.canFind("object")) return "codegen_backend";
    if (n.canFind("optimi")) return "optimization";
    if (n.canFind("import")) return "module_loading";
    return "other";
}

Tuple!(string, string) dominantPhase(string phaseCsv)
{
    if (!exists(phaseCsv)) return tuple("missing", "0");
    auto lines = readText(phaseCsv).splitLines();
    if (lines.length < 2) return tuple("missing", "0");
    auto first = parseCsvLine(lines[1]);
    if (first.length < 4) return tuple("missing", "0");
    return tuple(first[0], first[3]);
}

Tuple!(string, string) dominantPhaseFromRows(PhaseRow[] rows)
{
    if (!rows.length) return tuple("missing", "0");
    return tuple(rows[0].phase, format("%.2f", rows[0].percent));
}

// --- Switch scale ---
void runSwitchScale(string[] args)
{
    string compiler = ".locald/dmd-nightly/osx/bin/dmd";
    string caseCounts = "100,1000,10000";
    int runs = 7;
    int warmups = 2;
    string outDir = "artifacts/switch_scaling";
    int timeoutSec = 120;

    auto help = getopt(
        args,
        "compiler", &compiler,
        "case-counts", &caseCounts,
        "runs", &runs,
        "warmups", &warmups,
        "out-dir", &outDir,
        "timeout-sec", &timeoutSec
    );
    enforce(help.helpWanted == false, "");

    mkdirRecurse(outDir);
    string[] countsRaw = caseCounts.split(',').map!(a => a.strip).filter!(a => a.length).array;
    int[] counts;
    foreach (raw; countsRaw) counts ~= to!int(raw);
    counts.sort;
    counts = counts.uniq.array;

    string summaryPath = buildPath(outDir, "summary.csv");
    writeText(summaryPath, "cases,median_ms,mad_ms,mean_ms,ci_low_ms,ci_high_ms,ok_runs,fail_runs\n");

    foreach (c; counts)
    {
        auto sourcePath = buildPath(outDir, format("switch_%s.d", c));
        writeSwitchSource(sourcePath, c);
        double[] times;
        int okRuns = 0;
        int failRuns = 0;
        int total = warmups + runs;
        foreach (i; 0 .. total)
        {
            auto outObj = buildPath(outDir, format("switch_%s_%s.o", c, i + 1));
            auto res = measureCompile(compiler, sourcePath, outObj, timeoutSec);
            if (res.exitCode == 0)
            {
                if (i >= warmups) times ~= cast(double) res.elapsedMs;
                okRuns++;
            }
            else
            {
                failRuns++;
            }
            if (exists(outObj)) remove(outObj);
        }

        double med = times.length ? median(times) : double.nan;
        double madVal = times.length ? mad(times) : double.nan;
        double meanVal = times.length ? mean(times) : double.nan;
        auto ci = times.length ? bootstrapCi(times, 2000) : tuple(double.nan, double.nan);

        append(summaryPath, format("%s,%.3f,%.3f,%.3f,%.3f,%.3f,%s,%s\n", c, med, madVal, meanVal, ci[0], ci[1], okRuns, failRuns));
    }

    string[] report;
    report ~= "# Switch-case scaling";
    report ~= "";
    report ~= "## Experiment topology";
    report ~= "";
    appendMermaid(report, [
        "flowchart TD",
        "    A[\"case-count sweep\"] --> B[\"writeSwitchSource()\"]",
        "    B --> C[\"measured compiles\"]",
        "    C --> D[\"summary.csv\"]",
        "    D --> E[\"report.md\"]"
    ]);
    report ~= "";
    report ~= "See summary.csv for results.";
    writeText(buildPath(outDir, "report.md"), report.join("\n") ~ "\n");
}

void writeSwitchSource(string path, int cases)
{
    string[] lines;
    lines ~= "// Auto-generated by dmdbench switch-scale";
    lines ~= "import std.stdio;";
    lines ~= "";
    lines ~= "int dispatch(int x) {";
    lines ~= "    switch (x) {";
    foreach (i; 0 .. cases)
    {
        lines ~= format("        case %s: return %s;", i, i);
    }
    lines ~= "        default: return -1;";
    lines ~= "    }";
    lines ~= "}";
    lines ~= "";
    lines ~= "void main() {";
    lines ~= "    long acc = 0;";
    lines ~= format("    enum int N = %s;", cases);
    lines ~= "    foreach (i; 0 .. 2000) {";
    lines ~= "        acc += dispatch(i % N);";
    lines ~= "    }";
    lines ~= "    if (acc == -1) writeln(\"never\");";
    lines ~= "}";
    writeText(path, lines.join("\n") ~ "\n");
}

// --- Wrapper commands ---
void runNotDone(string[] args)
{
    auto originalArgs = args.dup;
    foreach (arg; originalArgs)
    {
        if (arg == "--list-tasks")
        {
            printNotDoneCatalog(buildNotDoneRegistry());
            return;
        }
    }
    string outDir = "artifacts/not_done";
    string tasks = "";
    string phase = "all";
    string dmd = ".locald/dmd-nightly/osx/bin/dmd";
    string dmdRepo = "external/dmd";
    string ldc2 = ".locald/ldc-1.42.0/bin/ldc2";
    string clang = "clang";
    int zeroCostRuns = 9;
    int zeroCostWarmups = 2;
    int zeroCostIters = 25;
    int runtimeRuns = 7;
    int runtimeWarmups = 2;
    int linkerPayloadLen = 262_144;
    string phobosArchive = ".locald/dmd-nightly/osx/lib/libphobos2.a";
    int fuzzIters = 120;
    double fuzzTimeout = 2.0;
    int fuzzSeed = 42;
    double taskTimeout = 240.0;
    bool native = false;
    string python = ".venv/bin/python";
    bool pythonFallback = false;
    bool listTasks = false;

    auto help = getopt(
        args,
        "out-dir", &outDir,
        "tasks", &tasks,
        "phase", &phase,
        "dmd", &dmd,
        "dmd-repo", &dmdRepo,
        "ldc2", &ldc2,
        "clang", &clang,
        "zero-cost-runs", &zeroCostRuns,
        "zero-cost-warmups", &zeroCostWarmups,
        "zero-cost-iters", &zeroCostIters,
        "runtime-runs", &runtimeRuns,
        "runtime-warmups", &runtimeWarmups,
        "linker-payload-len", &linkerPayloadLen,
        "phobos-archive", &phobosArchive,
        "fuzz-iters", &fuzzIters,
        "fuzz-timeout", &fuzzTimeout,
        "fuzz-seed", &fuzzSeed,
        "task-timeout", &taskTimeout,
        "python-bin", &python,
        "native", &native,
        "python-fallback", &pythonFallback,
        "list-tasks", &listTasks
    );
    enforce(help.helpWanted == false, "");

    NotDoneContext ctx;
    ctx.outDir = outDir;
    ctx.dmd = dmd;
    ctx.dmdRepo = dmdRepo;
    ctx.ldc2 = ldc2;
    ctx.clang = clang;
    ctx.phobosArchive = phobosArchive;
    ctx.zeroCostRuns = zeroCostRuns;
    ctx.zeroCostWarmups = zeroCostWarmups;
    ctx.zeroCostIters = zeroCostIters;
    ctx.runtimeRuns = runtimeRuns;
    ctx.runtimeWarmups = runtimeWarmups;
    ctx.linkerPayloadLen = linkerPayloadLen;
    ctx.fuzzIters = fuzzIters;
    ctx.fuzzTimeout = fuzzTimeout;
    ctx.fuzzSeed = fuzzSeed;
    ctx.taskTimeout = taskTimeout;
    ctx.pythonBin = python.length ? python : "python3";
    ctx.pythonFallback = pythonFallback;

    auto registry = buildNotDoneRegistry();
    if (listTasks)
    {
        printNotDoneCatalog(registry);
        return;
    }

    auto selected = resolveNotDoneTasks(registry, tasks, phase);
    if (!selected.length)
    {
        stderr.writeln("No tasks selected. Use --tasks or --phase.");
        return;
    }

    if (native) ctx.pythonFallback = false;
    bool hasNonNative = false;
    foreach (name; selected)
    {
        auto ptr = findNotDoneTask(registry, name);
        if (ptr is null || !ptr.native)
        {
            hasNonNative = true;
            break;
        }
    }

    if (ctx.pythonFallback && hasNonNative)
    {
        runNotDonePythonFallback(ctx, selected);
        return;
    }

    auto nativeResults = runNotDoneRegistry(registry, selected, ctx);
    if (nativeResults.length)
    {
        writeNotDoneStatus(outDir, nativeResults);
    }
}

void runParserCompare(string[] args)
{
    auto cmd = ["./parser_threading_compare.sh"] ~ args;
    auto res = safeExecute(cmd);
    if (res.status != 0)
    {
        stderr.writeln("parser_threading_compare.sh failed with status ", res.status);
    }
}

void runPerfProbe(string[] args)
{
    auto cmd = ["./strict_perf_probe.sh"] ~ args;
    auto res = safeExecute(cmd);
    if (res.status != 0)
    {
        stderr.writeln("strict_perf_probe.sh failed with status ", res.status);
        exit(res.status);
    }
}

void runLinuxGapClose(string[] args)
{
    auto cmd = ["./linux_gap_close.sh"] ~ args;
    auto res = safeExecute(cmd);
    if (res.status != 0)
    {
        stderr.writeln("linux_gap_close.sh failed with status ", res.status);
        exit(res.status);
    }
}

string getEnvVar(string key)
{
    auto value = environment.get(key);
    return value is null ? "" : value;
}

bool hasLongOption(string[] args, string name)
{
    string ignored;
    return tryGetLongOption(args, name, ignored);
}

bool tryGetLongOption(string[] args, string name, out string value)
{
    auto flag = "--" ~ name;
    auto prefix = flag ~ "=";
    foreach (i, arg; args)
    {
        if (arg == flag)
        {
            if (i + 1 < args.length && !args[i + 1].startsWith("--"))
            {
                value = args[i + 1];
                return true;
            }
            value = "";
            return true;
        }
        if (arg.startsWith(prefix))
        {
            value = arg[prefix.length .. $];
            return true;
        }
    }
    return false;
}

string findExecutable(string name)
{
    if (name.canFind("/")) return exists(name) ? name : "";
    auto pathVar = getEnvVar("PATH");
    foreach (dir; pathVar.split(pathSeparator))
    {
        auto candidate = buildPath(dir, name);
        if (exists(candidate)) return candidate;
    }
    return "";
}

void mergeStatusCsv(string profileCsv, string parserCsv, string outCsv, string outMd)
{
    string header = "";
    string[] rows;

    foreach (path; [profileCsv, parserCsv])
    {
        if (!exists(path)) continue;
        auto lines = readText(path).splitLines();
        if (!lines.length) continue;
        if (!header.length) header = lines[0];
        foreach (line; lines[1 .. $])
        {
            if (line.length) rows ~= line;
        }
    }

    if (!header.length) return;
    writeText(outCsv, header ~ "\n" ~ rows.join("\n") ~ "\n");
    writeStatusMarkdown(outCsv, outMd);
}

void appendMermaid(ref string[] linesOut, string[] diagram)
{
    linesOut ~= "```mermaid";
    linesOut ~= diagram;
    linesOut ~= "```";
}

void writeStatusMarkdown(string csvPath, string mdPath)
{
    if (!exists(csvPath)) return;
    auto lines = readText(csvPath).splitLines();
    if (lines.length < 2) return;
    auto header = parseCsvLine(lines[0]);
    int taskIdx = -1;
    int statusIdx = -1;
    foreach (i, h; header)
    {
        if (h == "task") taskIdx = cast(int) i;
        if (h == "status") statusIdx = cast(int) i;
    }
    if (taskIdx < 0 || statusIdx < 0) return;

    string[] linesOut;
    linesOut ~= "# Linux gap-close status";
    linesOut ~= "";
    linesOut ~= "## Status topology";
    linesOut ~= "";
    appendMermaid(linesOut, [
        "flowchart TD",
        "    A[\"profile/status.csv\"] --> C[\"merged status.csv\"]",
        "    B[\"parser/status.csv\"] --> C",
        "    C --> D[\"status.md\"]"
    ]);
    linesOut ~= "";
    linesOut ~= "| Task | Status |";
    linesOut ~= "|---|---|";
    foreach (line; lines[1 .. $])
    {
        auto fields = parseCsvLine(line);
        if (fields.length <= max(taskIdx, statusIdx)) continue;
        linesOut ~= format("| %s | %s |", fields[taskIdx], fields[statusIdx]);
    }
    writeText(mdPath, linesOut.join("\n") ~ "\n");
}

struct TaskResult
{
    string task;
    string status;
    string[string] extras;
}

struct NotDoneContext
{
    string outDir;
    string dmd;
    string dmdRepo;
    string ldc2;
    string clang;
    string phobosArchive;
    int zeroCostRuns;
    int zeroCostWarmups;
    int zeroCostIters;
    int runtimeRuns;
    int runtimeWarmups;
    int linkerPayloadLen;
    int fuzzIters;
    double fuzzTimeout;
    int fuzzSeed;
    double taskTimeout;
    string pythonBin;
    bool pythonFallback;
}

alias TaskRunner = TaskResult function(ref NotDoneContext);

struct NotDoneTask
{
    string name;
    string description;
    string[] phases;
    bool native;
    string[] requires;
    TaskRunner runner;
}

TaskResult makeTaskResult(string task, string status, string[string] extras = null)
{
    TaskResult res;
    res.task = task;
    res.status = status;
    res.extras = extras;
    return res;
}

NotDoneTask[] buildNotDoneRegistry()
{
    NotDoneTask[] tasks;
    tasks ~= NotDoneTask("perfetto", "Perfetto screenshot capture", ["quick"], false, ["chrome"], null);
    tasks ~= NotDoneTask("zero_cost", "std.range/std.algorithm vs foreach (LDC)", ["quick"], true, ["ldc2"], &runTaskZeroCost);
    tasks ~= NotDoneTask("phobos_sections", "Phobos archive section sizing", ["quick"], true, ["libphobos2.a"], &runTaskPhobosSections);
    tasks ~= NotDoneTask("gc_kernels", "GC micro-kernels", ["quick", "runtime_libs", "broader_gist"], true, ["ldc2"], &runTaskGCKernels);
    tasks ~= NotDoneTask("aa_kernels", "Associative array kernels", ["quick", "runtime_libs", "broader_gist"], true, ["ldc2"], &runTaskAAKernels);
    tasks ~= NotDoneTask("float_to_string_kernels", "Float-to-string kernels", ["quick", "runtime_libs", "broader_gist"], true, ["ldc2"], &runTaskFloatToString);
    tasks ~= NotDoneTask("dub_pgo", "Dub PGO benchmark", ["broader_gist"], false, ["dub", "ldmd2", "ldc-profdata"], null);
    tasks ~= NotDoneTask("non_zero_init_structs", "Large non-zero-init struct scan", ["analysis"], false, ["dmd", "git"], null);
    tasks ~= NotDoneTask("linker_strip", "Dead-strip behavior", ["quick"], true, ["ldc2"], &runTaskLinkerStrip);
    tasks ~= NotDoneTask("ast_field_order", "AST field-order experiment", ["invasive"], false, ["dmd", "rdmd"], null);
    tasks ~= NotDoneTask("parser_parallel", "Parallel lexer/parser prototype", ["invasive"], false, ["dmd"], null);
    tasks ~= NotDoneTask("parser_incompiler_parallel", "In-compiler parser threading", ["invasive"], false, ["dmd"], null);
    tasks ~= NotDoneTask("allocator_compare", "Allocator replacement comparison", ["analysis"], false, ["dmd"], null);
    tasks ~= NotDoneTask("c_vs_d_asm", "C vs D assembly comparison", ["quick"], true, ["ldc2", "clang"], &runTaskCvsDAsm);
    tasks ~= NotDoneTask("dmd_profile_compare", "DMD -profile comparison", ["analysis"], false, ["dmd"], null);
    tasks ~= NotDoneTask("compiler_fuzz", "Compiler fuzzing", ["quick"], true, ["dmd", "dmd-repo"], &runTaskCompilerFuzz);
    tasks ~= NotDoneTask("large_char_array", "char[] > 4GB probe", ["quick"], true, ["ldc2"], &runTaskLargeCharArray);
    return tasks;
}

NotDoneTask* findNotDoneTask(NotDoneTask[] registry, string name)
{
    foreach (ref task; registry)
    {
        if (task.name == name) return &task;
    }
    return null;
}

string[] resolveNotDoneTasks(NotDoneTask[] registry, string tasks, string phase)
{
    if (tasks.length)
    {
        return tasks.split(',').map!(t => t.strip).filter!(t => t.length).array;
    }
    if (phase == "all")
    {
        return registry.map!(t => t.name).array;
    }
    string[] selected;
    foreach (task; registry)
    {
        if (task.phases.canFind(phase)) selected ~= task.name;
    }
    return selected;
}

void printNotDoneCatalog(NotDoneTask[] registry)
{
    writeln("Not-done task catalog:");
    foreach (task; registry)
    {
        auto phase = task.phases.length ? task.phases.join("|") : "-";
        auto reqs = task.requires.length ? task.requires.join(",") : "-";
        writeln(format("- %s [%s] native=%s requires=%s :: %s", task.name, phase, task.native ? "yes" : "no", reqs, task.description));
    }
}

TaskResult runTaskCompilerFuzz(ref NotDoneContext ctx)
{
    return runCompilerFuzz(ctx.outDir, ctx.dmd, ctx.dmdRepo, ctx.fuzzIters, ctx.fuzzTimeout, ctx.fuzzSeed);
}

TaskResult runTaskLargeCharArray(ref NotDoneContext ctx)
{
    return runLargeCharArray(ctx.outDir, ctx.ldc2, ctx.taskTimeout);
}

TaskResult runTaskCvsDAsm(ref NotDoneContext ctx)
{
    return runCvsDAsm(ctx.outDir, ctx.ldc2, ctx.clang, ctx.taskTimeout);
}

TaskResult runTaskZeroCost(ref NotDoneContext ctx)
{
    return runZeroCost(ctx.outDir, ctx.ldc2, ctx.zeroCostRuns, ctx.zeroCostWarmups, ctx.zeroCostIters, ctx.taskTimeout);
}

TaskResult runTaskGCKernels(ref NotDoneContext ctx)
{
    return runGCKernels(ctx.outDir, ctx.ldc2, ctx.runtimeRuns, ctx.runtimeWarmups, ctx.taskTimeout);
}

TaskResult runTaskAAKernels(ref NotDoneContext ctx)
{
    return runAAKernels(ctx.outDir, ctx.ldc2, ctx.runtimeRuns, ctx.runtimeWarmups, ctx.taskTimeout);
}

TaskResult runTaskLinkerStrip(ref NotDoneContext ctx)
{
    return runLinkerStrip(ctx.outDir, ctx.ldc2, ctx.linkerPayloadLen, ctx.taskTimeout);
}

TaskResult runTaskFloatToString(ref NotDoneContext ctx)
{
    return runFloatToString(ctx.outDir, ctx.ldc2, ctx.runtimeRuns, ctx.runtimeWarmups, ctx.taskTimeout);
}

TaskResult runTaskPhobosSections(ref NotDoneContext ctx)
{
    return runPhobosSections(ctx.outDir, ctx.phobosArchive);
}

TaskResult[] runNotDoneRegistry(NotDoneTask[] registry, string[] selected, ref NotDoneContext ctx)
{
    TaskResult[] results;

    foreach (name; selected)
    {
        auto taskPtr = findNotDoneTask(registry, name);
        if (taskPtr is null)
        {
            results ~= makeTaskResult(name, "missing", ["reason": "task not registered"]);
            continue;
        }
        auto task = *taskPtr;
        if (!task.native)
        {
            results ~= makeTaskResult(name, "blocked", ["reason": "native implementation missing"]);
            continue;
        }
        if (task.runner is null)
        {
            results ~= makeTaskResult(name, "blocked", ["reason": "no runner configured"]);
            continue;
        }
        results ~= task.runner(ctx);
    }

    return results;
}

void runNotDonePythonFallback(ref NotDoneContext ctx, string[] selected)
{
    if (!ctx.pythonFallback) return;
    string[] pythonTasks;
    auto registry = buildNotDoneRegistry();
    foreach (name; selected)
    {
        auto taskPtr = findNotDoneTask(registry, name);
        if (taskPtr is null || !taskPtr.native) pythonTasks ~= name;
    }
    if (!pythonTasks.length) return;
    if (!exists(ctx.pythonBin)) ctx.pythonBin = "python3";
    auto cmd = [
        ctx.pythonBin,
        "not_done_experiments.py",
        "--out-dir", ctx.outDir,
        "--tasks", pythonTasks.join(","),
        "--dmd", ctx.dmd,
        "--dmd-repo", ctx.dmdRepo,
        "--ldc2", ctx.ldc2,
        "--clang", ctx.clang,
        "--phobos-archive", ctx.phobosArchive,
        "--zero-cost-runs", to!string(ctx.zeroCostRuns),
        "--zero-cost-warmups", to!string(ctx.zeroCostWarmups),
        "--zero-cost-iters", to!string(ctx.zeroCostIters),
        "--runtime-runs", to!string(ctx.runtimeRuns),
        "--runtime-warmups", to!string(ctx.runtimeWarmups),
        "--fuzz-iters", to!string(ctx.fuzzIters),
        "--fuzz-timeout", to!string(ctx.fuzzTimeout),
        "--fuzz-seed", to!string(ctx.fuzzSeed),
        "--task-timeout", to!string(ctx.taskTimeout)
    ];
    auto res = safeExecute(cmd);
    if (res.status != 0)
    {
        stderr.writeln("not_done_experiments.py failed with status ", res.status);
    }
}

void runNotDoneNative(
    string outDir,
    string[] selected,
    string dmd,
    string dmdRepo,
    string ldc2,
    string clang,
    string phobosArchive,
    int zeroCostRuns,
    int zeroCostWarmups,
    int zeroCostIters,
    int runtimeRuns,
    int runtimeWarmups,
    int linkerPayloadLen,
    int fuzzIters,
    double fuzzTimeout,
    int fuzzSeed,
    double taskTimeout)
{
    if (!selected.length)
    {
        stderr.writeln("No native tasks selected. Use --tasks or --phase quick/analysis.");
        return;
    }

    TaskResult[] results;
    foreach (task; selected)
    {
        if (task == "compiler_fuzz")
        {
            results ~= runCompilerFuzz(outDir, dmd, dmdRepo, fuzzIters, fuzzTimeout, fuzzSeed);
        }
        else if (task == "large_char_array")
        {
            results ~= runLargeCharArray(outDir, ldc2, taskTimeout);
        }
        else if (task == "c_vs_d_asm")
        {
            results ~= runCvsDAsm(outDir, ldc2, clang, taskTimeout);
        }
        else if (task == "zero_cost")
        {
            results ~= runZeroCost(outDir, ldc2, zeroCostRuns, zeroCostWarmups, zeroCostIters, taskTimeout);
        }
        else if (task == "gc_kernels")
        {
            results ~= runGCKernels(outDir, ldc2, runtimeRuns, runtimeWarmups, taskTimeout);
        }
        else if (task == "aa_kernels")
        {
            results ~= runAAKernels(outDir, ldc2, runtimeRuns, runtimeWarmups, taskTimeout);
        }
        else if (task == "linker_strip")
        {
            results ~= runLinkerStrip(outDir, ldc2, linkerPayloadLen, taskTimeout);
        }
        else if (task == "float_to_string_kernels")
        {
            results ~= runFloatToString(outDir, ldc2, runtimeRuns, runtimeWarmups, taskTimeout);
        }
        else if (task == "phobos_sections")
        {
            results ~= runPhobosSections(outDir, phobosArchive);
        }
        else
        {
            results ~= makeTaskResult(task, "skipped", ["reason": "not implemented in native mode"]);
        }
    }

    writeNotDoneStatus(outDir, results);
}

void writeNotDoneStatus(string outDir, TaskResult[] results)
{
    if (!results.length) return;
    mkdirRecurse(outDir);
    auto statusCsv = buildPath(outDir, "status.csv");
    auto statusMd = buildPath(outDir, "status.md");
    auto manifest = buildPath(outDir, "manifest.json");

    string[] keys = ["task", "status"];
    foreach (result; results)
    {
        if (result.extras.length)
        {
            foreach (key; result.extras.keys)
            {
                if (!keys.canFind(key)) keys ~= key;
            }
        }
    }

    writeText(statusCsv, keys.join(",") ~ "\n");
    foreach (result; results)
    {
        string[] fields;
        foreach (key; keys)
        {
            if (key == "task") fields ~= result.task;
            else if (key == "status") fields ~= result.status;
            else
            {
                if (auto v = key in result.extras)
                    fields ~= *v;
                else
                    fields ~= "";
            }
        }
        append(statusCsv, fields.map!csvEscape.join(",") ~ "\n");
    }

    string[] md;
    md ~= "# Dennis gist: Not Done status (native)";
    md ~= "";
    md ~= "## Execution topology";
    md ~= "";
    appendMermaid(md, [
        "flowchart TD",
        "    A[\"selected native tasks\"] --> B[\"native runners\"]",
        "    B --> C[\"per-task folders\"]",
        "    B --> D[\"status.csv\"]",
        "    B --> E[\"manifest.json\"]",
        "    D --> F[\"status.md\"]",
        "    C --> F",
        "    E --> F"
    ]);
    md ~= "";
    md ~= "| Task | Status | Key result |";
    md ~= "|---|---|---|";
    foreach (result; results)
    {
        string[] bits;
        if (result.extras.length)
        {
            foreach (key; result.extras.keys)
            {
                bits ~= format("%s=%s", key, result.extras[key]);
                if (bits.length >= 3) break;
            }
        }
        md ~= format("| %s | %s | %s |", result.task, result.status, bits.length ? bits.join("; ") : "-");
    }
    writeText(statusMd, md.join("\n") ~ "\n");

    auto payload = JSONValue([
        "tool": JSONValue("dmdbench"),
        "generated": JSONValue(utcNowStamp()),
        "hostname": JSONValue(hostName()),
        "cpu": JSONValue(cpuBrand()),
        "os": JSONValue(osValue())
    ]);
    writeText(manifest, payload.toPrettyString());
}

TaskResult runCompilerFuzz(string outDir, string dmd, string dmdRepo, int iterations, double timeoutSec, int seed)
{
    auto taskDir = buildPath(outDir, "compiler_fuzz");
    auto generatedDir = buildPath(taskDir, "generated");
    mkdirRecurse(generatedDir);

    auto testRoot = buildPath(dmdRepo, "compiler", "test");
    if (!exists(testRoot))
    {
        return makeTaskResult("compiler_fuzz", "blocked", ["reason": "missing " ~ testRoot]);
    }

    string[] candidates;
    foreach (sub; ["compilable", "runnable", "fail_compilation"])
    {
        auto root = buildPath(testRoot, sub);
        if (!exists(root)) continue;
        foreach (entry; dirEntries(root, SpanMode.depth))
        {
            if (entry.isDir) continue;
            if (!entry.name.endsWith(".d")) continue;
            auto size = entry.size;
            if (size > 0 && size <= 24_000) candidates ~= entry.name;
        }
    }
    if (!candidates.length)
    {
        return makeTaskResult("compiler_fuzz", "blocked", ["reason": "no candidate seed files discovered"]);
    }

    auto resultsCsv = buildPath(taskDir, "results.csv");
    writeText(resultsCsv, "iteration,seed_file,sample_file,outcome,return_code,elapsed_ms,stderr_tail\n");

    int ok = 0;
    int compileError = 0;
    int timeout = 0;
    int crash = 0;

    auto rng = Random(seed);
    auto objPath = buildPath(taskDir, "fuzz_tmp.o");

    foreach (idx; 1 .. iterations + 1)
    {
        auto seedFile = candidates[uniform(0, cast(int) candidates.length, rng)];
        string original;
        try original = readText(seedFile);
        catch (Exception) continue;

        auto mutated = mutateText(original, rng);
        auto samplePath = buildPath(generatedDir, format("mut_%05d.d", idx));
        writeText(samplePath, mutated);

        auto cmd = [dmd, "-c", samplePath, "-of=" ~ objPath, "-I" ~ testRoot, "-fmax-errors=1"];
        auto res = runProcessWithTimeout(cmd, timeoutSec);

        string outcome = "compile_error";
        if (res.timedOut || res.exitCode == 124)
        {
            outcome = "timeout";
            timeout++;
        }
        else if (res.exitCode == 0)
        {
            outcome = "ok";
            ok++;
        }
        else if (res.exitCode < 0)
        {
            outcome = "crash";
            crash++;
        }
        else
        {
            compileError++;
        }

        auto relSeed = relativePath(seedFile, dmdRepo);
        auto relSample = relativePath(samplePath, taskDir);
        append(resultsCsv, format("%s,%s,%s,%s,%s,%.3f,%s\n",
            idx,
            relSeed.length ? relSeed : seedFile,
            relSample.length ? relSample : samplePath,
            outcome,
            res.exitCode,
            res.elapsedMs,
            res.timedOut ? "timeout" : ""
        ));

        if (outcome == "ok" && exists(samplePath)) remove(samplePath);
        if (exists(objPath)) remove(objPath);
    }

    return makeTaskResult(
        "compiler_fuzz",
        "done",
        [
            "iterations": to!string(iterations),
            "ok": to!string(ok),
            "compile_error": to!string(compileError),
            "timeout": to!string(timeout),
            "crash": to!string(crash)
        ]
    );
}

TaskResult runLargeCharArray(string outDir, string ldc2, double taskTimeout)
{
    version (Posix) {} else return makeTaskResult("large_char_array", "blocked", ["reason": "posix-only test"]);
    auto taskDir = buildPath(outDir, "large_char_array_4gb");
    mkdirRecurse(taskDir);

    auto source = buildPath(taskDir, "large_char_array_4gb.d");
    auto exe = buildPath(taskDir, "large_char_array_4gb");

    string[] lines;
    lines ~= "module large_char_array_4gb;";
    lines ~= "";
    lines ~= "import core.stdc.errno : errno;";
    lines ~= "import core.sys.posix.sys.mman : MAP_ANON, MAP_FAILED, MAP_PRIVATE, PROT_READ, PROT_WRITE, mmap, munmap;";
    lines ~= "import std.stdio : writeln;";
    lines ~= "";
    lines ~= "enum ulong FOUR_GB = 4_294_967_296UL;";
    lines ~= "enum size_t LEN = cast(size_t) (FOUR_GB + 8_192UL);";
    lines ~= "";
    lines ~= "int main()";
    lines ~= "{";
    lines ~= "    void* p = mmap(null, LEN, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);";
    lines ~= "    if (p == MAP_FAILED)";
    lines ~= "    {";
    lines ~= "        writeln(\"mmap_failed errno=\", errno);";
    lines ~= "        return 2;";
    lines ~= "    }";
    lines ~= "    scope(exit) munmap(p, LEN);";
    lines ~= "";
    lines ~= "    auto arr = (cast(char*) p)[0 .. LEN];";
    lines ~= "    if (arr.length != LEN)";
    lines ~= "    {";
    lines ~= "        writeln(\"length_mismatch len=\", arr.length, \" expected=\", LEN);";
    lines ~= "        return 3;";
    lines ~= "    }";
    lines ~= "";
    lines ~= "    arr[0] = 'A';";
    lines ~= "    arr[cast(size_t) FOUR_GB] = 'B';";
    lines ~= "    arr[$ - 1] = 'Z';";
    lines ~= "";
    lines ~= "    auto hi = arr[cast(size_t) FOUR_GB .. cast(size_t) FOUR_GB + 16];";
    lines ~= "    hi[] = 'Q';";
    lines ~= "";
    lines ~= "    auto copyProbe = arr[cast(size_t) FOUR_GB - 16 .. cast(size_t) FOUR_GB + 16].dup;";
    lines ~= "    bool ok = arr[0] == 'A'";
    lines ~= "        && arr[cast(size_t) FOUR_GB] == 'Q'";
    lines ~= "        && arr[$ - 1] == 'Z'";
    lines ~= "        && hi.length == 16";
    lines ~= "        && copyProbe.length == 32;";
    lines ~= "";
    lines ~= "    writeln(\"len=\", arr.length, \" hi_len=\", hi.length, \" copy_len=\", copyProbe.length, \" ok=\", ok ? 1 : 0);";
    lines ~= "    return ok ? 0 : 4;";
    lines ~= "}";

    writeText(source, lines.join("\n") ~ "\n");

    auto compileRes = runProcessWithTimeout([ldc2, source, "-O3", "-release", "-boundscheck=off", "-of=" ~ exe], taskTimeout);
    if (compileRes.exitCode != 0)
    {
        return makeTaskResult("large_char_array", "failed", ["reason": "compile failed", "return_code": to!string(compileRes.exitCode)]);
    }

    auto runRes = safeExecute([exe]);
    writeText(buildPath(taskDir, "run_stdout.txt"), runRes.output);
    writeText(buildPath(taskDir, "run_stderr.txt"), "");

    auto status = runRes.status == 0 ? "done" : "failed";
    auto trimmed = runRes.output.strip.replace("\n", " ");
    return makeTaskResult("large_char_array", status, ["return_code": to!string(runRes.status), "stdout": trimmed]);
}

TaskResult runCvsDAsm(string outDir, string ldc2, string clang, double taskTimeout)
{
    auto taskDir = buildPath(outDir, "c_vs_d_assembly");
    mkdirRecurse(taskDir);

    struct Kernel
    {
        string name;
        string functionName;
        string cBody;
        string dBody;
    }

    Kernel[] kernels = [
        Kernel("weighted_sum", "weighted_sum",
            "long weighted_sum(const int* data, size_t n) {\n" ~
            "    long acc = 0;\n" ~
            "    for (size_t i = 0; i < n; ++i) {\n" ~
            "        int v = data[i];\n" ~
            "        if ((v & 1) == 0) {\n" ~
            "            acc += (long)v * 3 + 1;\n" ~
            "        }\n" ~
            "    }\n" ~
            "    return acc;\n" ~
            "}\n",
            "long weighted_sum(const(int)* data, size_t n) @nogc nothrow\n" ~
            "{\n" ~
            "    long acc = 0;\n" ~
            "    for (size_t i = 0; i < n; ++i)\n" ~
            "    {\n" ~
            "        int v = data[i];\n" ~
            "        if ((v & 1) == 0)\n" ~
            "        {\n" ~
            "            acc += cast(long) v * 3 + 1;\n" ~
            "        }\n" ~
            "    }\n" ~
            "    return acc;\n" ~
            "}\n"),
        Kernel("saxpy_like", "saxpy_like",
            "void saxpy_like(float* out, const float* x, const float* y, float a, size_t n) {\n" ~
            "    for (size_t i = 0; i < n; ++i) {\n" ~
            "        out[i] = a * x[i] + y[i];\n" ~
            "    }\n" ~
            "}\n",
            "void saxpy_like(float* dst, const(float)* x, const(float)* y, float a, size_t n) @nogc nothrow\n" ~
            "{\n" ~
            "    for (size_t i = 0; i < n; ++i)\n" ~
            "    {\n" ~
            "        dst[i] = a * x[i] + y[i];\n" ~
            "    }\n" ~
            "}\n"),
        Kernel("branch_mix", "branch_mix",
            "int branch_mix(const int* data, size_t n, int bias) {\n" ~
            "    int acc = 0;\n" ~
            "    for (size_t i = 0; i < n; ++i) {\n" ~
            "        int v = data[i] + bias;\n" ~
            "        if ((v & 3) == 0) acc += v;\n" ~
            "        else if ((v & 3) == 1) acc -= (v << 1);\n" ~
            "        else if ((v & 3) == 2) acc ^= v;\n" ~
            "        else acc += (v >> 1);\n" ~
            "    }\n" ~
            "    return acc;\n" ~
            "}\n",
            "int branch_mix(const(int)* data, size_t n, int bias) @nogc nothrow\n" ~
            "{\n" ~
            "    int acc = 0;\n" ~
            "    for (size_t i = 0; i < n; ++i)\n" ~
            "    {\n" ~
            "        int v = data[i] + bias;\n" ~
            "        if ((v & 3) == 0) acc += v;\n" ~
            "        else if ((v & 3) == 1) acc -= (v << 1);\n" ~
            "        else if ((v & 3) == 2) acc ^= v;\n" ~
            "        else acc += (v >> 1);\n" ~
            "    }\n" ~
            "    return acc;\n" ~
            "}\n"),
        Kernel("memxor", "memxor",
            "void memxor(unsigned char* dst, const unsigned char* a, const unsigned char* b, size_t n) {\n" ~
            "    for (size_t i = 0; i < n; ++i) {\n" ~
            "        dst[i] = (unsigned char)(a[i] ^ b[i]);\n" ~
            "    }\n" ~
            "}\n",
            "void memxor(ubyte* dst, const(ubyte)* a, const(ubyte)* b, size_t n) @nogc nothrow\n" ~
            "{\n" ~
            "    for (size_t i = 0; i < n; ++i)\n" ~
            "    {\n" ~
            "        dst[i] = cast(ubyte)(a[i] ^ b[i]);\n" ~
            "    }\n" ~
            "}\n"),
        Kernel("clamp_sum", "clamp_sum",
            "long clamp_sum(const int* data, size_t n, int lo, int hi) {\n" ~
            "    long acc = 0;\n" ~
            "    for (size_t i = 0; i < n; ++i) {\n" ~
            "        int v = data[i];\n" ~
            "        if (v < lo) v = lo;\n" ~
            "        if (v > hi) v = hi;\n" ~
            "        acc += v;\n" ~
            "    }\n" ~
            "    return acc;\n" ~
            "}\n",
            "long clamp_sum(const(int)* data, size_t n, int lo, int hi) @nogc nothrow\n" ~
            "{\n" ~
            "    long acc = 0;\n" ~
            "    for (size_t i = 0; i < n; ++i)\n" ~
            "    {\n" ~
            "        int v = data[i];\n" ~
            "        if (v < lo) v = lo;\n" ~
            "        if (v > hi) v = hi;\n" ~
            "        acc += v;\n" ~
            "    }\n" ~
            "    return acc;\n" ~
            "}\n")
    ];

    auto summaryCsv = buildPath(taskDir, "summary.csv");
    auto similarityCsv = buildPath(taskDir, "similarity.csv");
    writeText(summaryCsv, "kernel,toolchain,instruction_count\n");
    writeText(similarityCsv, "kernel,instruction_similarity_ratio,clang_instruction_count,ldc_instruction_count,diff_file\n");

    int totalClang = 0;
    int totalLdc = 0;
    double[] ratios;
    string[] kernelNames;
    size_t[] clangCounts;
    size_t[] ldcCounts;

    foreach (kernel; kernels)
    {
        auto cSrc = buildPath(taskDir, kernel.name ~ ".c");
        auto dSrc = buildPath(taskDir, kernel.name ~ ".d");
        auto cAsm = buildPath(taskDir, kernel.name ~ "_clang.s");
        auto dAsm = buildPath(taskDir, kernel.name ~ "_ldc.s");
        auto diffPath = buildPath(taskDir, kernel.name ~ "_instruction_diff.txt");

        string cText = "#include <stddef.h>\n\n" ~ kernel.cBody;
        string dText = "module " ~ kernel.name ~ "_d;\n\nextern(C):\n\n" ~ kernel.dBody;
        writeText(cSrc, cText);
        writeText(dSrc, dText);

        auto clangRes = runProcessWithTimeout([clang, "-O3", "-S", cSrc, "-o", cAsm], taskTimeout);
        if (clangRes.exitCode != 0)
        {
            return makeTaskResult("c_vs_d_asm", "failed", ["reason": "clang failed", "return_code": to!string(clangRes.exitCode)]);
        }
        auto ldcRes = runProcessWithTimeout([ldc2, "-betterC", "-O3", "-release", "-boundscheck=off", "-output-s", dSrc, "-of=" ~ dAsm], taskTimeout);
        if (ldcRes.exitCode != 0)
        {
            return makeTaskResult("c_vs_d_asm", "failed", ["reason": "ldc2 failed", "return_code": to!string(ldcRes.exitCode)]);
        }

        auto clangInsts = extractAsmInstructions(cAsm, "_" ~ kernel.functionName);
        if (!clangInsts.length) clangInsts = extractAsmInstructions(cAsm, kernel.functionName);
        auto ldcInsts = extractAsmInstructions(dAsm, "_" ~ kernel.functionName);
        if (!ldcInsts.length) ldcInsts = extractAsmInstructions(dAsm, kernel.functionName);

        totalClang += cast(int) clangInsts.length;
        totalLdc += cast(int) ldcInsts.length;

        auto ratio = sequenceSimilarity(clangInsts, ldcInsts);
        ratios ~= ratio;
        kernelNames ~= kernel.name;
        clangCounts ~= clangInsts.length;
        ldcCounts ~= ldcInsts.length;

        append(summaryCsv, format("%s,clang,%s\n", kernel.name, clangInsts.length));
        append(summaryCsv, format("%s,ldc2,%s\n", kernel.name, ldcInsts.length));
        append(similarityCsv, format("%s,%.4f,%s,%s,%s\n", kernel.name, ratio, clangInsts.length, ldcInsts.length, baseName(diffPath)));

        writeInstructionDiff(diffPath, clangInsts, ldcInsts, "clang_" ~ kernel.name, "ldc_" ~ kernel.name);
    }

    double avgRatio = ratios.length ? mean(ratios) : 0.0;
    double minRatio = ratios.length ? ratios.minElement : 0.0;
    double maxRatio = ratios.length ? ratios.maxElement : 0.0;

    string[] report;
    report ~= "# C vs D assembly comparison";
    report ~= "";
    report ~= "## Comparison topology";
    report ~= "";
    appendMermaid(report, [
        "flowchart TD",
        "    A[\"kernel set\"] --> B[\"clang -O3\"]",
        "    A --> C[\"ldc2 -O3\"]",
        "    B --> D[\"instruction extraction\"]",
        "    C --> D",
        "    D --> E[\"similarity.csv\"]",
        "    D --> F[\"*_instruction_diff.txt\"]",
        "    E --> G[\"report.md\"]",
        "    F --> H[\"godbolt_notes.md\"]"
    ]);
    report ~= "";
    report ~= format("- Kernels compared: %s", kernels.length);
    report ~= format("- Total clang instruction count: %s", totalClang);
    report ~= format("- Total ldc2 instruction count: %s", totalLdc);
    report ~= format("- Similarity ratio (avg/min/max): %.4f / %.4f / %.4f", avgRatio, minRatio, maxRatio);
    report ~= "";
    report ~= "| Kernel | Clang inst | LDC inst | Similarity |";
    report ~= "|---|---:|---:|---:|";
    foreach (idx, name; kernelNames)
    {
        report ~= format("| %s | %s | %s | %.4f |", name, clangCounts[idx], ldcCounts[idx], ratios[idx]);
    }
    writeText(buildPath(taskDir, "report.md"), report.join("\n") ~ "\n");

    string[] godbolt;
    godbolt ~= "# Compiler Explorer follow-up";
    godbolt ~= "";
    godbolt ~= "Local assembly diffs were produced for each kernel in this folder.";
    godbolt ~= "Use https://d.godbolt.org/ with -O3 and compare clang vs ldc2 for:";
    godbolt ~= "";
    godbolt ~= "## Follow-up topology";
    godbolt ~= "";
    appendMermaid(godbolt, [
        "flowchart TD",
        "    A[\"kernel pair\\nC source + D source\"] --> B[\"local clang/ldc2 assembly diff\"]",
        "    B --> C[\"*_instruction_diff.txt\"]",
        "    C --> D[\"godbolt_notes.md\"]",
        "    D --> E[\"d.godbolt.org\\nmanual visual confirmation\"]"
    ]);
    foreach (kernel; kernels)
    {
        godbolt ~= format("- `%s.c` vs `%s.d`", kernel.name, kernel.name);
    }
    writeText(buildPath(taskDir, "godbolt_notes.md"), godbolt.join("\n") ~ "\n");

    return makeTaskResult(
        "c_vs_d_asm",
        "done",
        [
            "clang_instruction_count": to!string(totalClang),
            "ldc_instruction_count": to!string(totalLdc),
            "instruction_similarity_ratio": format("%.4f", avgRatio),
            "kernel_count": to!string(kernels.length),
            "godbolt_ui_url": "https://d.godbolt.org/"
        ]
    );
}

string[] extractAsmInstructions(string path, string label)
{
    if (!exists(path)) return [];
    auto lines = readText(path).splitLines();
    int startIdx = -1;
    auto target = label ~ ":";
    foreach (i, line; lines)
    {
        auto stripped = line.strip;
        if (stripped == target || stripped.startsWith(target ~ " "))
        {
            startIdx = cast(int) i + 1;
            break;
        }
    }
    if (startIdx < 0) return [];

    string[] instructions;
    foreach (line; lines[startIdx .. $])
    {
        auto stripped = line.strip;
        if (!stripped.length) continue;
        if (stripped.length && stripped[$ - 1] == ':') break;
        if (stripped.startsWith(".")) continue;
        auto noComment = stripped.split("//")[0].split(";")[0].strip;
        if (!noComment.length) continue;
        instructions ~= std.regex.replace(noComment, regex("\\s+"), " ");
    }
    return instructions;
}

double sequenceSimilarity(string[] a, string[] b)
{
    if (!a.length && !b.length) return 1.0;
    auto lcs = lcsLength(a, b);
    return (2.0 * lcs) / (a.length + b.length);
}

int lcsLength(string[] a, string[] b)
{
    if (!a.length || !b.length) return 0;
    int n = cast(int) a.length;
    int m = cast(int) b.length;
    int[] prev;
    int[] curr;
    prev.length = m + 1;
    curr.length = m + 1;
    foreach (i; 1 .. n + 1)
    {
        curr[0] = 0;
        foreach (j; 1 .. m + 1)
        {
            if (a[i - 1] == b[j - 1])
                curr[j] = prev[j - 1] + 1;
            else
                curr[j] = max(prev[j], curr[j - 1]);
        }
        prev = curr.dup;
    }
    return prev[m];
}

void writeInstructionDiff(string path, string[] a, string[] b, string aLabel, string bLabel)
{
    string[] lines;
    lines ~= "--- " ~ aLabel;
    lines ~= "+++ " ~ bLabel;
    auto n = max(a.length, b.length);
    foreach (i; 0 .. n)
    {
        if (i < a.length && (i >= b.length || a[i] != b[i]))
            lines ~= "- " ~ a[i];
        if (i < b.length && (i >= a.length || a[i] != b[i]))
            lines ~= "+ " ~ b[i];
    }
    writeText(path, lines.join("\n") ~ "\n");
}

TaskResult runZeroCost(string outDir, string ldc2, int runs, int warmups, int iterations, double timeoutSec)
{
    auto taskDir = buildPath(outDir, "zero_cost_ldc");
    mkdirRecurse(taskDir);

    auto source = buildPath(taskDir, "zero_cost.d");
    auto exe = buildPath(taskDir, "zero_cost");
    auto obj = buildPath(taskDir, "zero_cost.o");
    auto disasmPath = buildPath(taskDir, "zero_cost.objdump.txt");

    string[] lines;
    lines ~= "module zero_cost;";
    lines ~= "";
    lines ~= "import std.algorithm : filter, map, sum;";
    lines ~= "import std.array : array;";
    lines ~= "import std.conv : to;";
    lines ~= "import std.range : iota;";
    lines ~= "import std.stdio : stderr, writeln;";
    lines ~= "";
    lines ~= "enum DATA_LEN = 400_000;";
    lines ~= "";
    lines ~= "pragma(inline, false)";
    lines ~= "extern(C) long proceduralSum(scope const(int)[] values) @safe nothrow @nogc";
    lines ~= "{";
    lines ~= "    long acc = 0;";
    lines ~= "    foreach (v; values)";
    lines ~= "    {";
    lines ~= "        if ((v & 1) == 0)";
    lines ~= "        {";
    lines ~= "            acc += cast(long) v * 3 + 1;";
    lines ~= "        }";
    lines ~= "    }";
    lines ~= "    return acc;";
    lines ~= "}";
    lines ~= "";
    lines ~= "pragma(inline, false)";
    lines ~= "extern(C) long rangeSum(scope const(int)[] values) @safe nothrow @nogc";
    lines ~= "{";
    lines ~= "    return values";
    lines ~= "        .filter!(v => (v & 1) == 0)";
    lines ~= "        .map!(v => cast(long) v * 3 + 1)";
    lines ~= "        .sum;";
    lines ~= "}";
    lines ~= "";
    lines ~= "int main(string[] args)";
    lines ~= "{";
    lines ~= "    if (args.length != 3)";
    lines ~= "    {";
    lines ~= "        stderr.writeln(\"usage: ./zero_cost <proc|range> <iterations>\");";
    lines ~= "        return 2;";
    lines ~= "    }";
    lines ~= "";
    lines ~= "    string mode = args[1];";
    lines ~= "    int iters = args[2].to!int;";
    lines ~= "    long sink = 0;";
    lines ~= "    auto data = iota(0, DATA_LEN).array;";
    lines ~= "";
    lines ~= "    foreach (_; 0 .. iters)";
    lines ~= "    {";
    lines ~= "        if (mode == \"proc\")";
    lines ~= "        {";
    lines ~= "            sink ^= proceduralSum(data);";
    lines ~= "        }";
    lines ~= "        else if (mode == \"range\")";
    lines ~= "        {";
    lines ~= "            sink ^= rangeSum(data);";
    lines ~= "        }";
    lines ~= "        else";
    lines ~= "        {";
    lines ~= "            stderr.writeln(\"invalid mode: \", mode);";
    lines ~= "            return 3;";
    lines ~= "        }";
    lines ~= "    }";
    lines ~= "";
    lines ~= "    writeln(sink);";
    lines ~= "    return 0;";
    lines ~= "}";
    writeText(source, lines.join("\n") ~ "\n");

    auto compileExe = runCaptureWithTimeout([ldc2, source, "-O3", "-release", "-boundscheck=off", "-of=" ~ exe], timeoutSec);
    if (compileExe.exitCode != 0)
    {
        return makeTaskResult("zero_cost", "blocked", ["reason": "compile failed", "return_code": to!string(compileExe.exitCode)]);
    }
    auto compileObj = runCaptureWithTimeout([ldc2, source, "-O3", "-release", "-boundscheck=off", "-c", "-of=" ~ obj], timeoutSec);
    if (compileObj.exitCode != 0)
    {
        return makeTaskResult("zero_cost", "blocked", ["reason": "obj compile failed", "return_code": to!string(compileObj.exitCode)]);
    }

    auto rawCsv = buildPath(taskDir, "runtime_raw.csv");
    auto summaryCsv = buildPath(taskDir, "runtime_summary.csv");
    auto advancedCsv = buildPath(taskDir, "runtime_advanced.csv");
    writeText(rawCsv, "mode,run_idx,elapsed_ms,sink\n");
    writeText(summaryCsv, "mode,runs,median_ms,mean_ms,mad_ms,min_ms,max_ms\n");
    writeText(advancedCsv, "mode,run_count,filtered_count,trimmed_mean_ms,p10_ms,p90_ms,outliers\n");

    string[] modes = ["proc", "range"];
    string procSymbol = "";
    string rangeSymbol = "";
    int procInstCount = 0;
    int rangeInstCount = 0;
    int failures = 0;

    foreach (mode; modes)
    {
        foreach (_; 0 .. warmups)
        {
            auto warm = runCaptureWithTimeout([exe, mode, to!string(iterations)], timeoutSec);
            if (warm.exitCode != 0) failures++;
        }

        double[] samples;
        foreach (runIdx; 1 .. runs + 1)
        {
            auto res = runCaptureWithTimeout([exe, mode, to!string(iterations)], timeoutSec);
            if (res.exitCode != 0)
            {
                failures++;
                continue;
            }
            auto sink = res.stdout.strip;
            samples ~= res.elapsedMs;
            append(rawCsv, format("%s,%s,%.3f,%s\n", mode, runIdx, res.elapsedMs, sink));
        }

        if (!samples.length) continue;
        auto filtered = filterOutliers(samples);
        auto trimmed = trimmedMean(samples, 0.1);
        auto sorted = samples.dup;
        sorted.sort;
        append(summaryCsv, format("%s,%s,%.3f,%.3f,%.3f,%.3f,%.3f\n",
            mode, runs, median(samples), mean(samples), mad(samples), sorted[0], sorted[$ - 1]));
        append(advancedCsv, format("%s,%s,%s,%.3f,%.3f,%.3f,%s\n",
            mode, samples.length, filtered.length, trimmed, percentile(sorted, 0.1), percentile(sorted, 0.9), samples.length - filtered.length));
    }

    auto objdumpBin = findExecutable("objdump");
    if (objdumpBin.length)
    {
        auto disasm = safeExecute([objdumpBin, "-d", obj]).output;
        writeText(disasmPath, disasm);

        Tuple!(ulong, string)[] starts;
        int[string] instCount;
        parseObjdumpSymbols(disasm, starts, instCount);
        auto sizeMap = symbolSizesFromStarts(starts);

        foreach (pair; starts)
        {
            if (!procSymbol.length && pair[1].canFind("proceduralSum")) procSymbol = pair[1];
            if (!rangeSymbol.length && pair[1].canFind("rangeSum")) rangeSymbol = pair[1];
        }
        if (procSymbol.length) procInstCount = instCount.get(procSymbol, 0);
        if (rangeSymbol.length) rangeInstCount = instCount.get(rangeSymbol, 0);

        auto asmCsv = buildPath(taskDir, "assembly_summary.csv");
        writeText(asmCsv, "symbol,size_bytes_estimate,instruction_count\n");
        foreach (symbol; [procSymbol, rangeSymbol])
        {
            if (!symbol.length) continue;
            append(asmCsv, format("%s,%s,%s\n", symbol, sizeMap.get(symbol, 0), instCount.get(symbol, 0)));
        }
    }

    double procMedian = 0;
    double rangeMedian = 0;
    if (exists(summaryCsv))
    {
        auto linesSummary = readText(summaryCsv).splitLines();
        foreach (line; linesSummary[1 .. $])
        {
            auto fields = parseCsvLine(line);
            if (fields.length < 3) continue;
            if (fields[0] == "proc") procMedian = to!double(fields[2]);
            if (fields[0] == "range") rangeMedian = to!double(fields[2]);
        }
    }
    auto slowdown = procMedian > 0 ? (rangeMedian / procMedian) : 0.0;

    return makeTaskResult(
        "zero_cost",
        "done",
        [
            "runtime_proc_median_ms": format("%.3f", procMedian),
            "runtime_range_median_ms": format("%.3f", rangeMedian),
            "runtime_ratio_range_over_proc": format("%.3f", slowdown),
            "proc_symbol": procSymbol,
            "range_symbol": rangeSymbol,
            "proc_inst_count": to!string(procInstCount),
            "range_inst_count": to!string(rangeInstCount),
            "failures": to!string(failures)
        ]
    );
}

TaskResult runGCKernels(string outDir, string ldc2, int runs, int warmups, double timeoutSec)
{
    auto taskDir = buildPath(outDir, "gc_kernels");
    mkdirRecurse(taskDir);
    auto source = buildPath(taskDir, "gc_kernels.d");
    auto exe = buildPath(taskDir, "gc_kernels");

    string[] lines;
    lines ~= "module gc_kernels;";
    lines ~= "";
    lines ~= "import core.memory : GC;";
    lines ~= "import core.time : MonoTime;";
    lines ~= "import std.conv : to;";
    lines ~= "import std.stdio : stderr, writeln;";
    lines ~= "";
    lines ~= "int main(string[] args)";
    lines ~= "{";
    lines ~= "    if (args.length != 2)";
    lines ~= "    {";
    lines ~= "        stderr.writeln(\"usage: gc_kernels <small|mixed|large>\");";
    lines ~= "        return 2;";
    lines ~= "    }";
    lines ~= "";
    lines ~= "    string mode = args[1];";
    lines ~= "    size_t sink = 0;";
    lines ~= "    size_t allocations = 0;";
    lines ~= "";
    lines ~= "    switch (mode)";
    lines ~= "    {";
    lines ~= "        case \"small\":";
    lines ~= "            auto keep = new ubyte[][](256);";
    lines ~= "            foreach (i; 0 .. 220_000)";
    lines ~= "            {";
    lines ~= "                auto buf = new ubyte[](64 + (i & 15));";
    lines ~= "                buf[0] = cast(ubyte) i;";
    lines ~= "                buf[$ - 1] = cast(ubyte) (i >> 1);";
    lines ~= "                keep[i % keep.length] = buf;";
    lines ~= "                sink += buf[0] + buf[$ - 1];";
    lines ~= "                allocations++;";
    lines ~= "            }";
    lines ~= "            break;";
    lines ~= "";
    lines ~= "        case \"mixed\":";
    lines ~= "            auto keep = new ubyte[][](512);";
    lines ~= "            foreach (i; 0 .. 160_000)";
    lines ~= "            {";
    lines ~= "                auto buf = new ubyte[](32 + (i % 96));";
    lines ~= "                buf[0] = cast(ubyte) (i * 13);";
    lines ~= "                sink ^= buf[0];";
    lines ~= "                keep[i % keep.length] = buf;";
    lines ~= "                if ((i & 255) == 0)";
    lines ~= "                    sink += keep[(i / 2) % keep.length].length;";
    lines ~= "                allocations++;";
    lines ~= "            }";
    lines ~= "            break;";
    lines ~= "";
    lines ~= "        case \"large\":";
    lines ~= "            auto keep = new ubyte[][](96);";
    lines ~= "            foreach (i; 0 .. 6_000)";
    lines ~= "            {";
    lines ~= "                auto buf = new ubyte[](64 * 1024 + (i % 8) * 4096);";
    lines ~= "                buf[0] = cast(ubyte) i;";
    lines ~= "                keep[i % keep.length] = buf;";
    lines ~= "                sink += keep[i % keep.length][0];";
    lines ~= "                allocations++;";
    lines ~= "            }";
    lines ~= "            break;";
    lines ~= "";
    lines ~= "        default:";
    lines ~= "            stderr.writeln(\"invalid mode: \", mode);";
    lines ~= "            return 3;";
    lines ~= "    }";
    lines ~= "";
    lines ~= "    auto collectStart = MonoTime.currTime;";
    lines ~= "    GC.collect();";
    lines ~= "    auto collectNs = (MonoTime.currTime - collectStart).total!\"nsecs\";";
    lines ~= "    writeln(mode, \",\", allocations, \",\", collectNs, \",\", sink);";
    lines ~= "    return 0;";
    lines ~= "}";
    writeText(source, lines.join("\n") ~ "\n");

    auto compileRes = runCaptureWithTimeout([ldc2, source, "-O3", "-release", "-boundscheck=off", "-of=" ~ exe], timeoutSec);
    writeText(buildPath(taskDir, "compile_stdout.txt"), compileRes.stdout);
    writeText(buildPath(taskDir, "compile_stderr.txt"), compileRes.stderr);
    if (compileRes.exitCode != 0)
    {
        return makeTaskResult("gc_kernels", "blocked", ["reason": "failed to compile gc benchmark", "return_code": to!string(compileRes.exitCode)]);
    }

    auto resultsCsv = buildPath(taskDir, "results.csv");
    auto summaryCsv = buildPath(taskDir, "summary.csv");
    auto advancedCsv = buildPath(taskDir, "summary_advanced.csv");
    writeText(resultsCsv, "mode,run_idx,allocations,collect_ms,wall_ms,sink\n");
    writeText(summaryCsv, "mode,runs,median_wall_ms,mad_wall_ms,median_collect_ms,median_allocations\n");
    writeText(advancedCsv, "mode,run_count,filtered_count,p10_wall_ms,p90_wall_ms,trimmed_wall_ms,outliers\n");

    string[] modes = ["small", "mixed", "large"];
    foreach (mode; modes)
    {
        foreach (_; 0 .. warmups)
        {
            auto warm = runCaptureWithTimeout([exe, mode], timeoutSec);
            if (warm.exitCode != 0) {}
        }

        double[] wallSamples;
        double[] collectSamples;
        int[] allocSamples;
        foreach (runIdx; 1 .. runs + 1)
        {
            auto res = runCaptureWithTimeout([exe, mode], timeoutSec);
            if (res.exitCode != 0) continue;
            auto parts = res.stdout.strip.split(",");
            if (parts.length != 4) continue;
            auto allocations = to!int(parts[1]);
            auto collectMs = to!double(parts[2]) / 1_000_000.0;
            auto sink = parts[3];

            wallSamples ~= res.elapsedMs;
            collectSamples ~= collectMs;
            allocSamples ~= allocations;

            append(resultsCsv, format("%s,%s,%s,%.3f,%.3f,%s\n", mode, runIdx, allocations, collectMs, res.elapsedMs, sink));
        }

        if (!wallSamples.length) continue;
        auto sorted = wallSamples.dup; sorted.sort;
        append(summaryCsv, format("%s,%s,%.3f,%.3f,%.3f,%s\n",
            mode, runs, median(wallSamples), mad(wallSamples), median(collectSamples), cast(int) median(allocSamples.map!(a => cast(double)a).array)));

        auto filtered = filterOutliers(wallSamples);
        append(advancedCsv, format("%s,%s,%s,%.3f,%.3f,%.3f,%s\n",
            mode, wallSamples.length, filtered.length, percentile(sorted, 0.1), percentile(sorted, 0.9), trimmedMean(wallSamples, 0.1), wallSamples.length - filtered.length));
    }

    string[] report;
    report ~= "# D runtime GC kernels";
    report ~= "";
    report ~= "Compiler flags: `-O3 -release -boundscheck=off`";
    report ~= "";
    report ~= "Kernels:";
    report ~= "- `small`: short-lived small allocations";
    report ~= "- `mixed`: mixed churn with a persistent live set";
    report ~= "- `large`: larger array churn to stress collection cost";
    report ~= "";
    report ~= "| Mode | Median allocations | Median collect ms | Median wall ms |";
    report ~= "|---|---:|---:|---:|";
    if (exists(summaryCsv))
    {
        auto linesSum = readText(summaryCsv).splitLines();
        foreach (line; linesSum[1 .. $])
        {
            auto fields = parseCsvLine(line);
            if (fields.length < 6) continue;
            report ~= format("| %s | %s | %s | %s |", fields[0], fields[5], fields[4], fields[2]);
        }
    }
    writeText(buildPath(taskDir, "report.md"), report.join("\n") ~ "\n");

    return makeTaskResult("gc_kernels", "done", ["modes": "small,mixed,large", "runs": to!string(runs)]);
}

TaskResult runAAKernels(string outDir, string ldc2, int runs, int warmups, double timeoutSec)
{
    auto taskDir = buildPath(outDir, "aa_kernels");
    mkdirRecurse(taskDir);
    auto source = buildPath(taskDir, "aa_kernels.d");
    auto exe = buildPath(taskDir, "aa_kernels");

    string[] lines;
    lines ~= "module aa_kernels;";
    lines ~= "";
    lines ~= "import std.conv : to;";
    lines ~= "import std.format : format;";
    lines ~= "import std.stdio : stderr, writeln;";
    lines ~= "";
    lines ~= "string makeKey(size_t i)";
    lines ~= "{";
    lines ~= "    return format!\"key_%08x\"(cast(uint) (i * 2_654_435_761U));";
    lines ~= "}";
    lines ~= "";
    lines ~= "int main(string[] args)";
    lines ~= "{";
    lines ~= "    if (args.length != 4)";
    lines ~= "    {";
    lines ~= "        stderr.writeln(\"usage: aa_kernels <int|string> <insert|hit_lookup|miss_lookup|iterate|delete_reinsert> <scale>\");";
    lines ~= "        return 2;";
    lines ~= "    }";
    lines ~= "";
    lines ~= "    string keyType = args[1];";
    lines ~= "    string workload = args[2];";
    lines ~= "    size_t scale = args[3].to!size_t;";
    lines ~= "    ulong sink = 0;";
    lines ~= "    size_t ops = 0;";
    lines ~= "";
    lines ~= "    if (keyType == \"int\")";
    lines ~= "    {";
    lines ~= "        int[int] table;";
    lines ~= "        foreach (i; 0 .. scale)";
    lines ~= "            table[cast(int) i] = cast(int) (i * 7 + 3);";
    lines ~= "";
    lines ~= "        switch (workload)";
    lines ~= "        {";
    lines ~= "            case \"insert\":";
    lines ~= "                table = int[int].init;";
    lines ~= "                foreach (i; 0 .. scale)";
    lines ~= "                {";
    lines ~= "                    table[cast(int) i] = cast(int) (i * 7 + 3);";
    lines ~= "                    sink += table[cast(int) i];";
    lines ~= "                    ops++;";
    lines ~= "                }";
    lines ~= "                break;";
    lines ~= "";
    lines ~= "            case \"hit_lookup\":";
    lines ~= "                foreach (_; 0 .. 5)";
    lines ~= "                foreach (i; 0 .. scale)";
    lines ~= "                {";
    lines ~= "                    sink += cast(uint) table[cast(int) i];";
    lines ~= "                    ops++;";
    lines ~= "                }";
    lines ~= "                break;";
    lines ~= "";
    lines ~= "            case \"miss_lookup\":";
    lines ~= "                foreach (_; 0 .. 5)";
    lines ~= "                foreach (i; 0 .. scale)";
    lines ~= "                {";
    lines ~= "                    sink += (cast(int) (i + scale) in table) is null ? 1 : 0;";
    lines ~= "                    ops++;";
    lines ~= "                }";
    lines ~= "                break;";
    lines ~= "";
    lines ~= "            case \"iterate\":";
    lines ~= "                foreach (_; 0 .. 4)";
    lines ~= "                foreach (k, v; table)";
    lines ~= "                {";
    lines ~= "                    sink += cast(uint) (k ^ v);";
    lines ~= "                    ops++;";
    lines ~= "                }";
    lines ~= "                break;";
    lines ~= "";
    lines ~= "            case \"delete_reinsert\":";
    lines ~= "                foreach (i; 0 .. scale)";
    lines ~= "                {";
    lines ~= "                    table.remove(cast(int) i);";
    lines ~= "                    ops++;";
    lines ~= "                }";
    lines ~= "                foreach (i; 0 .. scale)";
    lines ~= "                {";
    lines ~= "                    table[cast(int) i] = cast(int) (i * 11 + 5);";
    lines ~= "                    sink += cast(uint) table[cast(int) i];";
    lines ~= "                    ops++;";
    lines ~= "                }";
    lines ~= "                break;";
    lines ~= "";
    lines ~= "            default:";
    lines ~= "                stderr.writeln(\"invalid workload: \", workload);";
    lines ~= "                return 3;";
    lines ~= "        }";
    lines ~= "    }";
    lines ~= "    else if (keyType == \"string\")";
    lines ~= "    {";
    lines ~= "        string[string] table;";
    lines ~= "        auto keys = new string[](scale);";
    lines ~= "        foreach (i; 0 .. scale)";
    lines ~= "        {";
    lines ~= "            keys[i] = makeKey(i);";
    lines ~= "            table[keys[i]] = keys[i];";
    lines ~= "        }";
    lines ~= "";
    lines ~= "        switch (workload)";
    lines ~= "        {";
    lines ~= "            case \"insert\":";
    lines ~= "                table = string[string].init;";
    lines ~= "                foreach (i; 0 .. scale)";
    lines ~= "                {";
    lines ~= "                    auto key = makeKey(i);";
    lines ~= "                    table[key] = key;";
    lines ~= "                    sink += table[key].length;";
    lines ~= "                    ops++;";
    lines ~= "                }";
    lines ~= "                break;";
    lines ~= "";
    lines ~= "            case \"hit_lookup\":";
    lines ~= "                foreach (_; 0 .. 5)";
    lines ~= "                foreach (key; keys)";
    lines ~= "                {";
    lines ~= "                    sink += table[key].length;";
    lines ~= "                    ops++;";
    lines ~= "                }";
    lines ~= "                break;";
    lines ~= "";
    lines ~= "            case \"miss_lookup\":";
    lines ~= "                foreach (_; 0 .. 5)";
    lines ~= "                foreach (i; 0 .. scale)";
    lines ~= "                {";
    lines ~= "                    auto key = makeKey(i + scale);";
    lines ~= "                    sink += (key in table) is null ? 1 : 0;";
    lines ~= "                    ops++;";
    lines ~= "                }";
    lines ~= "                break;";
    lines ~= "";
    lines ~= "            case \"iterate\":";
    lines ~= "                foreach (_; 0 .. 4)";
    lines ~= "                foreach (k, v; table)";
    lines ~= "                {";
    lines ~= "                    sink += k.length + v.length;";
    lines ~= "                    ops++;";
    lines ~= "                }";
    lines ~= "                break;";
    lines ~= "";
    lines ~= "            case \"delete_reinsert\":";
    lines ~= "                foreach (key; keys)";
    lines ~= "                {";
    lines ~= "                    table.remove(key);";
    lines ~= "                    ops++;";
    lines ~= "                }";
    lines ~= "                foreach (key; keys)";
    lines ~= "                {";
    lines ~= "                    table[key] = key;";
    lines ~= "                    sink += table[key].length;";
    lines ~= "                    ops++;";
    lines ~= "                }";
    lines ~= "                break;";
    lines ~= "";
    lines ~= "            default:";
    lines ~= "                stderr.writeln(\"invalid workload: \", workload);";
    lines ~= "                return 3;";
    lines ~= "        }";
    lines ~= "    }";
    lines ~= "    else";
    lines ~= "    {";
    lines ~= "        stderr.writeln(\"invalid keyType: \", keyType);";
    lines ~= "        return 4;";
    lines ~= "    }";
    lines ~= "";
    lines ~= "    writeln(keyType, \",\", workload, \",\", scale, \",\", ops, \",\", sink);";
    lines ~= "    return 0;";
    lines ~= "}";
    writeText(source, lines.join("\n") ~ "\n");

    auto compileRes = runCaptureWithTimeout([ldc2, source, "-O3", "-release", "-boundscheck=off", "-of=" ~ exe], timeoutSec);
    writeText(buildPath(taskDir, "compile_stdout.txt"), compileRes.stdout);
    writeText(buildPath(taskDir, "compile_stderr.txt"), compileRes.stderr);
    if (compileRes.exitCode != 0)
    {
        return makeTaskResult("aa_kernels", "blocked", ["reason": "failed to compile aa benchmark", "return_code": to!string(compileRes.exitCode)]);
    }

    auto resultsCsv = buildPath(taskDir, "results.csv");
    auto summaryCsv = buildPath(taskDir, "summary.csv");
    auto advancedCsv = buildPath(taskDir, "summary_advanced.csv");
    writeText(resultsCsv, "key_type,workload,scale,run_idx,ops,wall_ms,ns_per_op,sink\n");
    writeText(summaryCsv, "key_type,workload,scale,runs,median_ops,median_wall_ms,median_ns_per_op\n");
    writeText(advancedCsv, "key_type,workload,scale,run_count,filtered_count,p10_ns_per_op,p90_ns_per_op,trimmed_ns_per_op,outliers\n");

    string[] keyTypes = ["int", "string"];
    string[] workloads = ["insert", "hit_lookup", "miss_lookup", "iterate", "delete_reinsert"];
    int[] scales = [1000, 10_000, 100_000];

    foreach (keyType; keyTypes)
    foreach (workload; workloads)
    foreach (scale; scales)
    {
        foreach (_; 0 .. warmups)
        {
            runCaptureWithTimeout([exe, keyType, workload, to!string(scale)], timeoutSec);
        }

        double[] wallSamples;
        double[] nsSamples;
        int[] opsSamples;
        foreach (runIdx; 1 .. runs + 1)
        {
            auto res = runCaptureWithTimeout([exe, keyType, workload, to!string(scale)], timeoutSec);
            if (res.exitCode != 0) continue;
            auto parts = res.stdout.strip.split(",");
            if (parts.length != 5) continue;
            auto ops = to!int(parts[3]);
            auto nsPerOp = ops > 0 ? (res.elapsedMs * 1_000_000.0 / ops) : double.nan;

            wallSamples ~= res.elapsedMs;
            nsSamples ~= nsPerOp;
            opsSamples ~= ops;

            append(resultsCsv, format("%s,%s,%s,%s,%s,%.3f,%.3f,%s\n",
                keyType, workload, scale, runIdx, ops, res.elapsedMs, nsPerOp, parts[4]));
        }

        if (!wallSamples.length) continue;
        append(summaryCsv, format("%s,%s,%s,%s,%s,%.3f,%.3f\n",
            keyType, workload, scale, runs, cast(int) median(opsSamples.map!(a => cast(double)a).array), median(wallSamples), median(nsSamples)));

        auto sorted = nsSamples.dup; sorted.sort;
        auto filtered = filterOutliers(nsSamples);
        append(advancedCsv, format("%s,%s,%s,%s,%s,%.3f,%.3f,%.3f,%s\n",
            keyType, workload, scale, nsSamples.length, filtered.length, percentile(sorted, 0.1), percentile(sorted, 0.9), trimmedMean(nsSamples, 0.1), nsSamples.length - filtered.length));
    }

    string[] report;
    report ~= "# D associative-array kernels";
    report ~= "";
    report ~= "Compiler flags: `-O3 -release -boundscheck=off`";
    report ~= "";
    report ~= "| Key type | Workload | Scale | Median ns/op | Median wall ms |";
    report ~= "|---|---|---:|---:|---:|";
    if (exists(summaryCsv))
    {
        auto linesSum = readText(summaryCsv).splitLines();
        foreach (line; linesSum[1 .. $])
        {
            auto fields = parseCsvLine(line);
            if (fields.length < 7) continue;
            if (fields[2] == "100000")
                report ~= format("| %s | %s | %s | %s | %s |", fields[0], fields[1], fields[2], fields[6], fields[5]);
        }
    }
    writeText(buildPath(taskDir, "report.md"), report.join("\n") ~ "\n");

    return makeTaskResult("aa_kernels", "done", ["key_types": "int,string", "workloads": "insert,hit_lookup,miss_lookup,iterate,delete_reinsert", "scales": "1000,10000,100000"]);
}

TaskResult runLinkerStrip(string outDir, string ldc2, int payloadLen, double timeoutSec)
{
    auto taskDir = buildPath(outDir, "linker_strip_unused_data");
    mkdirRecurse(taskDir);

    auto stringsBin = findExecutable("strings");
    if (!stringsBin.length)
    {
        return makeTaskResult("linker_strip", "blocked", ["reason": "strings not available"]);
    }

    string markerToken = "UNUSED_PAYLOAD_MARKER_35A2A4D9";
    auto payloadPath = buildPath(taskDir, "payload_unused.d");
    buildLinkerStripPayload(payloadPath, markerToken, payloadLen);

    auto mainBaseline = buildPath(taskDir, "main_baseline.d");
    auto mainImportOnly = buildPath(taskDir, "main_import_only.d");
    auto mainTouchPayload = buildPath(taskDir, "main_touch_payload.d");

    writeText(mainBaseline, "module main_baseline;\nimport std.stdio : writeln;\nvoid main() { writeln(\"ok\"); }\n");
    writeText(mainImportOnly, "module main_import_only;\nimport payload_unused;\nimport std.stdio : writeln;\nvoid main() { writeln(\"ok\"); }\n");
    writeText(mainTouchPayload, "module main_touch_payload;\nimport payload_unused : payloadMarkerLength;\nimport std.stdio : writeln;\nvoid main() { writeln(payloadMarkerLength()); }\n");

    struct Scenario
    {
        string name;
        string mainFile;
        bool deadStrip;
        bool includePayload;
    }
    Scenario[] scenarios = [
        Scenario("baseline", mainBaseline, false, false),
        Scenario("baseline", mainBaseline, true, false),
        Scenario("import_only", mainImportOnly, false, true),
        Scenario("import_only", mainImportOnly, true, true),
        Scenario("touch_payload", mainTouchPayload, false, true),
        Scenario("touch_payload", mainTouchPayload, true, true)
    ];

    auto resultsCsv = buildPath(taskDir, "results.csv");
    writeText(resultsCsv, "scenario,dead_strip,compile_ok,exe_size_bytes,marker_present_in_binary,compile_stderr_tail,run_stdout,run_stderr\n");

    string deadStripArg = "";
    version (OSX) deadStripArg = "-L=-Wl,-dead_strip";
    version (Linux) deadStripArg = "-L=-Wl,--gc-sections";

    size_t[] baselineSizes;
    size_t[] importSizes;

    foreach (scenario; scenarios)
    {
        string suffix = scenario.deadStrip ? "deadstrip" : "nodeadstrip";
        auto exe = buildPath(taskDir, scenario.name ~ "_" ~ suffix);
        string[] cmd = [ldc2, scenario.mainFile, "-O3", "-release", "-boundscheck=off", "-of=" ~ exe];
        if (scenario.includePayload) cmd ~= payloadPath;
        if (scenario.deadStrip && deadStripArg.length) cmd ~= deadStripArg;

        auto cp = runCaptureWithTimeout(cmd, timeoutSec);
        bool markerFound = false;
        string runStdout = "";
        string runStderr = "";

        if (cp.exitCode == 0 && exists(exe))
        {
            auto stringsOut = safeExecute([stringsBin, "-a", exe]).output;
            markerFound = stringsOut.canFind(markerToken);
            auto runRes = runCaptureWithTimeout([exe], timeoutSec);
            runStdout = runRes.stdout.strip.replace("\n", " ");
            runStderr = runRes.stderr.strip.replace("\n", " ");
        }

        auto sizeVal = exists(exe) ? getSize(exe) : 0;
        auto errLines = cp.stderr.strip.splitLines();
        auto errTail = errLines.length ? errLines[$ - 1] : "";
        auto errTailTrimmed = errTail.length ? errTail[0 .. min(cast(int) errTail.length, 200)] : "";
        append(resultsCsv, format("%s,%s,%s,%s,%s,%s,%s,%s\n",
            scenario.name,
            scenario.deadStrip ? 1 : 0,
            cp.exitCode == 0 ? 1 : 0,
            sizeVal ? to!string(sizeVal) : "",
            markerFound ? 1 : 0,
            errTailTrimmed,
            runStdout.length ? runStdout[0 .. min(cast(int) runStdout.length, 160)] : "",
            runStderr.length ? runStderr[0 .. min(cast(int) runStderr.length, 160)] : ""
        ));

        if (scenario.name == "baseline" && cp.exitCode == 0) baselineSizes ~= sizeVal;
        if (scenario.name == "import_only" && cp.exitCode == 0) importSizes ~= sizeVal;
    }

    auto baselineMin = baselineSizes.length ? baselineSizes.minElement : 0;
    auto importMin = importSizes.length ? importSizes.minElement : 0;

    return makeTaskResult(
        "linker_strip",
        "done",
        [
            "rows": to!string(scenarios.length),
            "baseline_exe_size_min": to!string(baselineMin),
            "import_only_exe_size_min": to!string(importMin)
        ]
    );
}

TaskResult runFloatToString(string outDir, string ldc2, int runs, int warmups, double timeoutSec)
{
    auto taskDir = buildPath(outDir, "float_to_string_kernels");
    mkdirRecurse(taskDir);

    auto source = buildPath(taskDir, "float_to_string_kernels.d");
    auto exe = buildPath(taskDir, "float_to_string_kernels");

    string[] lines;
    lines ~= "module float_to_string_kernels;";
    lines ~= "";
    lines ~= "import std.array : appender;";
    lines ~= "import std.conv : to;";
    lines ~= "import std.math : cos, sin;";
    lines ~= "import std.stdio : stderr, writeln;";
    lines ~= "";
    lines ~= "double[] buildDataset(string dataset)";
    lines ~= "{";
    lines ~= "    auto result = appender!(double[])();";
    lines ~= "    switch (dataset)";
    lines ~= "    {";
    lines ~= "        case \"normal\":";
    lines ~= "            foreach (i; 0 .. 4096)";
    lines ~= "                result.put(cast(double) i * 0.25 + sin(cast(double) i / 31.0));";
    lines ~= "            break;";
    lines ~= "";
    lines ~= "        case \"scientific\":";
    lines ~= "            foreach (i; 0 .. 4096)";
    lines ~= "            {";
    lines ~= "                auto mag = cast(double) ((i % 40) - 20);";
    lines ~= "                result.put((sin(cast(double) i / 9.0) + 1.5) * 10.0 ^^ mag);";
    lines ~= "            }";
    lines ~= "            break;";
    lines ~= "";
    lines ~= "        case \"special\":";
    lines ~= "            double[] base = [";
    lines ~= "                0.0,";
    lines ~= "                -0.0,";
    lines ~= "                double.min_normal / 2.0,";
    lines ~= "                double.min_normal,";
    lines ~= "                double.max / 2.0,";
    lines ~= "                double.infinity,";
    lines ~= "                -double.infinity,";
    lines ~= "                double.nan,";
    lines ~= "                sin(1.0),";
    lines ~= "                cos(1.0),";
    lines ~= "            ];";
    lines ~= "            foreach (_; 0 .. 512)";
    lines ~= "                foreach (v; base)";
    lines ~= "                    result.put(v);";
    lines ~= "            break;";
    lines ~= "";
    lines ~= "        default:";
    lines ~= "            assert(0, \"unknown dataset\");";
    lines ~= "    }";
    lines ~= "    return result.data;";
    lines ~= "}";
    lines ~= "";
    lines ~= "int main(string[] args)";
    lines ~= "{";
    lines ~= "    if (args.length != 3)";
    lines ~= "    {";
    lines ~= "        stderr.writeln(\"usage: float_to_string_kernels <normal|scientific|special> <outer_loops>\");";
    lines ~= "        return 2;";
    lines ~= "    }";
    lines ~= "";
    lines ~= "    string dataset = args[1];";
    lines ~= "    size_t outerLoops = args[2].to!size_t;";
    lines ~= "    auto values = buildDataset(dataset);";
    lines ~= "    ulong sink = 0;";
    lines ~= "    size_t ops = 0;";
    lines ~= "    size_t totalChars = 0;";
    lines ~= "";
    lines ~= "    foreach (_; 0 .. outerLoops)";
    lines ~= "    {";
    lines ~= "        foreach (v; values)";
    lines ~= "        {";
    lines ~= "            auto s = v.to!string;";
    lines ~= "            totalChars += s.length;";
    lines ~= "            sink = (sink * 1_099_511_628_211UL) ^ cast(ulong) s.length;";
    lines ~= "            ops++;";
    lines ~= "        }";
    lines ~= "    }";
    lines ~= "";
    lines ~= "    writeln(dataset, \",\", ops, \",\", totalChars, \",\", sink);";
    lines ~= "    return 0;";
    lines ~= "}";
    writeText(source, lines.join("\n") ~ "\n");

    auto compileRes = runCaptureWithTimeout([ldc2, source, "-O3", "-release", "-boundscheck=off", "-of=" ~ exe], timeoutSec);
    writeText(buildPath(taskDir, "compile_stdout.txt"), compileRes.stdout);
    writeText(buildPath(taskDir, "compile_stderr.txt"), compileRes.stderr);
    if (compileRes.exitCode != 0)
    {
        return makeTaskResult("float_to_string_kernels", "blocked", ["reason": "failed to compile float benchmark", "return_code": to!string(compileRes.exitCode)]);
    }

    auto resultsCsv = buildPath(taskDir, "results.csv");
    auto summaryCsv = buildPath(taskDir, "summary.csv");
    auto advancedCsv = buildPath(taskDir, "summary_advanced.csv");
    writeText(resultsCsv, "dataset,run_idx,ops,total_chars,wall_ms,conversions_per_sec,sink\n");
    writeText(summaryCsv, "dataset,runs,median_ops,median_wall_ms,median_conversions_per_sec\n");
    writeText(advancedCsv, "dataset,run_count,filtered_count,p10_wall_ms,p90_wall_ms,trimmed_wall_ms,p10_cps,p90_cps,trimmed_cps,outliers\n");

    string[string] datasets = ["normal": "128", "scientific": "128", "special": "256"];
    foreach (dataset, outerLoops; datasets)
    {
        foreach (_; 0 .. warmups)
        {
            runCaptureWithTimeout([exe, dataset, outerLoops], timeoutSec);
        }

        double[] wallSamples;
        double[] cpsSamples;
        int[] opsSamples;
        foreach (runIdx; 1 .. runs + 1)
        {
            auto res = runCaptureWithTimeout([exe, dataset, outerLoops], timeoutSec);
            if (res.exitCode != 0) continue;
            auto parts = res.stdout.strip.split(",");
            if (parts.length != 4) continue;
            auto ops = to!int(parts[1]);
            auto totalChars = parts[2];
            auto cps = res.elapsedMs > 0 ? ops / (res.elapsedMs / 1000.0) : double.nan;
            wallSamples ~= res.elapsedMs;
            cpsSamples ~= cps;
            opsSamples ~= ops;
            append(resultsCsv, format("%s,%s,%s,%s,%.3f,%.1f,%s\n", dataset, runIdx, ops, totalChars, res.elapsedMs, cps, parts[3]));
        }

        if (!wallSamples.length) continue;
        append(summaryCsv, format("%s,%s,%s,%.3f,%.1f\n", dataset, runs, cast(int) median(opsSamples.map!(a => cast(double)a).array), median(wallSamples), median(cpsSamples)));

        auto sortedWall = wallSamples.dup; sortedWall.sort;
        auto sortedCps = cpsSamples.dup; sortedCps.sort;
        auto filtered = filterOutliers(wallSamples);
        append(advancedCsv, format("%s,%s,%s,%.3f,%.3f,%.3f,%.1f,%.1f,%.1f,%s\n",
            dataset, wallSamples.length, filtered.length,
            percentile(sortedWall, 0.1), percentile(sortedWall, 0.9), trimmedMean(wallSamples, 0.1),
            percentile(sortedCps, 0.1), percentile(sortedCps, 0.9), trimmedMean(cpsSamples, 0.1),
            wallSamples.length - filtered.length));
    }

    string[] report;
    report ~= "# D float-to-string kernels";
    report ~= "";
    report ~= "## Benchmark topology";
    report ~= "";
    appendMermaid(report, [
        "flowchart TD",
        "    A[\"datasets: normal | scientific | special\"] --> B[\"compiled benchmark binary\"]",
        "    B --> C[\"measured runs\"]",
        "    C --> D[\"results.csv\"]",
        "    D --> E[\"summary.csv\"]",
        "    E --> F[\"report.md\"]"
    ]);
    report ~= "";
    report ~= "Compiler flags: `-O3 -release -boundscheck=off`";
    report ~= "";
    report ~= "| Dataset | Median ops | Median wall ms | Median conversions/sec |";
    report ~= "|---|---:|---:|---:|";
    if (exists(summaryCsv))
    {
        auto linesSum = readText(summaryCsv).splitLines();
        foreach (line; linesSum[1 .. $])
        {
            auto fields = parseCsvLine(line);
            if (fields.length < 5) continue;
            report ~= format("| %s | %s | %s | %s |", fields[0], fields[2], fields[3], fields[4]);
        }
    }
    writeText(buildPath(taskDir, "report.md"), report.join("\n") ~ "\n");

    return makeTaskResult("float_to_string_kernels", "done", ["datasets": "normal,scientific,special", "runs": to!string(runs)]);
}

TaskResult runPhobosSections(string outDir, string archivePath)
{
    auto taskDir = buildPath(outDir, "libphobos_sections");
    mkdirRecurse(taskDir);

    if (!exists(archivePath))
    {
        return makeTaskResult("phobos_sections", "blocked", ["reason": "archive missing", "archive": archivePath]);
    }
    auto objdumpBin = findExecutable("objdump");
    if (!objdumpBin.length)
    {
        return makeTaskResult("phobos_sections", "blocked", ["reason": "objdump not available"]);
    }

    auto objdumpOutput = safeExecute([objdumpBin, "-h", archivePath]).output;
    writeText(buildPath(taskDir, "objdump_sections.txt"), objdumpOutput);

    auto memberRe = regex("^\\s*.+\\(([^()]+)\\):\\s+file format");
    auto sectionRe = regex("^\\s*\\d+\\s+(\\S+)\\s+([0-9a-fA-F]+)\\s+[0-9a-fA-F]+\\s+(\\S+)");

    string currentMember = "";
    ulong[string] memberTotals;
    ulong[string] sectionTotals;

    auto memberCsv = buildPath(taskDir, "member_section_sizes.csv");
    writeText(memberCsv, "member,section,size_bytes,section_type\n");

    foreach (line; objdumpOutput.splitLines())
    {
        auto m = matchFirst(line, memberRe);
        if (!m.empty)
        {
            currentMember = m.captures[1];
            continue;
        }
        auto s = matchFirst(line, sectionRe);
        if (s.empty || !currentMember.length) continue;
        auto sectionName = s.captures[1];
        auto sizeBytes = to!ulong("0x" ~ s.captures[2]);
        auto sectionType = s.captures[3];
        appendRow(memberCsv, [currentMember, sectionName, to!string(sizeBytes), sectionType]);
        memberTotals[currentMember] = memberTotals.get(currentMember, 0) + sizeBytes;
        sectionTotals[sectionName] = sectionTotals.get(sectionName, 0) + sizeBytes;
    }

    auto memberTotalsCsv = buildPath(taskDir, "member_totals.csv");
    auto sectionTotalsCsv = buildPath(taskDir, "section_totals.csv");
    writeText(memberTotalsCsv, "member,total_bytes\n");
    writeText(sectionTotalsCsv, "section,total_bytes\n");

    auto memberPairs = memberTotals.keys.array.map!(k => tuple(k, memberTotals[k])).array;
    memberPairs.sort!((a, b) => a[1] > b[1]);
    foreach (pair; memberPairs)
    {
        appendRow(memberTotalsCsv, [pair[0], to!string(pair[1])]);
    }

    auto sectionPairs = sectionTotals.keys.array.map!(k => tuple(k, sectionTotals[k])).array;
    sectionPairs.sort!((a, b) => a[1] > b[1]);
    foreach (pair; sectionPairs)
    {
        appendRow(sectionTotalsCsv, [pair[0], to!string(pair[1])]);
    }

    string[] report;
    report ~= "# libphobos2.a section analysis";
    report ~= "";
    report ~= format("Archive: `%s`", archivePath);
    report ~= "";
    report ~= "## Analysis topology";
    report ~= "";
    appendMermaid(report, [
        "flowchart TD",
        "    A[\"libphobos2.a\"] --> B[\"objdump -h\"]",
        "    B --> C[\"member_section_sizes.csv\"]",
        "    C --> D[\"member_totals.csv\"]",
        "    C --> E[\"section_totals.csv\"]",
        "    D --> F[\"report.md\"]",
        "    E --> F"
    ]);
    report ~= "";
    report ~= "## Top members by total section bytes";
    report ~= "";
    report ~= "| Member | Total bytes |";
    report ~= "|---|---:|";
    foreach (pair; memberPairs[0 .. min(memberPairs.length, 15)])
    {
        report ~= format("| %s | %s |", pair[0], pair[1]);
    }
    report ~= "";
    report ~= "## Top section names by aggregate bytes";
    report ~= "";
    report ~= "| Section | Total bytes |";
    report ~= "|---|---:|";
    foreach (pair; sectionPairs[0 .. min(sectionPairs.length, 15)])
    {
        report ~= format("| %s | %s |", pair[0], pair[1]);
    }
    writeText(buildPath(taskDir, "report.md"), report.join("\n") ~ "\n");

    auto topMember = memberPairs.length ? memberPairs[0][0] : "";
    auto topBytes = memberPairs.length ? memberPairs[0][1] : 0;
    return makeTaskResult("phobos_sections", "done", ["archive": archivePath, "member_count": to!string(memberPairs.length), "top_member": topMember, "top_member_bytes": to!string(topBytes)]);
}

void buildLinkerStripPayload(string payloadPath, string markerToken, int payloadLen)
{
    auto filler = repeat('X', payloadLen).array;
    auto literal = markerToken ~ cast(string) filler ~ "_PAYLOAD_END";
    auto escaped = literal.replace("\\", "\\\\").replace("\"", "\\\"");
    string code =
        "module payload_unused;\n\n"
        ~ format("enum string PAYLOAD_MARKER = \"%s\";\n", escaped)
        ~ "immutable(char)[] LARGE_TEXT = PAYLOAD_MARKER;\n"
        ~ "__gshared ubyte[8_000_000] LARGE_BSS;\n\n"
        ~ "extern(C) size_t payloadMarkerLength() @nogc nothrow\n"
        ~ "{\n"
        ~ "    return LARGE_TEXT.length + LARGE_BSS.length;\n"
        ~ "}\n";
    writeText(payloadPath, code);
}

void parseObjdumpSymbols(string disasm, out Tuple!(ulong, string)[] starts, out int[string] instCount)
{
    starts = [];
    instCount = null;
    string currentSymbol = "";
    foreach (line; disasm.splitLines())
    {
        auto stripped = line.strip;
        auto match = matchFirst(stripped, regex("^([0-9A-Fa-f]+) <([^>]+)>:"));
        if (!match.empty)
        {
            auto addr = to!ulong(match.captures[1], 16);
            currentSymbol = match.captures[2];
            starts ~= tuple(addr, currentSymbol);
            continue;
        }
        auto instMatch = matchFirst(stripped, regex("^([0-9A-Fa-f]+):"));
        if (!instMatch.empty && currentSymbol.length)
        {
            instCount[currentSymbol] = instCount.get(currentSymbol, 0) + 1;
        }
    }
}

ulong[string] symbolSizesFromStarts(Tuple!(ulong, string)[] starts)
{
    ulong[string] sizes;
    if (!starts.length) return sizes;
    auto sorted = starts.dup;
    sorted.sort!((a, b) => a[0] < b[0]);
    foreach (i; 0 .. sorted.length)
    {
        auto addr = sorted[i][0];
        auto name = sorted[i][1];
        ulong size = 0;
        if (i + 1 < sorted.length)
        {
            size = sorted[i + 1][0] - addr;
        }
        sizes[name] = size;
    }
    return sizes;
}

double[] filterOutliers(double[] values)
{
    if (values.length < 3) return values;
    auto med = median(values);
    auto madVal = mad(values);
    if (madVal == 0) return values;
    double threshold = madVal * 4.5;
    double[] filtered;
    foreach (v; values)
    {
        if (fabs(v - med) <= threshold) filtered ~= v;
    }
    return filtered.length ? filtered : values;
}

double trimmedMean(double[] values, double trimFraction)
{
    if (!values.length) return 0.0;
    auto sorted = values.dup;
    sorted.sort;
    auto trim = cast(int) (sorted.length * trimFraction);
    if (trim * 2 >= sorted.length) return mean(sorted);
    auto slice = sorted[trim .. $ - trim];
    return mean(slice);
}

struct TimedCapture
{
    int exitCode;
    string stdout;
    string stderr;
    double elapsedMs;
    bool timedOut;
}

string readAll(File file)
{
    auto buffer = appender!string();
    ubyte[4096] chunk;
    while (true)
    {
        auto data = file.rawRead(chunk[]);
        if (data.length == 0) break;
        buffer.put(cast(string) data);
    }
    return buffer.data;
}

TimedCapture runCaptureWithTimeout(string[] cmd, double timeoutSec)
{
    auto sw = StopWatch(AutoStart.yes);
    auto pipes = pipeProcess(cmd, Redirect.stdout | Redirect.stderr);
    shared bool done = false;
    shared int exitCode = -1;
    string outText = "";
    string errText = "";

    auto outThread = new Thread({
        try outText = readAll(pipes.stdout);
        catch (Exception) outText = "";
    });
    auto errThread = new Thread({
        try errText = readAll(pipes.stderr);
        catch (Exception) errText = "";
    });
    auto waitThread = new Thread({
        try exitCode = wait(pipes.pid);
        catch (Exception) exitCode = -1;
        done = true;
    });
    outThread.start();
    errThread.start();
    waitThread.start();

    auto start = MonoTime.currTime;
    bool timedOut = false;
    while (!done)
    {
        if ((MonoTime.currTime - start).total!"seconds" > timeoutSec)
        {
            terminateProcess(pipes.pid);
            exitCode = 124;
            done = true;
            timedOut = true;
            break;
        }
        Thread.sleep(dur!"msecs"(25));
    }

    waitThread.join();
    outThread.join();
    errThread.join();
    sw.stop();

    TimedCapture res;
    res.exitCode = exitCode;
    res.stdout = outText;
    res.stderr = errText;
    res.elapsedMs = sw.peek.total!"msecs";
    res.timedOut = timedOut;
    return res;
}


struct TimedResult
{
    int exitCode;
    double elapsedMs;
    bool timedOut;
}

TimedResult runProcessWithTimeout(string[] cmd, double timeoutSec)
{
    auto sw = StopWatch(AutoStart.yes);
    auto proc = spawnProcess(cmd);
    shared bool done = false;
    shared int exitCode = -1;

    auto t = new Thread({
        try exitCode = proc.wait();
        catch (Exception) exitCode = -1;
        done = true;
    });
    t.start();

    auto start = MonoTime.currTime;
    bool timedOut = false;
    while (!done)
    {
        if ((MonoTime.currTime - start).total!"seconds" > timeoutSec)
        {
            terminateProcess(proc);
            exitCode = 124;
            done = true;
            timedOut = true;
            break;
        }
        Thread.sleep(dur!"msecs"(25));
    }
    t.join();
    sw.stop();

    return TimedResult(exitCode, sw.peek.total!"msecs", timedOut);
}

string mutateText(string seedText, Random rng)
{
    string text = seedText;
    auto edits = uniform(1, 5, rng);
    foreach (_; 0 .. edits)
    {
        if (!text.length)
        {
            text = "int main(){return 0;}\n";
        }
        auto op = FUZZ_OPS[uniform(0, cast(int) FUZZ_OPS.length, rng)];
        if (op == "insert")
        {
            auto at = uniform(0, cast(int) text.length + 1, rng);
            auto token = FUZZ_TOKENS[uniform(0, cast(int) FUZZ_TOKENS.length, rng)];
            text = text[0 .. at] ~ token ~ text[at .. $];
        }
        else if (op == "delete" && text.length > 8)
        {
            auto i = uniform(0, cast(int) text.length - 1, rng);
            auto j = min(cast(int) text.length, i + uniform(1, min(80, cast(int) text.length - i), rng));
            text = text[0 .. i] ~ text[j .. $];
        }
        else if (op == "flip")
        {
            auto i = uniform(0, cast(int) text.length, rng);
            auto repl = FUZZ_CHARS[uniform(0, cast(int) FUZZ_CHARS.length, rng)];
            text = text[0 .. i] ~ repl ~ text[i + 1 .. $];
        }
        else if (op == "duplicate" && text.length > 16)
        {
            auto i = uniform(0, cast(int) text.length - 1, rng);
            auto j = min(cast(int) text.length, i + uniform(1, min(40, cast(int) text.length - i), rng));
            auto at = uniform(0, cast(int) text.length + 1, rng);
            text = text[0 .. at] ~ text[i .. j] ~ text[at .. $];
        }
    }
    return text;
}

immutable string[] FUZZ_TOKENS = [
    "if",
    "else",
    "for",
    "while",
    "template",
    "mixin",
    "alias",
    "struct",
    "class",
    "{",
    "}",
    ";",
    "import std.stdio;",
    "pragma(msg, \"fuzz\");"
];

immutable string[] FUZZ_OPS = ["insert", "delete", "flip", "duplicate"];
immutable string[] FUZZ_CHARS = ["a","b","c","d","e","f","g","h","i","j","k","l","m","n","o","p","q","r","s","t","u","v","w","x","y","z","{","}","[","]","(",")",";",",","+","-","/","*"];

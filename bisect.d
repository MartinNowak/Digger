module bisect;

import core.thread;

import std.algorithm;
import std.exception;
import std.file;
import std.getopt : getopt;
import std.path;
import std.process;
import std.range;
import std.string;

import ae.sys.file;
import ae.sys.git;
import ae.utils.math;
import ae.utils.sini;

import common;
import config;
import repo;

enum EXIT_UNTESTABLE = 125;

string bisectConfigFile;
struct BisectConfig
{
	string bad, good;
	bool reverse;
	string tester;
	bool bisectBuild;

	BuildConfig build;

	string[string] environment;
}
BisectConfig bisectConfig;

/// Final build directory for bisect tests.
alias currentDir = subDir!"current";

int doBisect(bool noVerify, string bisectConfigFile)
{
	bisectConfig = bisectConfigFile
		.readText()
		.splitLines()
		.parseStructuredIni!BisectConfig();
	d.config.build = bisectConfig.build;

	d.getMetaRepo().needRepo();
	auto repo = &d.getMetaRepo().git;

	d.needUpdate();

	void test(bool good, string rev)
	{
		auto name = good ? "GOOD" : "BAD";
		log("Sanity-check, testing %s revision %s...".format(name, rev));
		auto result = doBisectStep(rev);
		enforce(result != EXIT_UNTESTABLE,
			"%s revision %s is not testable"
			.format(name, rev));
		enforce(!result == good,
			"%s revision %s is not correct (exit status is %d)"
			.format(name, rev, result));
	}

	if (!noVerify)
	{
		auto good = getRev!true();
		auto bad = getRev!false();

		enforce(good != bad, "Good and bad revisions are both " ~ bad);

		auto nGood = repo.query(["log", "--format=oneline", good]).splitLines().length;
		auto nBad  = repo.query(["log", "--format=oneline", bad ]).splitLines().length;
		if (bisectConfig.reverse)
		{
			enforce(nBad < nGood, "Bad commit is newer than good commit (and reverse search is enabled)");
			test(false, bad);
			test(true, good);
		}
		else
		{
			enforce(nGood < nBad, "Good commit is newer than bad commit");
			test(true, good);
			test(false, bad);
		}
	}

	if (bisectConfig.bisectBuild)
		enforce(!bisectConfig.tester, "bisectBuild and specifying a test command are mutually exclusive");

	auto p0 = getRev!true();  // good
	auto p1 = getRev!false(); // bad
	if (bisectConfig.reverse)
		swap(p0, p1);

	auto cacheState = d.getCacheState([p0, p1]);
	bool[string] untestable;

	bisectLoop:
	while (true)
	{
		log("Finding shortest path between %s and %s...".format(p0, p1));
		auto path = repo.pathBetween(p0, p1);
		enforce(path.length >= 2 && path[0] == p0 && path[$-1] == p1, "Bad path calculation result");
		path = path[1..$-1];
		log("%d commits (about %d tests) remaining.".format(path.length, ilog2(path.length+1)));

		if (!path.length)
		{
			log("%s is the first %s commit".format(p1, bisectConfig.reverse ? "good" : "bad"));
			repo.run("show", p1);
			log("Bisection completed successfully.");
			return 0;
		}

		log("(%d total, %d cached, %d untestable)".format(
			path.length,
			path.filter!(commit => cacheState.get(commit, false)).walkLength,
			path.filter!(commit => commit in untestable).walkLength,
		));

		// First try all cached commits in the range (middle-most first).
		// Afterwards, do a binary-log search across the commit range for a testable commit.
		auto order = chain(
			path.radial     .filter!(commit =>  cacheState.get(commit, false)),
			path.binaryOrder.filter!(commit => !cacheState.get(commit, false))
		).filter!(commit => commit !in untestable).array;

		foreach (i, p; order)
		{
			auto result = doBisectStep(p);
			if (result == EXIT_UNTESTABLE)
			{
				log("Commit %s (%d/%d) is untestable.".format(p, i+1, order.length));
				untestable[p] = true;
				continue;
			}

			if (bisectConfig.reverse)
				result = result ? 0 : 1;

			if (result == 0) // good
				p0 = p;
			else
				p1 = p;

			continue bisectLoop;
		}

		log("There are only untestable commits left to bisect.");
		log("The first %s commit could be any of:".format(bisectConfig.reverse ? "good" : "bad"));
		foreach (p; path ~ [p1])
			log(p);
		throw new Exception("We cannot bisect more!");
	}

	assert(false);
}

string[] pathBetween(Repository* repo, string p0, string p1)
{
	auto commonAncestor = repo.query("merge-base", p0, p1);
	return chain(
		repo.commitsBetween(commonAncestor, p0).retro,
		commonAncestor.only,
		repo.commitsBetween(commonAncestor, p1)
	).array;
}

string[] commitsBetween(Repository* repo, string p0, string p1)
{
	return repo.query("log", "--reverse", "--pretty=format:%H", p0 ~ ".." ~ p1).splitLines();
}

/// Reorders [1, 2, ..., 98, 99]
/// into [50, 25, 75, 13, 38, 63, 88, ...]
T[] binaryOrder(T)(T[] items)
{
	auto n = items.length;
	assert(n);
	auto seen = new bool[n];
	auto result = new T[n];
	size_t c = 0;

	foreach (p; 0..30)
		foreach (i; 0..1<<p)
		{
			auto x = cast(size_t)(n/(2<<p) + ulong(n+1)*i/(1<<p));
			if (x >= n || seen[x])
				continue;
			seen[x] = true;
			result[c++] = items[x];
			if (c == n)
				return result;
		}
	assert(false);
}

unittest
{
	assert(iota(1, 7+1).array.binaryOrder.equal([4, 2, 6, 1, 3, 5, 7]));
	assert(iota(1, 100).array.binaryOrder.startsWith([50, 25, 75, 13, 38, 63, 88]));
}

int doBisectStep(string rev)
{
	log("Testing revision: " ~ rev);

	try
	{
		if (currentDir.exists)
		{
			version (Windows)
			{
				try
					currentDir.rmdirRecurse();
				catch (Exception e)
				{
					log("Failed to clean up %s: %s".format(currentDir, e.msg));
					Thread.sleep(500.msecs);
					log("Retrying...");
					currentDir.rmdirRecurse();
				}
			}
			else
				currentDir.rmdirRecurse();
		}

		auto state = d.begin(rev);

		scope (exit)
			if (d.buildDir.exists)
				rename(d.buildDir, currentDir);

		d.build(state);
	}
	catch (Exception e)
	{
		log("Build failed: " ~ e.toString());
		if (bisectConfig.bisectBuild)
			return 1;
		return EXIT_UNTESTABLE;
	}

	if (bisectConfig.bisectBuild)
	{
		log("Build successful.");
		return 0;
	}

	d.applyEnv(bisectConfig.environment);

	auto oldPath = environment["PATH"];
	scope(exit) environment["PATH"] = oldPath;

	// Add the final DMD to the environment PATH
	d.config.env["PATH"] = buildPath(currentDir, "bin").absolutePath() ~ pathSeparator ~ d.config.env["PATH"];
	environment["PATH"] = d.config.env["PATH"];

	d.logProgress("Running test command...");
	auto result = spawnShell(bisectConfig.tester, d.config.env, Config.newEnv).wait();
	d.logProgress("Test command exited with status %s (%s).".format(result, result==0 ? "GOOD" : result==EXIT_UNTESTABLE ? "UNTESTABLE" : "BAD"));
	return result;
}

/// Returns SHA-1 of the initial search points.
string getRev(bool good)()
{
	static string result;
	if (!result)
	{
		auto rev = good ? bisectConfig.good : bisectConfig.bad;
		result = parseRev(rev);
		log("Resolved %s revision `%s` to %s.".format(good ? "GOOD" : "BAD", rev, result));
	}
	return result;
}

struct CommitRange
{
	uint startTime; /// first bad commit
	uint endTime;   /// first good commit
}
/// Known unbuildable time ranges
const CommitRange[] badCommits =
[
	{ 1342243766, 1342259226 }, // Messed up DMD make files
	{ 1317625155, 1319346272 }, // Missing std.stdio import in std.regex
];

/// Find the earliest revision that Digger can build.
/// Used during development to extend Digger's range.
int doDelve(bool inBisect)
{
	if (inBisect)
	{
		log("Invoked by git-bisect - performing bisect step.");

		import std.conv;
		d.getMetaRepo().needRepo();
		auto rev = d.getMetaRepo().getRef("BISECT_HEAD");
		auto t = d.getMetaRepo().git.query("log", "-n1", "--pretty=format:%ct", rev).to!int();
		foreach (r; badCommits)
			if (r.startTime <= t && t < r.endTime)
			{
				log("This revision is known to be unbuildable, skipping.");
				return EXIT_UNTESTABLE;
			}

		d.config.cacheFailures = false;
		d.config.build = bisectConfig.build;
		auto state = d.begin(rev);
		try
		{
			d.build(state);
			return 1;
		}
		catch (Exception e)
		{
			log("Build failed: " ~ e.toString());
			return 0;
		}
	}
	else
	{
		d.getMetaRepo.needRepo();
		auto root = d.getMetaRepo().git.query("log", "--pretty=format:%H", "--reverse", "master").splitLines()[0];
		d.getMetaRepo().git.run(["bisect", "start", "--no-checkout", "master", root]);
		d.getMetaRepo().git.run("bisect", "run",
			thisExePath,
			"--dir", getcwd(),
			"--config-file", opts.configFile,
			"delve", "--in-bisect",
		);
		return 0;
	}
}

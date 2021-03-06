module digger;

import std.array;
import std.exception;
import std.file : thisExePath;
import std.stdio;
import std.typetuple;

static if(!is(typeof({import ae.utils.text;}))) static assert(false, "ae library not found, did you clone with --recursive?"); else:

version (Windows)
	static import ae.sys.net.wininet;
else
	static import ae.sys.net.ae;

import ae.sys.d.manager : DManager;
import ae.utils.funopt;
import ae.utils.main;
import ae.utils.meta : structFun;
import ae.utils.text : eatLine;

import bisect;
import common;
import config;
import custom;
import install;
import repo;

// http://d.puremagic.com/issues/show_bug.cgi?id=7016
version(Windows) static import ae.sys.windows;

alias BuildOptions = TypeTuple!(
	Switch!(hiddenOption, 0, "64"),
	Option!(string, "Select model (32 or 64).\nOn this system, the default is " ~ BuildConfig.components.common.defaultModel, null, 0, "model"),
	Option!(string[], "Do not build a component (that would otherwise be built by default). List of default components: " ~ DManager.defaultComponents.join(", "), "COMPONENT", 0, "without"),
	Option!(string[], "Specify an additional D component to build. List of available additional components: " ~ DManager.additionalComponents.join(", "), "COMPONENT", 0, "with"),
	Option!(string[], `Additional make parameters, e.g. "-j8" or "HOST_CC=g++48"`, "ARG", 0, "makeArgs"),
	Switch!("Bootstrap the compiler (build from C++ source code) instead of downloading a pre-built binary package", 0, "bootstrap"),
	Switch!(hiddenOption, 0, "use-vc"),
);

alias Spec = Parameter!(string, "D ref (branch / tag / point in time) to build, plus any additional forks or pull requests. Example:\n"
	"\"master @ 3 weeks ago + dmd#123 + You/dmd/awesome-feature\"");

BuildConfig parseBuildOptions(BuildOptions options)
{
	BuildConfig buildConfig;
	if (options[0])
		buildConfig.components.common.model = "64";
	if (options[1])
		buildConfig.components.common.model = options[1];
	foreach (componentName; options[2])
		buildConfig.components.enable[componentName] = false;
	foreach (componentName; options[3])
		buildConfig.components.enable[componentName] = true;
	buildConfig.components.common.makeArgs = options[4];
	buildConfig.components.dmd.bootstrap = options[5];
	buildConfig.components.dmd.useVC = options[6];
	return buildConfig;
}

struct Digger
{
static:
	@(`Build D from source code`)
	int build(BuildOptions options, Spec spec = "master")
	{
		buildCustom(spec, parseBuildOptions(options));
		return 0;
	}

	@(`Incrementally rebuild the current D checkout`)
	int rebuild(BuildOptions options)
	{
		incrementalBuild(parseBuildOptions(options));
		return 0;
	}

	@(`Install Digger's build result on top of an existing stable DMD installation`)
	int install(
		Switch!("Do not prompt", 'y') yes,
		Switch!("Only print what would be done", 'n') dryRun,
		Parameter!(string, "Directory to install to. Default is to find one in PATH.") installLocation = null,
	)
	{
		enforce(!yes || !dryRun, "--yes and --dry-run are mutually exclusive");
		.install.install(yes, dryRun, installLocation);
		return 0;
	}

	@(`Undo the "install" action`)
	int uninstall(
		Switch!("Only print what would be done", 'n') dryRun,
		Switch!("Do not verify files to be deleted; ignore errors") force,
		Parameter!(string, "Directory to uninstall from. Default is to search PATH.") installLocation = null,
	)
	{
		.uninstall(dryRun, force, installLocation);
		return 0;
	}

	@(`Bisect D history according to a bisect.ini file`)
	int bisect(bool noVerify, string bisectConfigFile)
	{
		return doBisect(noVerify, bisectConfigFile);
	}

	@(`Cache maintenance actions (run with no arguments for details)`)
	int cache(string[] args)
	{
		static struct CacheActions
		{
		static:
			@(`Compact the cache (replace identical files with hard links)`)
			int compact()
			{
				d.optimizeCache();
				return 0;
			}

			@(`Delete entries cached as unbuildable`)
			int purgeUnbuildable()
			{
				d.purgeUnbuildable();
				return 0;
			}

			@(`Migrate cached entries from one cache engine to another`)
			int migrate(string source, string target)
			{
				d.migrateCache(source, target);
				return 0;
			}
		}

		return funoptDispatch!CacheActions(["digger cache"] ~ args);
	}

	// hidden actions

	int buildAll(BuildOptions options, string spec = "master")
	{
		.buildAll(spec, parseBuildOptions(options));
		return 0;
	}

	int delve(bool inBisect)
	{
		return doDelve(inBisect);
	}

	int parseRev(string rev)
	{
		stdout.writeln(.parseRev(rev));
		return 0;
	}

	int show(string revision)
	{
		d.getMetaRepo().needRepo();
		d.getMetaRepo().git.run("log", "-n1", revision);
		d.getMetaRepo().git.run("log", "-n1", "--pretty=format:t=%ct", revision);
		return 0;
	}

	int help()
	{
		throw new Exception("For help, run digger without any arguments.");
	}
}

int digger()
{
	if (opts.action == "do")
		return handleWebTask(opts.actionArguments.dup);

	static void usageFun(string usage)
	{
		import std.algorithm, std.array, std.stdio, std.string;
		auto lines = usage.splitLines();

		stderr.writeln("Digger v" ~ diggerVersion ~ " - a D source code building and archaeology tool");
		stderr.writeln("Created by Vladimir Panteleev <vladimir@thecybershadow.net>");
		stderr.writeln("https://github.com/CyberShadow/Digger");
		stderr.writeln();

		if (lines[0].canFind("ACTION [ACTION-ARGUMENTS]"))
		{
			lines =
				[lines[0].replace(" ACTION ", " [OPTION]... ACTION ")] ~
				getUsageFormatString!(structFun!Opts).splitLines()[1..$] ~
				lines[1..$];

			stderr.writefln("%-(%s\n%)", lines);
			stderr.writeln();
			stderr.writeln("For help on a specific action, run: digger ACTION --help");
			stderr.writeln("For more information, see README.md.");
			stderr.writeln();
		}
		else
			stderr.writefln("%-(%s\n%)", lines);
	}

	return funoptDispatch!(Digger, FunOptConfig.init, usageFun)([thisExePath] ~ (opts.action ? [opts.action.value] ~ opts.actionArguments : []));
}

mixin main!digger;

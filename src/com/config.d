/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

User preferences persisted as JSON in an OS-specific config directory — backend/connection/audio settings read at startup and editable at runtime via File->Properties.
*/

module com.config;

import std.json;
import std.file : exists, read, write, mkdirRecurse;
import std.path : buildPath;
import std.process : environment;
import std.stdio : stderr;
// Stable storage identifier for the per-user config directory. Deliberately a
// fixed literal, NOT APP_NAME: re-styling the display name (e.g. "Extended" ->
// "EXTended") must not move the config dir and orphan an existing prefs file.
private enum CONFIG_DIR = "CheeseCutter-Extended";

// Bumped when the on-disk schema changes incompatibly. Stored as "version" in
// the JSON so a future load() can migrate; kept separate from APP_VERSION (the
// app can ship many versions sharing one schema).
enum CONFIG_SCHEMA_VERSION = 1;

// The persisted user preferences. Defaults here are the built-in fallback used
// when no config file exists yet; the file (then the CLI) override them.
struct Prefs {
	string backend = "local";        // "local" | "ultimate" | "vice"
	string ultimateHost = "127.0.0.1";
	int    ultimatePort = 80;
	string x64scPath = "";           // empty = launch x64sc from PATH
	string audioDriver = "";         // empty = SDL default driver
	// reSID (local) emulation settings — ignored while a remote backend is active.
	int    sidModel = 0;             // 0 = 6581, 1 = 8580
	int    filter6581 = 0;           // filter-preset index for the 6581 model
	int    filter8580 = 0;           // filter-preset index for the 8580 model
}

__gshared Prefs prefs;

// OS-specific per-user config directory (created on demand), following platform
// convention: %APPDATA% on Windows, ~/Library/Application Support on macOS,
// $XDG_CONFIG_HOME (else ~/.config) elsewhere.
string configDir() {
	version(Windows) {
		string base = environment.get("APPDATA", "");
		if(base.length == 0) base = environment.get("USERPROFILE", ".");
		return buildPath(base, CONFIG_DIR);
	} else version(OSX) {
		string home = environment.get("HOME", ".");
		return buildPath(home, "Library", "Application Support", CONFIG_DIR);
	} else {
		string base = environment.get("XDG_CONFIG_HOME", "");
		if(base.length == 0)
			base = buildPath(environment.get("HOME", "."), ".config");
		return buildPath(base, "cheesecutter-extended");
	}
}

string configPath() { return buildPath(configDir(), "config.json"); }

// Read the prefs file into `prefs`, tolerating missing/extra keys. If the file
// does not exist, leave the defaults and create it so the user has something to
// edit on disk. Never throws — bad/locked config must not stop the editor.
void load() {
	string path = configPath();
	if(!exists(path)) {
		save();
		return;
	}
	try {
		auto root = parseJSON(cast(string)read(path));
		void str(string key, ref string dst) {
			if(auto p = key in root.object)
				if(p.type == JSONType.string) dst = p.str;
		}
		void integer(string key, ref int dst) {
			if(auto p = key in root.object)
				if(p.type == JSONType.integer) dst = cast(int)p.integer;
		}
		str("backend", prefs.backend);
		str("ultimateHost", prefs.ultimateHost);
		integer("ultimatePort", prefs.ultimatePort);
		str("x64scPath", prefs.x64scPath);
		str("audioDriver", prefs.audioDriver);
		integer("sidModel", prefs.sidModel);
		integer("filter6581", prefs.filter6581);
		integer("filter8580", prefs.filter8580);
	}
	catch(Exception e) {
		stderr.writeln("config: could not read ", path, " (", e.msg,
					   "); using defaults.");
	}
}

// Write `prefs` back out (pretty-printed). Never throws.
void save() {
	try {
		mkdirRecurse(configDir());
		JSONValue root = [
			"version":      JSONValue(CONFIG_SCHEMA_VERSION),
			"backend":      JSONValue(prefs.backend),
			"ultimateHost": JSONValue(prefs.ultimateHost),
			"ultimatePort": JSONValue(prefs.ultimatePort),
			"x64scPath":    JSONValue(prefs.x64scPath),
			"audioDriver":  JSONValue(prefs.audioDriver),
			"sidModel":     JSONValue(prefs.sidModel),
			"filter6581":   JSONValue(prefs.filter6581),
			"filter8580":   JSONValue(prefs.filter8580),
		];
		write(configPath(), root.toPrettyString());
	}
	catch(Exception e) {
		stderr.writeln("config: could not write ", configPath(), " (", e.msg, ").");
	}
}

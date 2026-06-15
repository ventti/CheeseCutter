/*
CheeseCutter-Extended. Licensed under GNU GPL.

Man-page generator. The CLI option list (CliOpt[]) is the single source of
truth — see cliOptions() in src/main.d, used for both --help and the man page.
This module renders that list as roff for `ccutter --dump-man [lang]`, in
English (default) or a localized variant (fr/de/sv/fi). Regenerate the shipped
pages with `make docs`. The non-English strings are machine-authored; have a
native speaker review them.
*/
module manpage;

import std.array : appender, replace, split, join;
import std.string : format;

/// One command-line option: literal flags, arg placeholder, English help.
struct CliOpt { string flags; string arg; string help; }

/// Localized strings for a man page. `opt` maps an option's `flags` string to
/// its translated help; anything missing falls back to the English help.
private struct ManLang {
	string manual;                                   // .TH manual name
	string sName, sSynopsis, sDescription;           // section headers
	string sOptions, sEnvironment, sKeys, sSeeAlso;
	string tagline;                                  // NAME one-liner
	string optionWord, fileWord;                     // SYNOPSIS metavars
	string basedOn;                                  // 4x %s template
	string license;
	string envDesc;
	string keysText;
	string[string] opt;
}

private ManLang langEN() {
	ManLang l;
	l.manual = "User Commands";
	l.sName = "NAME"; l.sSynopsis = "SYNOPSIS"; l.sDescription = "DESCRIPTION";
	l.sOptions = "OPTIONS"; l.sEnvironment = "ENVIRONMENT"; l.sKeys = "KEYS";
	l.sSeeAlso = "SEE ALSO";
	l.tagline = "SID music editor";
	l.optionWord = "OPTION"; l.fileWord = "FILE";
	l.basedOn = "%s %s, based on %s %s.";
	l.license = "CheeseCutter (C) 2009-17 Abaddon. Released under GNU GPL.";
	l.envDesc = "If set, sent as the X-Password header on every C64 Ultimate REST request (firmware 3.12+).";
	l.keysText = "In the editor press F12 for context help, or run ccutter --dump-keys for the full reference. Shift-F10 saves the current subtune as a self-running .prg.";
	return l; // opt empty -> English help used directly
}

private ManLang langFR() {
	auto l = langEN();
	l.manual = "Commandes utilisateur";
	l.sName = "NOM"; l.sDescription = "DESCRIPTION"; l.sOptions = "OPTIONS";
	l.sEnvironment = "ENVIRONNEMENT"; l.sKeys = "TOUCHES"; l.sSeeAlso = "VOIR AUSSI";
	l.tagline = "éditeur de musique SID";
	l.optionWord = "OPTION"; l.fileWord = "FICHIER";
	l.basedOn = "%s %s, basé sur %s %s.";
	l.license = "CheeseCutter (C) 2009-17 Abaddon. Publié sous GNU GPL.";
	l.envDesc = "Si défini, envoyé comme en-tête X-Password à chaque requête REST du C64 Ultimate (firmware 3.12+).";
	l.keysText = "Dans l'éditeur, appuyez sur F12 pour l'aide contextuelle, ou lancez ccutter --dump-keys pour la référence complète. Shift-F10 enregistre le sous-morceau courant en .prg autonome.";
	l.opt = [
		"-b": "Définir la taille du tampon de lecture (déf=2048)",
		"-f, --full": "Démarrer en mode plein écran",
		"-nofp": "Ne pas utiliser l'émulation resid-fp",
		"-fpr": "Spécifie le préréglage de filtre. x = 0..16 pour 6581 et 0..1 pour 8580",
		"-i": "Désactive l'interpolation resid (utilise le mode rapide à la place)",
		"-l": "Active l'émulation du timing badline du VIC-II",
		"-m": "Spécifie le modèle SID pour reSID (6581/8580) (déf=0)",
		"-n": "Active le mode NTSC",
		"-r": "Définit la fréquence de lecture (déf=48000)",
		"-y": "Utiliser la superposition vidéo YUV",
		"-h, --help": "Afficher cette aide et quitter",
		"--height": "Définit la hauteur du séquenceur en lignes (min=40, max=64) ; désactive l'autoscale",
		"--width": "Définit la largeur de l'interface en colonnes (min=160, max=200) ; désactive l'autoscale",
		"--dump-keys": "Affiche la référence clavier en Markdown et quitte",
		"--dump-man": "Affiche la page de manuel (roff) sur la sortie standard et quitte",
		"--ultimate": "Jouer sur un C64 Ultimate (1541U/Ultimate64) à l'IP via son API REST",
		"--ultimate-port": "Port de l'API REST pour --ultimate (déf=80)",
		"--vice": "Jouer sur un émulateur VICE x64sc (lance x64sc depuis le PATH). --vice=hôte:port pour se connecter à un -binarymonitor en cours, ou --vice=/chemin/x64sc pour lancer ce binaire",
		"--vice-port": "Port du moniteur binaire pour --vice (déf=6502)",
		"--verbose": "Active la journalisation détaillée",
	];
	return l;
}

private ManLang langDE() {
	auto l = langEN();
	l.manual = "Benutzerbefehle";
	l.sName = "NAME"; l.sSynopsis = "ÜBERSICHT"; l.sDescription = "BESCHREIBUNG";
	l.sOptions = "OPTIONEN"; l.sEnvironment = "UMGEBUNG"; l.sKeys = "TASTEN";
	l.sSeeAlso = "SIEHE AUCH";
	l.tagline = "SID-Musik-Editor";
	l.optionWord = "OPTION"; l.fileWord = "DATEI";
	l.basedOn = "%s %s, basierend auf %s %s.";
	l.license = "CheeseCutter (C) 2009-17 Abaddon. Veröffentlicht unter der GNU GPL.";
	l.envDesc = "Falls gesetzt, wird er als X-Password-Header bei jeder C64-Ultimate-REST-Anfrage gesendet (Firmware 3.12+).";
	l.keysText = "Drücken Sie im Editor F12 für die Kontexthilfe oder führen Sie ccutter --dump-keys für die vollständige Referenz aus. Shift-F10 speichert das aktuelle Unterstück als eigenständige .prg.";
	l.opt = [
		"-b": "Wiedergabepuffergröße festlegen (Std=2048)",
		"-f, --full": "Im Vollbildmodus starten",
		"-nofp": "resid-fp-Emulation nicht verwenden",
		"-fpr": "Filter-Voreinstellung angeben. x = 0..16 für 6581 und 0..1 für 8580",
		"-i": "resid-Interpolation deaktivieren (stattdessen schnellen Modus verwenden)",
		"-l": "VIC-II-Badline-Timing-Emulation aktivieren",
		"-m": "SID-Modell für reSID angeben (6581/8580) (Std=0)",
		"-n": "NTSC-Modus aktivieren",
		"-r": "Wiedergabefrequenz festlegen (Std=48000)",
		"-y": "YUV-Video-Overlay verwenden",
		"-h, --help": "Diese Hilfe anzeigen und beenden",
		"--height": "Sequenzerhöhe in Zeilen festlegen (min=40, max=64); deaktiviert die Autoskalierung",
		"--width": "UI-Breite in Spalten festlegen (min=160, max=200); deaktiviert die Autoskalierung",
		"--dump-keys": "Die Tastaturreferenz als Markdown ausgeben und beenden",
		"--dump-man": "Die Handbuchseite (roff) auf die Standardausgabe schreiben und beenden",
		"--ultimate": "Auf einem C64 Ultimate (1541U/Ultimate64) unter IP über dessen REST-API abspielen",
		"--ultimate-port": "REST-API-Port für --ultimate (Std=80)",
		"--vice": "Auf einem VICE-x64sc-Emulator abspielen (startet x64sc aus dem PATH). --vice=Host:Port verbindet mit einem laufenden -binarymonitor, --vice=/pfad/x64sc startet diese Binärdatei",
		"--vice-port": "Binärmonitor-Port für --vice (Std=6502)",
		"--verbose": "Ausführliche Protokollierung aktivieren",
	];
	return l;
}

private ManLang langSV() {
	auto l = langEN();
	l.manual = "Användarkommandon";
	l.sName = "NAMN"; l.sSynopsis = "SYNOPSIS"; l.sDescription = "BESKRIVNING";
	l.sOptions = "FLAGGOR"; l.sEnvironment = "MILJÖ"; l.sKeys = "TANGENTER";
	l.sSeeAlso = "SE ÄVEN";
	l.tagline = "SID-musikredigerare";
	l.optionWord = "FLAGGA"; l.fileWord = "FIL";
	l.basedOn = "%s %s, baserad på %s %s.";
	l.license = "CheeseCutter (C) 2009-17 Abaddon. Släppt under GNU GPL.";
	l.envDesc = "Om satt skickas det som X-Password-huvud i varje REST-begäran till C64 Ultimate (firmware 3.12+).";
	l.keysText = "Tryck F12 i editorn för kontexthjälp, eller kör ccutter --dump-keys för den fullständiga referensen. Shift-F10 sparar den aktuella dellåten som en självkörande .prg.";
	l.opt = [
		"-b": "Ange storlek på uppspelningsbufferten (def=2048)",
		"-f, --full": "Starta i helskärmsläge",
		"-nofp": "Använd inte resid-fp-emulering",
		"-fpr": "Ange filterförval. x = 0..16 för 6581 och 0..1 för 8580",
		"-i": "Inaktivera resid-interpolering (använd snabbläge i stället)",
		"-l": "Aktivera VIC-II badline-timingemulering",
		"-m": "Ange SID-modell för reSID (6581/8580) (def=0)",
		"-n": "Aktivera NTSC-läge",
		"-r": "Ange uppspelningsfrekvens (def=48000)",
		"-y": "Använd YUV-videoöverlägg",
		"-h, --help": "Visa denna hjälp och avsluta",
		"--height": "Ange sequencerhöjd i rader (min=40, max=64); inaktiverar autoskalning",
		"--width": "Ange gränssnittsbredd i kolumner (min=160, max=200); inaktiverar autoskalning",
		"--dump-keys": "Skriv ut tangentbordsreferensen som Markdown och avsluta",
		"--dump-man": "Skriv ut manualsidan (roff) till standard ut och avsluta",
		"--ultimate": "Spela på en riktig C64 Ultimate (1541U/Ultimate64) på IP via dess REST-API",
		"--ultimate-port": "REST-API-port för --ultimate (def=80)",
		"--vice": "Spela på en VICE x64sc-emulator (startar x64sc från PATH). --vice=värd:port ansluter till en körande -binarymonitor, --vice=/sökväg/x64sc startar den binären",
		"--vice-port": "Binärmonitorport för --vice (def=6502)",
		"--verbose": "Aktivera utförlig loggning",
	];
	return l;
}

private ManLang langFI() {
	auto l = langEN();
	l.manual = "Käyttäjän komennot";
	l.sName = "NIMI"; l.sSynopsis = "YLEISKATSAUS"; l.sDescription = "KUVAUS";
	l.sOptions = "VALITSIMET"; l.sEnvironment = "YMPÄRISTÖ"; l.sKeys = "NÄPPÄIMET";
	l.sSeeAlso = "KATSO MYÖS";
	l.tagline = "SID-musiikkieditori";
	l.optionWord = "VALITSIN"; l.fileWord = "TIEDOSTO";
	l.basedOn = "%s %s, perustuu ohjelmaan %s %s.";
	l.license = "CheeseCutter (C) 2009-17 Abaddon. Julkaistu GNU GPL -lisenssillä.";
	l.envDesc = "Jos asetettu, lähetetään X-Password-otsakkeena jokaisessa C64 Ultimaten REST-pyynnössä (laiteohjelmisto 3.12+).";
	l.keysText = "Paina editorissa F12 saadaksesi kontekstiohjeen, tai aja ccutter --dump-keys saadaksesi täyden viitteen. Shift-F10 tallentaa nykyisen alikappaleen itsestään käynnistyvänä .prg-tiedostona.";
	l.opt = [
		"-b": "Aseta toiston puskurin koko (olet=2048)",
		"-f, --full": "Käynnistä koko näytön tilassa",
		"-nofp": "Älä käytä resid-fp-emulaatiota",
		"-fpr": "Määritä suodatinesiasetus. x = 0..16 (6581) ja 0..1 (8580)",
		"-i": "Poista resid-interpolointi käytöstä (käytä nopeaa tilaa)",
		"-l": "Ota käyttöön VIC-II:n badline-ajoituksen emulointi",
		"-m": "Määritä SID-malli reSIDille (6581/8580) (olet=0)",
		"-n": "Ota NTSC-tila käyttöön",
		"-r": "Aseta toistotaajuus (olet=48000)",
		"-y": "Käytä YUV-videopeittokuvaa",
		"-h, --help": "Näytä tämä ohje ja poistu",
		"--height": "Aseta sekvensserin korkeus riveinä (min=40, max=64); poistaa automaattiskaalauksen",
		"--width": "Aseta käyttöliittymän leveys sarakkeina (min=160, max=200); poistaa automaattiskaalauksen",
		"--dump-keys": "Tulosta näppäimistöviite Markdownina ja poistu",
		"--dump-man": "Tulosta man-sivu (roff) vakiotulosteeseen ja poistu",
		"--ultimate": "Toista oikealla C64 Ultimatella (1541U/Ultimate64) IP-osoitteessa sen REST-rajapinnan kautta",
		"--ultimate-port": "REST-rajapinnan portti --ultimate-valitsimelle (olet=80)",
		"--vice": "Toista VICE x64sc -emulaattorilla (käynnistää x64sc:n PATHista). --vice=osoite:portti yhdistää käynnissä olevaan -binarymonitoriin, --vice=/polku/x64sc käynnistää kyseisen ohjelman",
		"--vice-port": "Binäärimonitorin portti --vice-valitsimelle (olet=6502)",
		"--verbose": "Ota käyttöön yksityiskohtainen lokitus",
	];
	return l;
}

private ManLang manLang(string code) {
	switch(code) {
		case "fr": return langFR();
		case "de": return langDE();
		case "sv": return langSV();
		case "fi": return langFI();
		default:   return langEN();
	}
}

/// Render the man page (roff) for the given option list and language code
/// ("" / "en" = English). Output is deterministic.
string dumpManPage(CliOpt[] opts, string code) {
	import com.util : APP_NAME, APP_VERSION, UPSTREAM_NAME, UPSTREAM_VERSION;
	auto L = manLang(code);
	// roff: escape backslashes and hyphens in free text.
	string esc(string s) { return s.replace(`\`, `\\`).replace("-", `\-`); }
	auto a = appender!string();
	if(code.length && code != "en")
		a.put(".\\\" Generated by 'ccutter --dump-man " ~ code ~
			  "' (src/manpage.d). Machine translation; review recommended.\n");
	a.put(format(".TH CCUTTER \"1\" \"\" \"%s %s\" \"%s\"\n", APP_NAME, APP_VERSION, L.manual));
	a.put(".SH " ~ L.sName ~ "\nccutter \\- " ~ esc(L.tagline) ~ "\n");
	a.put(".SH " ~ L.sSynopsis ~ "\n.B ccutter\n");
	a.put("[\\fI\\," ~ L.optionWord ~ "\\/\\fR]... [\\fI\\," ~ L.fileWord ~ "\\/\\fR]\n");
	a.put(".SH " ~ L.sDescription ~ "\n");
	a.put(esc(format(L.basedOn, APP_NAME, APP_VERSION, UPSTREAM_NAME, UPSTREAM_VERSION)) ~ "\n.PP\n");
	a.put(esc(L.license) ~ "\n");
	a.put(".SH " ~ L.sOptions ~ "\n");
	foreach(o; opts) {
		a.put(".TP\n");
		string[] bolded;
		foreach(f; o.flags.split(", "))
			bolded ~= "\\fB" ~ esc(f) ~ "\\fR";
		a.put(bolded.join(", ") ~ (o.arg.length ? " " ~ esc(o.arg) : "") ~ "\n");
		string h = (o.flags in L.opt) ? L.opt[o.flags] : o.help;
		a.put(esc(h) ~ "\n");
	}
	a.put(".SH " ~ L.sEnvironment ~ "\n.TP\n\\fBCHEESECUTTER_ULTIMATE_PASSWORD\\fR\n");
	a.put(esc(L.envDesc) ~ "\n");
	a.put(".SH " ~ L.sKeys ~ "\n" ~ esc(L.keysText) ~ "\n");
	a.put(".SH " ~ L.sSeeAlso ~ "\nct2util(1)\n");
	return a.data;
}

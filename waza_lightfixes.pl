#!/usr/bin/perl
BEGIN {
    $::VERSION = "0.40-PRE-RELEASE-2";
}

# tes3cmd: command line tool to do various hacks with TES3 plugins
# Copyright 2016 by John Moonsugar
# Distributed as part of the tes3cmd project:
#   https://github.com/john-moonsugar/tes3cmd/
# under the MIT License:
#   https://github.com/john-moonsugar/tes3cmd/blob/master/LICENSE
# Documentation:
#   https://github.com/john-moonsugar/tes3cmd/wiki
# to build on Windows with Par::Packer
# pp -o tes3cmd.exe tes3cmd

BEGIN {
    use constant DBG => grep(/^(?:-d|-?-debug)$/, @ARGV);
    use constant ASSERT => grep(/^-?-assert$/, @ARGV);
    use constant VERBOSE => (DBG or grep(/^(?:-v|-?-verbose)$/, @ARGV)); # debug turns on verbosity
}

use Carp;
use IO::Handle;
use Fcntl qw(SEEK_SET SEEK_CUR SEEK_END);
use File::Basename;
use File::Spec;
use File::Copy;
use File::Find;
use Getopt::Long qw(:config auto_abbrev);
use Data::Dumper;
use Storable;
use Cwd;
use strict;
use warnings;

my $R;				# current record for modify command

our $CURRENT_PLUGIN = '';
our $MWDIR;			# Where Morrowind is installed
our $DATADIR;			# where "Data Files" lives ($MWDIR/Data Files)
our $TES3CMD_DIR;		# tes3cmd directory ($MWDIR/tes3cmd)
our $CACHE_DIR;			# cache directory ($MWDIR/tes3cmd/cache)

### MAIN COMMON COMMAND OPTIONS
our @STDOPT = ("assert", "debug", "output=s", "verbose"); # options for all commands
our @MODOPT = ("backup-dir=s", "hide-backups"); # options for commands that modify
our $opt_active;				# limit processing to active plugins
our $opt_output;				# specify output (default is STDOUT)
our $opt_backup_dir;		# default value gets set in find_morrowind()
our $opt_exterior;		# select only exterior cells
our $opt_hide_backups;
our $opt_instance_type;		# show types for object instances
our $opt_instance_match;
our $opt_instance_no_match;
our $opt_interior;
our $opt_list;
our $opt_no_banner;
our $opt_no_cache;
our $opt_output_dir;
our $opt_overwrite;
our $opt_report_only;
our $opt_separator;
our $opt_sub_match;
our $opt_sub_no_match;
our @opt_exact_id = ();
our @opt_flag;
our @opt_id = ();
our @opt_ignore_plugin = ();
our @opt_match;
our @opt_no_match;
our @opt_type = ();

### MAIN COMMAND OPTIONS
our $opt_active_off;
our $opt_active_on;

our $opt_clean_all = 0;
our $opt_clean_instances = 0;
our $opt_clean_cell_params = 0;
our $opt_clean_dups = 0;
our $opt_clean_gmsts = 0;
our $opt_clean_junk_cells = 0;

our @opt_diff_ignore_types = ();
our $opt_diff_1_not_2;
our $opt_diff_2_not_1;
our $opt_diff_equal;
our $opt_diff_not_equal;
our $opt_diff_types;
our $opt_diff_sortsubrecs;

our @opt_dump_format;
our $opt_dump_no_quote;
our $opt_dump_raw;		# OBSOLETE
our $opt_dump_raw_with_header;	# OBSOLETE
our $opt_dump_binary;
our $opt_dump_header;
our $opt_dump_wrap;

our $opt_header_author = '';
our $opt_header_description = '';
our $opt_header_multiline = 0;
our $opt_header_synchronize;
our $opt_header_update_masters;
our $opt_header_update_record_count = 0;

our $opt_lint_all;
our $opt_lint_recommended;
our $opt_lint_autocalc_spells;
our $opt_lint_bloodmoon_dependency;
our $opt_lint_cell_00;
our $opt_lint_clean;
our $opt_lint_deprecated_lists;
our $opt_lint_dialogue_teleports;
our $opt_lint_duplicate_info;
our $opt_lint_duplicate_records;
our $opt_lint_expansion_dependency;
our $opt_lint_evil_gmsts;
our $opt_lint_fogbug;
our $opt_lint_fogsync;
our $opt_lint_getsoundplaying;
our $opt_lint_junk_cells;
our $opt_lint_master_sync;
our $opt_lint_menumode;
our $opt_lint_missing_author;
our $opt_lint_missing_description;
our $opt_lint_missing_version;
our $opt_lint_modified_info;
our $opt_lint_modified_info_id;
our $opt_lint_record_count;
our $opt_lint_overrides;
our $opt_lint_no_bloodmoon_functions;
our $opt_lint_no_tribunal_functions;
our $opt_lint_scripted_doors;

our $opt_modify_program_file = '';
our $opt_modify_replace = '';
our $opt_modify_replacefirst = '';
our $opt_modify_run = '';

our $opt_run_program_file = '';

our $opt_multipatch_cellnames;
our $opt_multipatch_fogbug;
our $opt_multipatch_merge_objects;
our $opt_multipatch_merge_lists;
our $opt_multipatch_no_activate;
our $opt_multipatch_summons_persist;
our @opt_multipatch_delete_creature;
our @opt_multipatch_delete_item;

our $opt_overdial_single;

our $opt_testcodec_continue;
our $opt_testcodec_ignore_cruft;
our @opt_testcodec_exclude_type = ();

### Global wanted record selectors, set in get_wanted() and rec_match()
our $WANTED_IDS;
our $WANTED_TYPES;
our $WANTED_FLAGS;

# misc globals
our %STATS;

### CLASS: Util

package Util;

BEGIN {
    # since perl will optimize out conditional branches that are never
    # reached, we define the following constants so that we only compile
    # debug/help code into the program when it it actually needed.
    use constant DBG => scalar(grep(/^(?:-d|-?-debug)$/, @ARGV));
    use constant ASSERT => grep(/^-?-assert$/, @ARGV);
    use constant VERBOSE => (DBG or grep(/^(?:-v|-?-verbose)$/, @ARGV)); # debug turns on verbosity

    use Exporter ();
    our @ISA = qw(Exporter);
    our @EXPORT_OK = qw(abort assert err dbg prn msg msgonce list_files mkpath sort_by_date RELOAD);
    our %EXPORT_TAGS = ( FIELDS => [ @EXPORT_OK ] );
}

use constant RELOAD => 1;	# tell methods not to use cached data

sub err { warn "[ERROR ($CURRENT_PLUGIN): @_]\n"; }
sub dbg { warn "[DEBUG ($CURRENT_PLUGIN): @_]\n"; }
sub msg { warn "@_\n"; }
my %ONE_TIME_MESSAGE;
sub msgonce {
    warn "@_\n" unless (defined($ONE_TIME_MESSAGE{@_}));
    $ONE_TIME_MESSAGE{@_}++;
}
sub prn { print "@_\n"; }
sub assert { my($bool, $msg) = @_; Carp::confess("Assertion Failed: $msg") unless ($bool); }
sub abort {
    my($msg) = @_;
    my $diagnosis = '';
    if ($^O =~ /^MSWin/) {
	if ($msg =~ /permission denied/i) {
	    $diagnosis =<<END
Permission errors may occur in recent versions of Windows OS (since Vista) due to
the UAC feature and new protected nature of "Program Files". The ideal
solution is to install Morrowind some place other than "Program Files", such
as "C:\\Games\\Morrowind". Some choose to disable UAC, but that is not 
recommended as it is less secure.
END
	}
    }
    $msg = qq{FATAL ERROR ($CURRENT_PLUGIN): $msg$diagnosis};
    if (DBG) {
	Carp::confess($msg);
    } else {
	Carp::croak($msg);
    }
}

# return a dictionary of all the files found in the given directory.
# keys are lowercased for caseless file finding.
sub list_files {
    my($dir) = @_;
    my %files = ();
    dbg(qq{Listing files in: "$dir"}) if (DBG);
    if (opendir(DH, $dir)) {
	while (my $file = readdir(DH)) {
	    next if (($file eq '.') or ($file eq '..'));
	    # map caseless lowercased version to original cased version
	    $files{lc($file)} = $file;
	}
	closedir(DH);
    } else {
	abort(qq{Opening "$dir" ($!)});
    }
    return(\%files);
}

sub mkpath {
    my($path, $perms_in) = @_;
    dbg(qq{Creating Path: "$path" with permissions: $perms_in}) if (DBG);
    my $perms = $perms_in || 0755;
    my $dir = "";
    foreach my $name (split(m!/!, $path)) {
	$dir .= "$name/";
	unless (-d $dir) {
	    unless (mkdir($dir, $perms)) {
		print STDERR qq{mkpath(): Error creating "$dir" ($!)\n};
		return(0);
	    }
	}
    }
    return(1);
}

# sort list of files by their modification date
# TBD - assume @files can have directories
sub sort_by_date {
    my($dir, @files) = @_;
    my $dirlist = list_files($dir);
    my @sorted = sort { (-M "$dir/$dirlist->{lc($b)}") <=> (-M "$dir/$dirlist->{lc($a)}") } @files;
    dbg(qq{sorted files:} . join("\n", @sorted)) if (DBG);
    return(@sorted);
}


### END OF Util

package TES3::Util;

BEGIN {
    use constant DBG => grep(/^(?:-d|-?-debug)$/, @ARGV);
    use constant ASSERT => grep(/^-?-assert$/, @ARGV);
    use constant VERBOSE => (DBG or grep(/^(?:-v|-?-verbose)$/, @ARGV)); # debug turns on verbosity
    Util->import(qw(abort assert dbg err msg msgonce prn list_files sort_by_date));
}


### CLASS: TES3::Util

# assuming the program is run somewhere under the Morrowind game directory, find the
# location of the "Data Files" directory by walking up the hierarchy. Then create
# TES3CMD_DIR if it does not already exist.
# since find_morrowind() sets some global option ($opt_) defaults, run it before GetOptions()
sub find_morrowind {
    return($DATADIR) if (defined($DATADIR));
    my $dir = $ENV{PWD} || Cwd::getcwd; # TBD: check this works on Windows
    abort(qq{Current working directory does not exist: "$dir"}) unless (defined $dir);
    dbg(qq{Checking for data dir in: "$dir"}) if (DBG);
    while (-d $dir) {
	dbg(qq{Checking for Morrowind home in: "$dir"}) if (DBG);
	my $datadir = list_files($dir)->{"data files"};
	my $mwini = list_files($dir)->{"morrowind.ini"};
	if ($datadir and $mwini) {
	    $MWDIR = $dir;
	    $DATADIR = "$MWDIR/$datadir";
	    msg(qq{DATADIR = "$DATADIR"}) if (VERBOSE);
	    last;
	}
	my @parts = split(m![\\/]!, $dir);
	pop(@parts);
	$dir = join("/", @parts);
	dbg(qq{Checking for "Data Files" in: "$dir"}) if (DBG);
    }
    if (defined $MWDIR) {
	$TES3CMD_DIR = "$MWDIR/tes3cmd";
	$CACHE_DIR = "$MWDIR/tes3cmd/cache";
	unless (-d $CACHE_DIR) {
	    Util::mkpath($CACHE_DIR, 0755) or
		  abort(qq{Unable to make directory: "$CACHE_DIR" ($!)});
	}
	# TBD: remove this post release of v0.40!!!
	my $oldcachefiles = list_files($TES3CMD_DIR);
	foreach my $oldcache (keys %$oldcachefiles) {
	    if ($oldcache =~ /\.cache$/ and
		-f "$TES3CMD_DIR/$oldcache") {
		msg(qq{[Note: Removing obsolete cache file: "$TES3CMD_DIR/$oldcache"]});
		unlink("$TES3CMD_DIR/$oldcache");
	    }
	}
    } else {
	msg(qq{WARNING: Can't find "Data Files" directory, functionality reduced. You should first cd (change directory) to somewhere under where Morrowind is installed.});
	$MWDIR = '.';
	$DATADIR = '.';		# not running under morrowind directory
	$TES3CMD_DIR = '.';
	$CACHE_DIR = '.';
	$opt_no_cache = 1;	# don't know where MW stuff is, turn off caching
    }
    prn qq{<DATADIR> is "$DATADIR"} if (VERBOSE);
    unless (-d $TES3CMD_DIR) {
	if (-e $TES3CMD_DIR) {
	    abort(qq{"$TES3CMD_DIR" exists, but is not a directory, please remove or rename it.});
	}
	mkdir($TES3CMD_DIR, 0755) or
	    abort(qq{Unable to make directory: "$TES3CMD_DIR" ($!)});
    }
    if (-d "$DATADIR/tes3cmd") {
	msg(qq{[Found old version of tes3cmd directory: $DATADIR/tes3cmd]});
	msg(qq{[This old version can be safely removed. New version is now one level up.]});
    }
    $opt_backup_dir = "$TES3CMD_DIR/backups"; # TBD: check how we do default during init!
} # find_morrowind

BEGIN {
    # print DEBUG banner
    warn(<<EOF) if (DBG);
DEBUG ON
tes3cmd Version: $::VERSION
Platform: $^O
EOF
}

### TES3::Util methods

sub new {
    my($class) = @_;
    return(bless({}, $class));
}

# map of "Data Files" directory for caseless filename lookup
sub datafiles_map {
    my($self, $reload) = @_;
    return($self->{datafiles_map})
	if (defined($self->{datafiles_map}) and (not $reload));
    return($self->{datafiles_map} = list_files($DATADIR));
}

sub datapath {
    my($self, $plugin, $reload) = @_;
    assert(defined $DATADIR, "DATADIR is not defined") if (ASSERT);
    my $path = $self->datafiles_map($reload)->{lc($plugin)};
    if (defined $path) {
	return("$DATADIR/" . $path);
    } else {
	return(undef);
    }
}
sub datafile {
    my($self, $plugin, $reload) = @_;
    $self->datafiles_map($reload)->{lc($plugin)};
}

sub ini_file {
    my($self, $reload) = @_;
    return($self->{ini_file})
	if (defined($self->{ini_file} and not $reload));
    my $mwfiles = list_files($MWDIR);
    my $mwinifile = $mwfiles->{'morrowind.ini'};
    abort(qq{ini_file(): Error finding "$mwinifile" in "$MWDIR"})
	if (not -f "$MWDIR/$mwinifile");
    return($self->{ini_file} = "$MWDIR/$mwinifile");
}

sub read_gamefiles {
    my($self) = @_;
    my $mwini = $self->ini_file;
    my @gamefiles = ();
    open(INI, "<", $mwini) or abort(qq{opening "$mwini" for input ($!)});
    binmode(INI, ':crlf');
    dbg(qq{Opened "$mwini" for Input\n}) if (DBG);
    while (<INI>) {
	last if (/^\[Game Files\]/i);
    }
    while (<INI>) {
	chomp;
	if (/^GameFile\d+=(.+)/) {
	    push(@gamefiles, $1);
	} elsif (/^\[.+\]/) {
	    last;
	}
    }
    close(INI);
    return(\@gamefiles);
}

sub write_gamefiles {
    my($self, $gamefiles) = @_;
    my $mwini = $self->ini_file;
    my $tmpini = qq{${mwini}.tmp};
    open(INI, "<", $mwini) or abort(qq{opening "$mwini" for input ($!)});
    binmode(INI, ':crlf');
    open(TMP, ">", "$tmpini") or abort(qq{opening "$tmpini" for output ($!)});
    binmode(TMP, ':crlf');
    while (<INI>) {		# just copy ini file up to [Game Files] section
	print TMP;
	last if (/^\[Game Files\]/i);
    }
    my $i=0;
    foreach my $gamefile (@$gamefiles) { # write new gamefiles section
	print TMP "GameFile$i=$gamefile\n";
	$i++;
    }
    while (<INI>) {		# skip old gamefiles section
	if (/^\[.*\]/i) {
	    print TMP;
	    last;
	}
    }
    while (<INI>) {		# copy anything after gamefiles section
	print TMP $_;
    }
    close(INI);
    close(TMP);
    rename($mwini, "$mwini.old") or abort(qq{Error renaming "$mwini" to "$mwini.old" ($!)});
    rename($tmpini, $mwini) or abort(qq{Error renaming "$tmpini" to "$mwini" ($!)});
}

sub load_order {
    my($self, $reload) = @_;
    return(@{$self->{load_order}})
	if (defined($self->{load_order} and not $reload));
    abort("DATADIR not defined") unless (defined($DATADIR));
    my $gamefiles = $self->read_gamefiles();
    my @active;
    foreach my $plugin (@$gamefiles) {
	if ($self->datafile($plugin)) {
	    dbg(qq{Found Gamefile: "$plugin"}) if (DBG);
	    push(@active, $plugin);
	} else {
	    dbg(qq{MISSING Gamefile: "$plugin"}) if (DBG);
	}
    }
    my @sorted = sort_by_date($DATADIR, @active);
    return(@{$self->{load_order} = [grep(/\.esm$/i, @sorted), grep(/\.esp$/i, @sorted)]});
}

### END OF TES3::Util

### CLASS: TES3

package TES3;

our $HDR_AUTH_LENGTH = 32;
our $HDR_DESC_LENGTH = 256;

### SYMBOLIC NAMES FOR FIELD VALUES

# The flags field of the AIDT subrecord is for SERVICES offered by this actor
our %AIDT_FLAGS =
    ("weapon" => 0x00001,
     "armor" => 0x00002,
     "clothing" => 0x00004,
     "books" => 0x00008,
     "ingredient" => 0x00010,
     "picks" => 0x00020,
     "probes" => 0x00040,
     "lights" => 0x00080,
     "apparatus" => 0x00100,
     "repair" => 0x00200,
     "misc" => 0x00400,
     "spells" => 0x00800,
     "magic_items" => 0x01000,
     "potions" => 0x02000,
     "training" => 0x04000,
     "spellmaking" => 0x08000,
     "enchanting" => 0x10000,
     "repair_item" => 0x20000);

our %APPARATUS_TYPE =
    (0 => "Mortar_and_Pestle",
     1 => "Alembic",
     2 => "Calcinator",
     3 => "Retort");

our %ARMOR_INDEX =
    (0 => "Head",
     1 => "Hair",
     2 => "Neck",
     3 => "Cuirass",
     4 => "Groin",
     5 => "Skirt",
     6 => "Right_Hand",
     7 => "Left_Hand",
     8 => "Right_Wrist",
     9 => "Left_Wrist",
     10 => "Shield",
     11 => "Right_Forearm",
     12 => "Left_Forearm",
     13 => "Right_Upper_Arm",
     14 => "Left_Upper_Arm",
     15 => "Right_Foot",
     16 => "Left_Foot",
     17 => "Right_Ankle",
     18 => "Left_Ankle",
     19 => "Right_Knee",
     20 => "Left_Knee",
     21 => "Right_Upper_Leg",
     22 => "Left_Upper_Leg",
     23 => "Right_Pauldron",
     24 => "Left_Pauldron",
     25 => "Weapon",
     26 => "Tail");

our %ARMOR_TYPE =
    (0 => "Helmet",
     1 => "Cuirass",
     2 => "Left_Pauldron",
     3 => "Right_Pauldron",
     4 => "Greaves",
     5 => "Boots",
     6 => "Left_Gauntlet",
     7 => "Right_Gauntlet",
     8 => "Shield",
     9 => "Left_Bracer",
     10 => "Right_Bracer");

# max weight for each armor piece/class
our %ARMOR_CLASS =
    (0 => { "light" =>  3.0, "medium" =>  4.5 }, # Helmet
     1 => { "light" => 18.0, "medium" => 27.0 }, # Cuirass
     2 => { "light" =>  6.0, "medium" =>  9.0 }, # Left_Pauldron
     3 => { "light" =>  6.0, "medium" =>  9.0 }, # Right_Pauldron
     4 => { "light" =>  9.0, "medium" => 13.5 }, # Greaves
     5 => { "light" => 12.0, "medium" => 18.0 }, # Boots
     6 => { "light" =>  3.0, "medium" =>  4.5 }, # Left_Gauntlet
     7 => { "light" =>  3.0, "medium" =>  4.5 }, # Right_Gauntlet
     8 => { "light" =>  9.0, "medium" => 13.5 }, # Shield
     9 => { "light" =>  3.0, "medium" =>  4.5 }, # Left_Bracer
     10 => { "light" => 3.0, "medium" =>  4.5 }); # Right_Bracer

our %ATTRIBUTE =
    (-1 => "None",
     0 => "Strength",
     1 => "Intelligence",
     2 => "Willpower",
     3 => "Agility",
     4 => "Speed",
     5 => "Endurance",
     6 => "Personality",
     7 => "Luck");

our %AUTOCALC_FLAGS =
    ("weapon" => 0x00001,
     "armor" => 0x00002,
     "clothing" => 0x00004,
     "books" => 0x00008,
     "ingredient" => 0x00010,
     "picks" => 0x00020,
     "probes" => 0x00040,
     "lights" => 0x00080,
     "apparatus" => 0x00100,
     "repair" => 0x00200,
     "misc" => 0x00400,
     "spells" => 0x00800,
     "magic_items" => 0x01000,
     "potions" => 0x02000,
     "training" => 0x04000,
     "spellmaking" => 0x08000,
     "enchanting" => 0x10000,
     "repair_item" => 0x20000);

our %BIPED_OBJECT =
    (0 => "Head",
     1 => "Hair",
     2 => "Neck",
     3 => "Chest",
     4 => "Groin",
     5 => "Skirt",
     6 => "Right_Hand",
     7 => "Left_Hand",
     8 => "Right_Wrist",
     9 => "Left_Wrist",
     10 => "Shield",
     11 => "Right_Forearm",
     12 => "Left_Forearm",
     13 => "Right_Upper_Arm",
     14 => "Left_Upper_Arm",
     15 => "Right_Foot",
     16 => "Left_Foot",
     17 => "Right_Ankle",
     18 => "Left_Ankle",
     19 => "Right_Knee",
     20 => "Left_Knee",
     21 => "Right_Upper_Leg",
     22 => "Left_Upper_Leg",
     23 => "Right_Pauldron",
     24 => "Left_Pauldron",
     25 => "Weapon",
     26 => "Tail");

our %BYDT_PART =
    ('0' => "Head",
     '1' => "Hair",
     '2' => "Neck",
     '3' => "Chest",
     '4' => "Groin",
     '5' => "Hand",
     '6' => "Wrist",
     '7' => "Forearm",
     '8' => "Upperarm",
     '9' => "Foot",
     '10' => "Ankle",
     '11' => "Knee",
     '12' => "Upperleg",
     '13' => "Clavicle",
     '14' => "Tail");

our %BYDT_FLAGS = (Playable => 0, Female => 1, Not_Playable => 2);

our %BYDT_PTYP = ('0' => "Skin", "1" => "Clothing", "2" => "Armor");

our %BYDT_SKIN_TYPE = ('0' => "Normal", "1" => "Vampire");

our %CELL_FLAGS =
    (# "interior" => 0x01, # JMS - we print interior/exterior elsewise
     "has_water" => 0x02,
     "illegal_to_sleep_here" => 0x04,
     "behave_like_exterior" => 0x80);

our %CONTAINER_FLAGS =
    ("Organic" => 0x0001,
     "Respawns" => 0x0002,
     "Default" => 0x0008);

our %CREATURE_MOVEMENT_FLAGS =
    ("biped" => 0x0001,
     "movement:none"  => 0x0008,
     "swims" => 0x0010,
     "flies" => 0x0020,
     "walks" => 0x0040);

our %CREATURE_BLOOD_FLAGS =
    ("red_blood"         => 0x0000,
     "skeleton_blood"    => 0x0400,
     "metal_blood"       => 0x0800);

our %CREATURE_FLAGS =
    ("respawn"           => 0x0002,
     "weapon_and_shield" => 0x0004,
     "essential"         => 0x0080);

our %CREA_TYPE =
    ( 0 => 'Creature',
      1 => 'Daedra',
      2 => 'Undead',
      3 => 'Humanoid' );

our %CTDT_TYPE =
    (0 => "Pants",
     1 => "Shoes",
     2 => "Shirt",
     3 => "Belt",
     4 => "Robe",
     5 => "Right_Glove",
     6 => "Left_Glove",
     7 => "Skirt",
     8 => "Ring",
     9 => "Amulet");

our %DIAL_TYPE =
    (0 => "Topic",
     1 => "Voice",
     2 => "Greeting",
     3 => "Persuasion",
     4 => "Journal");

our %ENCHANT_TYPE =
    (0 => "Cast_Once",
     1 => "Cast_on_Strike",
     2 => "Cast_when_Used",
     3 => "Constant_Effect");

# Very odd, this, we do see all 4 values, but only the one bit is significant
our %ENDT_AUTO =
    (-2 => "No",
     -1 => "Yes",
     0 => "No",
     1 => "Yes");

our %FACT_FLAGS =
    ("hidden_from_player" => 0x1);

our %GLOBAL_TYPE =
    (s => 'Short',
     f => 'Float',
     l => 'Long');

our %INFO_FUN =
    ('00' => "Reaction_Low",
     '01' => "Reaction_High",
     '02' => "Rank_Requirement",
     '03' => "Reputation",
     '04' => "Health_Percent",
     '05' => "PC_Reputation",
     '06' => "PC_Level",
     '07' => "PC_Health_Percent",
     '08' => "PC_Magicka",
     '09' => "PC_Fatigue",

     '10' => "PC_Strength",
     '11' => "PC_Block",
     '12' => "PC_Armorer",
     '13' => "PC_Medium_Armor",
     '14' => "PC_Heavy_Armor",
     '15' => "PC_Blunt_Weapon",
     '16' => "PC_Long_Blade",
     '17' => "PC_Axe",
     '18' => "PC_Spear",
     '19' => "PC_Athletics",

     '20' => "PC_Enchant",
     '21' => "PC_Destruction",
     '22' => "PC_Alteration",
     '23' => "PC_Illusion",
     '24' => "PC_Conjuration",
     '25' => "PC_Mysticism",
     '26' => "PC_Restoration",
     '27' => "PC_Alchemy",
     '28' => "PC_Unarmored",
     '29' => "PC_Security",

     '30' => "PC_Sneak",
     '31' => "PC_Acrobatics",
     '32' => "PC_Light_Armor",
     '33' => "PC_Short_Blade",
     '34' => "PC_Marksman",
     '35' => "PC_Mercantile",
     '36' => "PC_Speechcraft",
     '37' => "PC_Hand_To_Hand",
     '38' => "PC_Sex",
     '39' => "PC_Expelled",

     '40' => "PC_Common_Disease",
     '41' => "PC_Blight_Disease",
     '42' => "PC_Clothing_Modifier",
     '43' => "PC_Crime_Level",
     '44' => "Same_Sex",
     '45' => "Same_Race",
     '46' => "Same_Faction",
     '47' => "Faction_Rank_Difference",
     '48' => "Detected",
     '49' => "Alarmed",

     '50' => "Choice",
     '51' => "PC_Intelligence",
     '52' => "PC_Willpower",
     '53' => "PC_Agility",
     '54' => "PC_Speed",
     '55' => "PC_Endurance",
     '56' => "PC_Personality",
     '57' => "PC_Luck",
     '58' => "PC_Corprus",
     '59' => "Weather",

     '60' => "PC_Vampire",
     '61' => "Level",
     '62' => "Attacked",
     '63' => "Talked_To_PC",
     '64' => "PC_Health",
     '65' => "Creature_Target",
     '66' => "Friend_Hit",
     '67' => "Fight",
     '68' => "Hello",
     '69' => "Alarm",

     '70' => "Flee",
     '71' => "Should_Attack",
     '72' => "Werewolf",
     '73' => "Werewolf_Kills",

     'CX' => "Not_Class",
     'DX' => "Dead_Type",
     'FX' => "Not_Faction",
     'IX' => "Item_Type",
     'JX' => "Journal_Type",
     'LX' => "Not_Cell",
     'RX' => "Not_Race",
     'XX' => "Not_ID_Type",
     'fX' => "Global",
     'lX' => "PCGold",
     '2X' => "Compare_Global",
     '3X' => "Compare_Local",
     'sX' => "Variable_Compare",
     "\000\000" => "\n\tERROR: Corrupted INFO! - did you edit with MWEdit? Try resaving with the Construction Set\n\t",
    );

our %INFO_SCVR_CMP =
    ('0' => '=',
     '1' => '!=',
     '2' => '>',
     '3' => '>=',
     '4' => '<',
     '5' => '<=');

our %INFO_SCVR_TYPE =
    ('0' => "Nothing",
     '1' => "Function",
     '2' => "Global",
     '3' => "Local",
     '4' => "Journal",
     '5' => "Item",
     '6' => "Dead",
     '7' => "Not_ID",
     '8' => "Not_Faction",
     '9' => "Not_Class",
     'A' => "Not_Race",
     'B' => "Not_Cell",
     'C' => "Not_Local");

our %LEVC_FLAGS =
    ("Calc_from_all_levels_<=_PC_level" => 1);

our %LEVI_FLAGS =
    ("Calc_from_all_levels_<=_PC_level" => 1,
     "Calc_for_each_item" => 2);

our %LHDT_FLAGS =
    ("dynamic" => 0x0001,
     "can_carry" => 0x0002,
     "negative" => 0x0004,
     "flicker" => 0x0008,
     "fire" => 0x0010,
     "off_default" => 0x0020,
     "flicker_slow" => 0x0040,
     "pulse" => 0x0080,
     "pulse_slow" => 0x0100);

our %MAGIC_SCHOOL =
    (0 => "Alteration",
     1 => "Conjuration",
     2 => "Destruction",
     3 => "Illusion",
     4 => "Mysticism",
     5 => "Restoration");

our %MGEF_FLAGS =
    ("spellmaking" => 0x0200,
     "enchanting" => 0x0400,
     "negative" => 0x0800);

our %NPC_FLAGS =
    ("female" => 0x0001,
     "essential" => 0x0002,
     "respawn" => 0x0004,
     #"FLAG-8" => 0x0008, #unused ???
     "autocalc" => 0x0010,
     "blood_skel" => 0x0400,
     "blood_metal" => 0x0800);

our %PLAYABLE =
    ( 0 => "Non-Playable",
      1 => "Playable" );

our %PGCOLOR =
    ( 0 => 'red',
      1 => 'blue' );

our %RADT_FLAGS =
    ("playable" => 0x01,
     "beast_race" => 0x02);

our %RANGE_TYPE =
    (-1 => "None",
     0 => "Self",
     1 => "Touch",
     2 => "Target");

our %HDR_FLAGS =
    ("deleted"     => 0x0020,
     "persistent"  => 0x0400,
     "ignored"     => 0x1000,
     "blocked"     => 0x2000);
# for convenience, we alias each symbolic flag name to its first letter:
$HDR_FLAGS{substr($_, 0, 1)} = $HDR_FLAGS{$_} foreach (keys %HDR_FLAGS);

our %SEX =
    (-1 => "None",
     0 => "Male",
     1 => "Female");

our %SKILL =
    (-1 => "None",
     0 => "Block",
     1 => "Armorer",
     2 => "Medium_Armor",
     3 => "Heavy_Armor",
     4 => "Blunt_Weapon",
     5 => "Long_Blade",
     6 => "Axe",
     7 => "Spear",
     8 => "Athletics",
     9 => "Enchant",
     10 => "Destruction",
     11 => "Alteration",
     12 => "Illusion",
     13 => "Conjuration",
     14 => "Mysticism",
     15 => "Restoration",
     16 => "Alchemy",
     17 => "Unarmored",
     18 => "Security",
     19 => "Sneak",
     20 => "Acrobatics",
     21 => "Light_Armor",
     22 => "Short_Blade",
     23 => "Marksman",
     24 => "Mercantile",
     25 => "Speechcraft",
     26 => "Hand_To_Hand");

our %SKILL_ACTIONS =
    (0 => [qw(Successful_Block)],		 # Block
     1 => [qw(Successful_Repair)],		 # Armorer
     2 => [qw(Hit_By_Opponent)],		 # Medium Armor
     3 => [qw(Hit_By_Opponent)],		 # Heavy Armor
     4 => [qw(Successful_Attack)],		 # Blunt Weapon
     5 => [qw(Successful_Attack)],		 # Long Blade
     6 => [qw(Successful_Attack)],		 # Axe
     7 => [qw(Successful_Attack)],		 # Spear
     8 => [qw(Second_of_Running Second_of_Swimming)], # Athletics
     9 => [qw(Recharge_Item Use_Magic_Item Create_Magic_Item Cast_When_Strikes)], # Enchant
     10 => [qw(Successful_Cast)],		 # Destruction
     11 => [qw(Successful_Cast)],		 # Alteration
     12 => [qw(Successful_Cast)],		 # Illusion
     13 => [qw(Successful_Cast)],		 # Conjuration
     14 => [qw(Successful_Cast)],		 # Mysticism
     15 => [qw(Successful_Cast)],		 # Restoration
     16 => [qw(Potion_Creation Ingredient_Use)], # Alchemy
     17 => [qw(Hit_By_Opponent)],		 # Unarmored
     18 => [qw(Defeat_Trap Pick_Lock)],		 # Security
     19 => [qw(Avoid_Notice Successful_Pickpocket)],	  # Sneak
     20 => [qw(Jump Fall)],			 # Acrobatics
     21 => [qw(Hit_By_Opponent)],		 # Light Armor
     22 => [qw(Successful_Attack)],		 # Short Blade
     23 => [qw(Successful_Attack)],		 # Marksman
     24 => [qw(Successful_Bargain Successful_Bribe)],	  # Mercantile
     25 => [qw(Cuccessful_Persuasion Failed_Persuasion)], # Speechcraft
     26 => [qw(Successful_Attack)]);		 # Hand to Hand

our %SNDG_DATA =
    (0 => "Left_Foot",
     1 => "Right_Foot",
     2 => "Swim_Left",
     3 => "Swim_Right",
     4 => "Moan",
     5 => "Roar",
     6 => "Scream",
     7 => "Land");

our %SPECIALIZATION =
    (0 => "Combat",
     1 => "Magic",
     2 => "Stealth");

our %SPEL_FLAGS =
    ("autocalc" => 0x0001,
     "pc_start" => 0x0002,
     "always_succeeds" => 0x0004);

our %SPEL_TYPE =
    (0 => "Spell",
     1 => "Ability",
     2 => "Blight",
     3 => "Disease",
     4 => "Curse",
     5 => "Power");

our %SPELL_EFFECT =
    ('-1' => 'NONE',
     '0' => "Water_Breathing",
     '1' => "Swift_Swim",
     '2' => "Water_Walking",
     '3' => "Shield",
     '4' => "Fire_Shield",
     '5' => "Lightning_Shield",
     '6' => "Frost_Shield",
     '7' => "Burden",
     '8' => "Feather",
     '9' => "Jump",
     '10' => "Levitate",
     '11' => "Slowfall",
     '12' => "Lock",
     '13' => "Open",
     '14' => "Fire_Damage",
     '15' => "Shock_Damage",
     '16' => "Frost_Damage",
     '17' => "Drain_Attribute",
     '18' => "Drain_Health",
     '19' => "Drain_Magicka",
     '20' => "Drain_Fatigue",
     '21' => "Drain_Skill",
     '22' => "Damage_Attribute",
     '23' => "Damage_Health",
     '24' => "Damage_Magicka",
     '25' => "Damage_Fatigue",
     '26' => "Damage_Skill",
     '27' => "Poison",
     '28' => "Weakness_to_Fire",
     '29' => "Weakness_to_Frost",
     '30' => "Weakness_to_Shock",
     '31' => "Weakness_to_Magicka",
     '32' => "Weakness_to_Common_Disease",
     '33' => "Weakness_to_Blight_Disease",
     '34' => "Weakness_to_Corprus_Disease",
     '35' => "Weakness_to_Poison",
     '36' => "Weakness_to_Normal_Weapons",
     '37' => "Disintegrate_Weapon",
     '38' => "Disintegrate_Armor",
     '39' => "Invisibility",
     '40' => "Chameleon",
     '41' => "Light",
     '42' => "Sanctuary",
     '43' => "Night_Eye",
     '44' => "Charm",
     '45' => "Paralyze",
     '46' => "Silence",
     '47' => "Blind",
     '48' => "Sound",
     '49' => "Calm_Humanoid",
     '50' => "Calm_Creature",
     '51' => "Frenzy_Humanoid",
     '52' => "Frenzy_Creature",
     '53' => "Demoralize_Humanoid",
     '54' => "Demoralize_Creature",
     '55' => "Rally_Humanoid",
     '56' => "Rally_Creature",
     '57' => "Dispel",
     '58' => "Soultrap",
     '59' => "Telekinesis",
     '60' => "Mark",
     '61' => "Recall",
     '62' => "Divine_Intervention",
     '63' => "Almsivi_Intervention",
     '64' => "Detect_Animal",
     '65' => "Detect_Enchantment",
     '66' => "Detect_Key",
     '67' => "Spell_Absorption",
     '68' => "Reflect",
     '69' => "Cure_Common_Disease",
     '70' => "Cure_Blight_Disease",
     '71' => "Cure_Corprus_Disease",
     '72' => "Cure_Poison",
     '73' => "Cure_Paralyzation",
     '74' => "Restore_Attribute",
     '75' => "Restore_Health",
     '76' => "Restore_Magicka",
     '77' => "Restore_Fatigue",
     '78' => "Restore_Skill",
     '79' => "Fortify_Attribute",
     '80' => "Fortify_Health",
     '81' => "Fortify_Magicka",
     '82' => "Fortify_Fatigue",
     '83' => "Fortify_Skill",
     '84' => "Fortify_Maximum_Magicka",
     '85' => "Absorb_Attribute",
     '86' => "Absorb_Health",
     '87' => "Absorb_Magicka",
     '88' => "Absorb_Fatigue",
     '89' => "Absorb_Skill",
     '90' => "Resist_Fire",
     '91' => "Resist_Frost",
     '92' => "Resist_Shock",
     '93' => "Resist_Magicka",
     '94' => "Resist_Common_Disease",
     '95' => "Resist_Blight_Disease",
     '96' => "Resist_Corprus_Disease",
     '97' => "Resist_Poison",
     '98' => "Resist_Normal_Weapons",
     '99' => "Resist_Paralysis",
     '100' => "Remove_Curse",
     '101' => "Turn_Undead",
     '102' => "Summon_Scamp",
     '103' => "Summon_Clannfear",
     '104' => "Summon_Daedroth",
     '105' => "Summon_Dremora",
     '106' => "Summon_Ancestral_Ghost",
     '107' => "Summon_Skeltal_Minion",
     '108' => "Summon_Bonewalker",
     '109' => "Summon_Greater_Bonewalker",
     '110' => "Summon_Bonelord",
     '111' => "Summon_Winged_Twilight",
     '112' => "Summon_Hunger",
     '113' => "Summon_Golden_Saint",
     '114' => "Summon_Flame_Atronach",
     '115' => "Summon_Frost_Atronach",
     '116' => "Summon_Storm_Atronach",
     '117' => "Fortify_Attack",
     '118' => "Command_Creature",
     '119' => "Command_Humanoid",
     '120' => "Bound_Dagger",
     '121' => "Bound_Longsword",
     '122' => "Bound_Mace",
     '123' => "Bound_Battle_Axe",
     '124' => "Bound_Spear",
     '125' => "Bound_Longbow",
     '126' => "EXTRA_SPELL",
     '127' => "Bound_Cuirass",
     '128' => "Bound_Helm",
     '129' => "Bound_Boots",
     '130' => "Bound_Shield",
     '131' => "Bound_Gloves",
     '132' => "Corprus",
     '133' => "Vampirism",
     '134' => "Summon_Centurion_Spider",
     '135' => "Sun_Damage",
     '136' => "Stunted_Magicka",
     '137' => "Summon_Fabricant",
     '138' => "Call_Wolf",
     '139' => "Call_Bear",
     '140' => "Summon_Bonewolf",
     '141' => "sEffectSummonCreature04",
     '142' => "sEffectSummonCreature05",
    );

our %SPLM_TYPE =
    (1 => "Spell",
     2 => "Enchantment");

our %TRUTH =
    ( 0 => "False",
      1 => "True");

our %WEAPON_FLAGS =
    ("[ignores_normal_weapon_resistance]" => 1);

our %WEAPON_TYPE =
    (0 => "ShortBladeOneHand",
     1 => "LongBladeOneHand",
     2 => "LongBladeTwoClose",
     3 => "BluntOneHand",
     4 => "BluntTwoClose",
     5 => "BluntTwoWide",
     6 => "SpearTwoWide",
     7 => "AxeOneHand",
     8 => "AxeTwoHand",
     9 => "MarksmanBow",
     10 => "MarksmanCrossbow",
     11 => "MarksmanThrown",
     12 => "Arrow",
     13 => "Bolt");

our %YESNO =
    ( 0 => "No",
      1 => "Yes");

### END OF TES3


### CLASS: TES3::Record

package TES3::Record;

BEGIN {
    use constant DBG => grep(/^(?:-d|-?-debug)$/, @ARGV);
    use constant ASSERT => grep(/^-?-assert$/, @ARGV);
    use constant WRAP => grep(/^-?-wrap$/, @ARGV);
    use constant VERBOSE => (DBG or grep(/^(?:-v|-?-verbose)$/, @ARGV)); # debug turns on verbosity
    Util->import(qw(abort assert dbg err msg msgonce prn));
}
use Text::Wrap qw(wrap);
use Data::Dumper;
use strict;

our $CODEC_VERSION = "0.3";
our $MARGIN = "  ";
our $GROUPMARGIN = " *";
our $CURRENT_DIAL;
our $CURRENT_GROUP;
#our %FACTION_INDEX;
#our $FACT_I = 0;
our %FACTION_RANK;
our %RECTYPES;

### RECORD DEFINITIONS

sub unknown_data {
    my($buf) = @_;
    my $len = length($buf);
    if ($len > 4) {
	my $sep = ($len < 25) ? "  " : "\n\t";
	(my $tmp = $buf) =~ tr/\000-\037\177-\377//d;
	return(sprintf("[UNKNOWN_DATA: len:%d${sep}hex:%s${sep}str:%s]",
		       $len, unpack("H*", $buf),
		       substr($tmp, 0, 80)));
    } elsif ($len == 4) {
	return(sprintf(qq{[UNKNOWN_WORD: 0x%s f:%0.2f  l:%d  (s:%d %d)  (c:%d %d %d %d)]},
		       unpack("H8", $buf), unpack("f", $buf), unpack("l", $buf),
		       unpack("s2", $buf), unpack("c4", $buf)));
    } elsif ($len > 1) {
	my(@chars) = unpack("c*", $buf);
	return(sprintf(qq{[UNKNOWN_BYTES: 0x%s (${[join(", ",map{"%d"}@chars)]})]},
		       unpack("H*", $buf), @chars));
    } elsif ($len == 1) {
	return(sprintf(qq{[UNKNOWN_BYTE: 0x%s (%d)]}, unpack("H*", $buf), unpack("c", $buf)));
    } else {
	return("UNKNOWN_NULL: (received zero length buffer)");
    }
}

my @RD_reference =
    ( decode => sub {
	  my($self, $buff, $parent) = @_;
	  $self->{_id_} = $parent->{_id_};
	  $self->{_subbuf_} = $buff;
	  my($idx) = unpack("L", $buff);
	  $self->{objidx} = ($idx & 0xFFFFFF);
	  $self->{mastidx} = ($idx >> 24);
	  return($self);
      },
      encode => sub {
	  my($self) = @_;
	  $self->{_subbuf_} = pack("L", ($self->{objidx} | ($self->{mastidx} << 24)));
	  return($self);
      },
      tostr => sub {
	  my($self) = @_;
	  qq{ObjIdx:$self->{objidx}  MastIdx:$self->{mastidx}};
      }
    );

my @RD_float_array_ess =
    ([], { decode => sub {
	       my($self, $buff) = @_;
	       $self->{_subbuf_} = $buff;
	       $self->{_array_} = [unpack("f*", $buff)];
	       return($self);
	   },
	   encode => sub {
	       my($self) = @_;
	       $self->{_subbuf_} = pack("f*", @{$self->{_array_}});
	       return($self);
	   },
	   #fieldnames => sub { (0..$_[0]->{_last_idx}); }, # NOTYET (and implement ordering)
	   tostr => sub {
	       my($self) = @_;
	       "Float_Array: " . join(", ", map { sprintf("$_=%0.2f", $_) } @{$self->{_array_}});
	   },
	   rdflags => [qw(ess)]});

my @RD_long_array_ess =
    ([], { decode => sub {
	       my($self, $buff) = @_;
	       $self->{_subbuf_} = $buff;
	       $self->{_array_} = [unpack("l*", $buff)];
	       return($self);
	   },
	   encode => sub {
	       my($self) = @_;
	       $self->{_subbuf_} = pack("l*", @{$self->{_array_}});
	       return($self);
	   },
	   #fieldnames => sub { (0..$_[0]->{_last_idx}); }, # NOTYET (and implement ordering)
	   tostr => sub {
	       my($self) = @_;
	       "Long_Array: " . join(", ", @{$self->{_array_}});
	   },
	   rdflags => [qw(ess)]});

my @RD_short_array_ess =
    ([], { decode => sub {
	       my($self, $buff) = @_;
	       $self->{_subbuf_} = $buff;
	       $self->{_array_} = [unpack("s*", $buff)];
	       return($self);
	   },
	   encode => sub {
	       my($self) = @_;
	       $self->{_subbuf_} = pack("s*", @{$self->{_array_}});
	       return($self);
	   },
	   #fieldnames => sub { (0..$_[0]->{_last_idx}); }, # NOTYET (and implement ordering)
	   tostr => sub {
	       my($self) = @_;
	       "Short_Array: " . join(", ", @{$self->{_array_}});
	   },
	   rdflags => [qw(ess)]});

my @RD_widx = ([["equipped_index", "l"], # JMS index into NPCO inventory items of those that are equipped
		["ammo_flag", "l"]],
	       { tostr => sub {
		     my($self) = @_;
		     sprintf("Equipped_Index:%d%s", $self->{equipped_index},
			     ($self->{ammo_flag} == 0) ? "" : " (Ammo)");
		 },
	       });


# Note: fieldnames that end in "_#" will get an automatically generated suffix_index
my @RD_AI_Activate = ([["target_id", ["Z32", "a32"]], ["unknown_#", "C"]]);
my @RD_AI_Travel = ([["x", "f"], ["y", "f"], ["z", "f"], ["unknown_#", "l"]]); # unknown is some sort of flags ???
my @RD_AI_Escort = ([["x", "l"], ["y", "l"], ["z", "l"], ["duration", "S"], ["target_id", ["Z32", "a32"]], ["unknown_#", "S"]]);
my @RD_AI_Follow = @RD_AI_Escort;
my @RD_AI_Wander_CREA = ([["distance", "S"], ["duration", "C"], ["time_of_day", "C"], ["unknown_#", "C"], 
			  ["idle_2", "C"], ["idle_3", "C"], ["idle_4", "C"], ["idle_5", "C"], ["idle_6", "C"], ["idle_7", "C"], ["idle_8", "C"], ["idle_9", "C"],
			  ["unknown_#", "C"]], { columns => 4 });
my @RD_AI_Wander_NPC = ([["distance", "S"], ["duration", "S"], ["time_of_day", "C"],
			 ["idle_2", "C"], ["idle_3", "C"], ["idle_4", "C"], ["idle_5", "C"], ["idle_6", "C"], ["idle_7", "C"], ["idle_8", "C"], ["idle_9", "C"],
			 ["unknown_#", "C"]], { columns => 3 });

my $RD_Actor_Data =
#     Field                              Offset
    [(["unknown_#", "l"],	       #   0
      ["unknown_#", "l"],	       #   4
      ["unknown_#", "l"],	       #   8
      ["unknown_#", "l"],	       #  12
      ["unknown_#", "f:%f\n\t"],       #  16
      ["x?", "f"],	       #  20
      ["y?", "f"],	       #  24
      ["z?", "f"],	       #  28
      ["unknown_#", "l"],	       #  32
      ["unknown_#", "l:%d\n\t"],       #  36
      ["health", "f"],		       #  40
      ["max_health", "f"],	       #  44
      ["fatigue", "f"],		       #  48
      ["max_fatigue", "f:%0.2f\n\t"],  #  52
      ["unknown_#", "f"],	       #  56
      ["unknown_#", "f"],	       #  60
      ["unknown_#", "f"],	       #  64
      ["unknown_#", "f"],	       #  68
      ["unknown_#", "f:%0.2f\n\t"],    #  72
      ["encumbrance", "f"],	       #  76
      ["str", "f"],		       #  80
      ["str_base", "f"],	       #  84
      ["int", "f"],		       #  88
      ["int_Base", "f:%0.2f\n\t"],     #  92
      ["wil", "f"],		       #  96
      ["wil_base", "f"],	       # 100
      ["agi", "f"],		       # 104
      ["agi_base", "f:%0.2f\n\t"],     # 108
      ["spd", "f"],		       # 112
      ["spd_base", "f"],	       # 116
      ["end", "f"],		       # 120
      ["end_base", "f:%0.2f\n\t"],     # 124
      ["per", "f"],		       # 128
      ["per_base", "f"],	       # 132
      ["luc", "f"],		       # 136
      ["luc_base", "f:%0.2f\n\t"],     # 140
      ["fortify_attack", "L"],	       # 144
      ["sanctuary", "L"],	       # 148
      ["resist_magicka", "C"],	       # 152
      ["unknown_#", "H6:%s\n\t"],
      ["resist_fire", "C"],	# 156 (+ Fire Shield)
      ["unknown_#", "H6"],
      ["resist_frost", "C"],	# 160 (+ Frost Shield)
      ["unknown_#", "H6:%s\n\t"],
      ["resist_shock", "C"],	# 164 (+ Lightning Shield)
      ["unknown_#", "H6"],
      ["resist_common_disease", "L"],		   # 168
      ["unknown_#", "L:%d\n\t"],		   # 172
      ["unknown_#", "L"],			   # 176
      ["resist_poison", "L"],			   # 180
      ["resist_paralysis", "L"],		   # 184
      ["chameleon", "L:%d\n\t"],		   # 188
      ["resist_normal_weapons", "L"],		   # 192
      ["water_breathing", "L"],			   # 196
      ["water_walking", "L"],			   # 200
      ["swift_swim", "L:%d\n\t"],		   # 204
      ["unknown_#", "L"],			   # 208
      ["levitate", "L"],			   # 212
      ["shield", "L"],				   # 216
      ["unknown_#", "L"],			   # 220
      ["unknown_#", "L"],			   # 224
      ["blind", "L:%d\n\t"],			   # 228
      ["unknown_#", "L"],			   # 232
      ["invisibility", "L"],			   # 236
      ["unknown_#", "L"],			   # 240
      ["unknown_#", "L:%d\n\t"],		   # 244
      ["unknown_#", "L"],			   # 248
      ["unknown_#", "L"],			   # 252
      ["unknown_#", "L"],			   # 256
      ["unknown_#", "L"])];

my @RD_Enchantment =
    ([["spell_effect", "s"], ["skill", "c"], ["attribute", "c"], ["range", "c"], ["Unused", "H6"],
      ["area", "L"], ["duration", "L"], ["mag_min", "L"], ["mag_max", "L"]],
     { tostr => sub {
	   my($self) = @_;
	   if (DBG and (not defined $SPELL_EFFECT{$self->{spell_effect}})) {
	       err(qq{unknown spell effect: "$self->{spell_effect}"});
	   }
	   my $spell = $SPELL_EFFECT{$self->{spell_effect}};
	   if ($spell =~ /_attribute$/i) {
	       $spell .= "/$ATTRIBUTE{$self->{attribute}}";
	   } elsif ($spell =~ /_skill$/i) {
	       $spell .= "/$SKILL{$self->{skill}}";
	   }
	   sprintf "Spell_Effect:(%s)  Range:(%s)  Area:%d  Duration:%d  Mag_Min:%d  Mag_Max:%d",
	       $spell, $RANGE_TYPE{$self->{range}}, $self->{area}, $self->{duration}, $self->{mag_min}, $self->{mag_max}
	   }});

my @RD_Unknown = ([["unknown_#", "H*"]], { tostr => sub { unknown_data($_[0]->{_subbuf_}); } });
my @RD_Unknown_ess = ([["unknown_#", "H*"]],
		      { tostr => sub { unknown_data($_[0]->{_subbuf_}); },
			rdflags => [qw(ess)] });

my @RD_Description = ([["description", "a*"]],
		      { tostr => sub {
			    my $str = "Description:".$_[0]->{description};
			    $str =~ tr/\r//d if ($^O eq 'linux');
			    (WRAP) ? wrap("","\t", $str) : $str;
			},
		      });


my %RDFLAGS;
my %COLUMNS;

# The global %FORMAT_INFO holds some formatting metadata for printing records
my %FORMAT_INFO;
$FORMAT_INFO{CLAS}->{CLDT}->{minor_skill_1}->{BOL} = 1;
$FORMAT_INFO{CREA}->{NPDT}->{attack_min_1}->{BOL} = 1;
$FORMAT_INFO{CREA}->{NPDT}->{attack_min_2}->{BOL} = 1;
$FORMAT_INFO{CREA}->{NPDT}->{attack_min_3}->{BOL} = 1;
$FORMAT_INFO{CREA}->{NPDT}->{gold}->{BOL} = 1;
$FORMAT_INFO{CREA}->{NPDT}->{str}->{BOL} = 1;

# The global %TYPE_INFO defines record metadata, like grouping and merging strategy
# The following record types can be merged
my %TYPE_INFO = map {$_,{canmerge=>1}}
    (qw(ACTI ALCH APPA ARMO BODY BOOK BSGN CLAS CLOT CONT CREA DOOR ENCH FACT
	INGR LIGH LOCK MGEF MISC NPC_ PROB REGN REPA SKIL SOUN SPEL WEAP));
# The following subtypes can be merged on individual fields:
# each of these subtypes occurs only once per record
foreach (qw(ALCH.ALDT APPA.AADT ARMO.AODT BOOK.BKDT CLOT.CTDT CREA.AIDT CREA.NPDT
	    ENCH.ENDT LIGH.LHDT LOCK.LKDT MGEF.MEDT MISC.MCDT NPC_.AIDT NPC_.NPDT
	    PROB.PBDT REPA.RIDT SPEL.SPDT WEAP.WPDT)) {
    my($rectype, $subtype) = split(/\./);
    $TYPE_INFO{$rectype}->{mergefields}->{$subtype} = 1;
}
# The following subtypes are treated as a list of groups
# each group can contain one or more subtypes.
# an example of a list of a single type would be NPC_.NPCO subrecords
# which are the list of objects carried by an NPC.
# format is: RECTYPE.SUBTYPE(groupstart)[.SUBTYPE(groupmember)]*
# groups/lists need special handling during merging
# most groups are definitely explicitly by the possible subtypes of their member subrecords
# but CELL groups are complex and ANY subrecord following an FRMR belongs to that group
# this is marked with "*" below
foreach (qw( ALCH.ENAM
	     ARMO.INDX.BNAM.CNAM
	     BSGN.NPCS
	     CLOT.INDX.BNAM.CNAM
	     CONT.NPCO
	     CELL.FRMR.*
	     CREA.AI_T
	     CREA.AI_W
	     CREA.DODT.DNAM
	     CREA.NPCO
	     CREA.NPCS
	     CREC.NPCO
	     ENCH.ENAM
	     FACT.ANAM.INTV
	     FACT.RNAM
	     INFO.SCVR.INTV.FLTV
	     KLST.KNAM.CNAM
	     LEVC.CNAM.INTV
	     LEVI.INAM.INTV
	     NPC_.AI_T
	     NPC_.AI_W
	     NPC_.DODT.DNAM
	     NPC_.NPCO
	     NPC_.NPCS
	     NPCC.NPCO
	     RACE.NPCS
	     REGN.SNAM
	     SPEL.ENAM
	     SPLM.NAME
	     TES3.MAST.DATA
	  )) {
    my($rectype, $groupstart, @groupmembers) = split(/\./);
    $TYPE_INFO{$rectype}->{group}->{$groupstart}->{start} = 1;
    $TYPE_INFO{$rectype}->{group}->{$groupstart}->{member}->{$groupstart} = 1;
    foreach (@groupmembers) {
	if ($_ eq '*') {
	    $TYPE_INFO{$rectype}->{groupall}->{$groupstart} = 1;
	} else {
	    $TYPE_INFO{$rectype}->{group}->{$_}->{member}->{$groupstart} = 1;
	}
    }
}
# The following subtypes can be merged as group lists
foreach (qw(CONT.NPCO CREA.DODT.DNAM CREA.NPCO CREA.NPCS NPC_.DODT NPC_.NPCO NPC_.NPCS)) {
    my($rectype, $subtype) = split(/\./);
    $TYPE_INFO{$rectype}->{mergegroup}->{$subtype} = 1;
}



#warn "DBG:".Dumper(\%TYPE_INFO)."\n";

# Note: fieldnames that end in _# will get an automatically generated suffix_index
my @RECDEFS =
    (
     [ACTI => [
	       [NAME => [["id", "Z*"]]],
	       [FNAM => [["name", "Z*"]]],
	       [MODL => [["model", "Z*"]]],
	       [SCRI => [["script", "Z*"]]],
	      ]],
     [ALCH => [
	       [NAME => [["id", "Z*"]]],
	       [ALDT => [["weight", "f"], ["value", "L"], ["autocalc", "L", { lookup => \%YESNO }]]],
	       [ENAM => @RD_Enchantment],
	       [FNAM => [["name", "Z*"]]],
	       [MODL => [["model", "Z*"]]],
	       [SCRI => [["script", "Z*"]]],
	       [TEXT => [["icon", "Z*"]]],
	      ]],
     [APPA => [
	       [NAME => [["id", "Z*"]]],
	       [AADT => [["type", "L", { lookup => \%APPARATUS_TYPE }],
			 ["quality", "f"], ["weight", "f"], ["value", "L"]]],
	       [FNAM => [["name", "Z*"]]],
	       [ITEX => [["icon", "Z*"]]],
	       [MODL => [["model", "Z*"]]],
	       [SCRI => [["script", "Z*"]]],
	      ]],
     [ARMO => [
	       [NAME => [["id", "Z*"]]],
	       [AODT => [["type", "L", { lookup => \%ARMOR_TYPE }], ["weight", "f"], ["value", "L"], ["health", "L"],
			 ["enchantment", "L"], ["ar", "L"]],
		{ tostr => sub {
		      my($self) = @_;
		      my $weight_class =
			  ($self->{weight} > $ARMOR_CLASS{$self->{type}}->{medium}) ? "Heavy" :
			      ($self->{weight} > $ARMOR_CLASS{$self->{type}}->{light}) ? "Medium" :
				  "Light";
		      sprintf("Type:(%s)  Weight:%0.2f ($weight_class)  Value:%d  Health:%d  Enchantment:%d  AR:%d",
			      $ARMOR_TYPE{$self->{type}}, $self->{weight}, $self->{value},
			      $self->{health}, $self->{enchantment}, $self->{ar});
		  }}],
	       [BNAM => [["male_body_id", ["Z*", "a*"]]]],
	       [CNAM => [["female_body_id", "a*"]]],
	       [ENAM => [["enchanting", "Z*"]]],
	       [FNAM => [["name", "Z*"]]],
	       [INDX => [["part_index", "C", { lookup => \%ARMOR_INDEX }]]],
	       [ITEX => [["icon", "Z*"]]],
	       [MODL => [["model", "Z*"]]],
	       [SCRI => [["script", "Z*"]]],
	      ]],
     [BODY => [
	       [NAME => [["id", "Z*"]]],
	       [BYDT => [["part", "C", { lookup => \%BYDT_PART }],
			 ["skin_type", "C", { lookup => \%BYDT_SKIN_TYPE }],
			 ["flags", "C", { symflags => \%BYDT_FLAGS }],
			 ["part_type", "C", { lookup => \%BYDT_PTYP }]]],
	       [FNAM => [["skin_race", "Z*"]]],
	       [MODL => [["model", "Z*"]]],
	      ]],
     [BOOK => [
	       [NAME => [["id", "Z*"]]],
	       [BKDT => [["weight", "f"], ["value", "L"], ["scroll", "L", { lookup => \%YESNO }],
			 ["teaches", "l", { lookup => \%SKILL }], ["enchantment", "L"]]],
	       [ENAM => [["enchanting", "Z*"]]],
	       [FNAM => [["name", "Z*"]]],
	       [ITEX => [["icon", "Z*"]]],
	       [MODL => [["model", "Z*"]]],
	       [SCRI => [["script", "Z*"]]],
	       [TEXT => [["text", "a*"]],
		{ tostr => sub {
		      my $str = $_[0]->{text};
		      $str =~ tr/\r//d if ($^O eq 'linux');
		      (WRAP) ? wrap("","\t", "Text:$str") : "Text:$str";
		  },
		}],
	      ]],
     [BSGN => [
	       [NAME => [["id", "Z*"]]],
	       [DESC => @RD_Description],
	       [FNAM => [["name", "Z*"]]],
	       [NPCS => [["spell", ["Z32", "a32"]]]], # Spells
	       [TNAM => [["image", "Z*"]]]
	      ]],
     [CELL => [
	       [AADT => @RD_Unknown_ess],
	       [AMBI => [["ambient", "L"], ["sunlight", "L"], ["fog", "L"], ["fog_density", "f"]],
		{ tostr => sub {
		      my($self) = @_;
		      join("  ", map { ucfirst($_) . ':' . color_tostr($self->{$_}) } (qw(ambient sunlight fog))) .
			  sprintf(" Fog_Density:%0.2f", $self->{fog_density});
		  }}
	       ],
	       [FRMR => [],	# "form reference"?
		{ @RD_reference }],
	       [ANAM => [["owner_actor", "Z*"]]],
	       [BNAM => [["global", "Z*"]]],

	       # CELL.CNAM
	       # - in FRMR group: is Owner Faction of object
	       # - in MVRF group: is Internal CELL Destination
	       [CNAM => [],
		{
		 decode => sub {
		     my($self, $buff, $parent) = @_;
		     $self->{_id_} = $parent->{_id_};
		     $self->{_subbuf_} = $buff;
		     if ($CURRENT_GROUP eq 'FRMR') {
			 $self->{owner_faction} = unpack("Z*", $buff);
		     } elsif ($CURRENT_GROUP eq 'MVRF') {
			 $self->{cell_destination} = unpack("Z*", $buff);
		     } else {
			 $self->{"unknown_#"} = unpack("H*", $buff);
		     }
		     return($self);
		 },
		 encode => sub {
		     my($self) = @_;
		     if (exists $self->{owner_faction}) {
			 $self->{_subbuf_} = pack("Z*", $self->{owner_faction});
		     } elsif (exists $self->{cell_destination}) {
			 $self->{_subbuf_} = pack("Z*", $self->{cell_destination});
		     } else {
			 $self->{_subbuf_} = pack("H*", $self->{unknown_1});
		     }
		     return($self);
		 },
		 tostr => sub {
		     my($self) = @_;
		     if (exists $self->{owner_faction}) {
			 sprintf("Owner_Faction:%s", $self->{owner_faction});
		     } elsif (exists $self->{cell_destination}) {
			 sprintf("Cell_Destination:%s (Internal)", $self->{cell_destination});
		     } else {
			 unknown_data($self->{_subbuf_})
		     }
		 },
		}],

	       [CNDT => [["x", "l"], ["y", "l"]],
		{ tostr => sub { sprintf ("X:$_[0]->{x}  Y:$_[0]->{y} (External Cell Destination)"); },
		}], # With MVRF is External CELL Destination
	       [DATA => [],
		{
		 decode => sub {
		     my($self, $buff, $parent) = @_;
		     $self->{_id_} = $parent->{_id_};
		     $self->{_subbuf_} = $buff;
		     my $blen = length($buff);
		     if ($blen == 24) {
			 ($self->{x}, $self->{y}, $self->{z},
			  $self->{x_angle}, $self->{y_angle}, $self->{z_angle}) = unpack("f6", $buff);
		     } elsif ($blen == 12) {
			 my($flags, $unk, $fogden) = unpack("LLf", $buff);
			 if ($flags & 0x01) { # Interior
			     $parent->{_is_interior_} = 1;
			     $self->{flags} = $flags;
			     $self->{unknown} = $unk;
			     $self->{fog_density} = $fogden;
			 } else { # Exterior
			     $parent->{_is_interior_} = 0;
			     $self->{flags} = $flags;
			     ($self->{x}, $self->{y}) = unpack("x[L]ll", $buff);
			 }
		     } else {
			 err("DECODER barfed on CELL.DATA, Invalid length: $blen, expected 24 or 12!");
		     }
		     return($self);
		 },
		 encode => sub {
		     my($self) = @_;
		     if (exists $self->{flags}) {
			 if ($self->{flags} & 0x01) { # Interior
			     $self->{_subbuf_} = pack("LLf", $self->{flags}, $self->{unknown}, $self->{fog_density});
			 } else { # Exterior
			     $self->{_subbuf_} = pack("Lll", $self->{flags}, $self->{x}, $self->{y});
			 }
		     } else {
			 $self->{_subbuf_} = pack("f6", $self->{x}, $self->{y}, $self->{z},
						  $self->{x_angle}, $self->{y_angle}, $self->{z_angle});
		     }
		     return($self);
		 },
		 #fieldnames => sub { grep {!/^_/} keys %{$_[0]}; }, # NOTYET check this works (and implement ordering)
		 tostr => sub {
		     my($self) = @_;
		     if (exists $self->{flags}) {
			 if ($self->{flags} & 0x01) { # Interior
			     # we don't print $self->{unknown} as it is really unused
			     sprintf("(Interior) Fog_Density:%0.2f  Flags:%s",
				     $self->{fog_density}, flags_tostr($self->{flags}, \%CELL_FLAGS));
			 } else {
			     sprintf("(Exterior) Coordinates: (%d, %d)  Flags:%s",
				     $self->{x}, $self->{y}, flags_tostr($self->{flags}, \%CELL_FLAGS));
			 }
		     } else {
			 sprintf("X:%0.3f  Y:%0.3f  Z:%0.3f  X_Angle:%0.4f  Y_Angle:%0.4f  Z_Angle:%0.4f",
				 $self->{x}, $self->{y}, $self->{z}, $self->{x_angle}, $self->{y_angle}, $self->{z_angle});
		     }
		 },
		}],
	       [DNAM => [["destination", "Z*"]]],
	       [DODT => [["x", "f"], ["y", "f"], ["z", "f"], ["x_angle", "f"], ["y_angle", "f"], ["z_angle", "f"]]],
	       [FLTV => [["lock_level", "L"]]],
	       [INDX => @RD_Unknown], # seems to only coincide with CNAM(Owner_Faction) subrecords

	       # CELL.INTV: (this is a bit of hairy situation)
	       # if in CELL Header, this is old way of specifying "Water_Height"
	       # if in FRMR, it's an item's unsigned short "Health_Left"
	       # or if item is LIGH, it's the float "Time_Left"
	       # it is other things too, such as some value for NPCS
	       [INTV => [],
		{
		 decode => sub {
		     my($self, $buff, $parent) = @_;
		     $self->{_id_} = $parent->{_id_};
		     $self->{_subbuf_} = $buff;
		     if ($CURRENT_GROUP) { # FRMR reference
			 my $val = unpack("l", $buff);
			 if ($val < 0 or $val > 65536) {
			     $val = unpack("f", $buff);
			     $self->{time_left} = $val;
			 } else {
			     $self->{health_left} = $val;
			 }
		     } else { 	# before any group, so in CELL header
			 $self->{water_height} = unpack("l", $buff);
		     }
		     return($self);
		 },
		 encode => sub {
		     my($self) = @_;
		     if (exists $self->{health_left}) {
			 $self->{_subbuf_} = pack("l", $self->{health_left});
		     } elsif (exists $self->{time_left}) {
			 $self->{_subbuf_} = pack("f", $self->{time_left});
		     } else {
			 $self->{_subbuf_} = pack("l", $self->{water_height});
		     }
		     return($self);
		 },
		 tostr => sub {
		     my($self) = @_;
		     if (exists $self->{health_left}) {
			 sprintf("Health_Left:%d", $self->{health_left});
		     } elsif (exists $self->{time_left}) {
			 sprintf("Time_Left:%0.2f", $self->{time_left});
		     } else {
			 sprintf("Water_Height:%d", $self->{water_height});
		     }
		 },
		}],

	       [KNAM => [["key", "Z*"]]],
	       [NAM0 => [["reference_count", "L"]]],
	       [NAM5 => [["color", "L"]]], # Map Color (TBD - display as RGB)
	       [NAME => [["name", "Z*"]]],
	       [RGNN => [["region", "Z*"]]],
	       [WHGT => [["water_height", "f"]]],
	       [XCHG => [["enchant_charge", "f"]]],
	       [XSCL => [["scale", "f"]]],
	       [XSOL => [["soul", "Z*"]]],
	       # sort CELL stuff from .ess below this line:
	       [ACDT => $RD_Actor_Data, { rdflags => [qw(ess)] }],
	       [ACSC => @RD_Unknown_ess],
	       [ACSL => @RD_Unknown_ess],
	       [ACTN => @RD_Unknown_ess], # looks like Actor Flags.
	       [ANIS => @RD_Unknown_ess],
	       [APUD => @RD_Unknown_ess],
	       [CHRD => @RD_long_array_ess],
	       [CRED => @RD_Unknown_ess],
	       [CSHN => [["currentstate_hit_target", "Z*"]], { rdflags => [qw(ess)] }],
	       [CSSN => [["currentstate_stolen_target", "Z*"]], { rdflags => [qw(ess)] }],
	       [CSTN => [["currentstate_target", "Z*"]], { rdflags => [qw(ess)] }],
	       [FGTN => [["friend_group_member", "Z*"]], { rdflags => [qw(ess)] }],
	       [LSHN => [["laststate_hit_target", "Z*"]], { rdflags => [qw(ess)] }],
	       [LSTN => [["laststate_target", "Z*"]], { rdflags => [qw(ess)] }],
	       [LVCR => @RD_Unknown_ess], # leveled creature???
	       [MNAM => @RD_Unknown_ess],
	       [MPCD => @RD_Unknown_ess],
	       [MPNT => @RD_Unknown_ess],
	       # (MVRF is encode/decoded just like the FRMR subrecord)
	       [MVRF => [],	# "moved reference"?
		{ @RD_reference }],
	       [NAM8 => @RD_Unknown_ess],
	       #[NAM8 => @RD_short_array_ess], # looks like it might be an array of shorts ???
	       [NAM9 => [["owned", "L"]]],
	       [ND3D => @RD_Unknown_ess],
	       [PRDT => @RD_Unknown_ess], # "pursuit data"???
	       [PWPC => @RD_Unknown_ess], # "powers used"???
	       [PWPS => @RD_Unknown_ess], # "powers used"???
	       [SCRI => [["script", "Z*"]], { rdflags => [qw(ess)] }],
	       [SLCS => [["n_shorts", "L"], ["n_longs", "L"], ["n_floats", "L"]], { rdflags => [qw(ess)] }],
	       [SLFD => @RD_float_array_ess], # "Script Localvar Float Data
	       [SLLD => @RD_long_array_ess], # "Script Localvar Long Data
	       [SLSD => @RD_short_array_ess], # "Script Localvar Short Data
	       [STPR => [["x", "f"], ["y", "f"], ["z", "f"], ["x_angle", "f"], ["y_angle", "f"], ["z_angle", "f"], ]], # "Setting To Position" or "Starting Position"???
	       [TGTN => [["target_group_member", "Z*"]]],
	       [TNAM => [["trap_spell", "Z*"]]],
	       [UNAM => @RD_Unknown],
	       [WNAM => @RD_Unknown_ess],
	       [XNAM => @RD_Unknown_ess],
	       [YNAM => @RD_Unknown_ess],
	       [ZNAM => [["disabled", "C"]]], # object flagged as disabled (ess only ???)
	      ], { id => sub {	# CELL->id()
		       my($self) = @_;
		       return($self->{_id_}) if (defined $self->{_id_});
		       my $name = $self->get('NAME', 'name');
		       return($self->{_id_} = lc($name)) if ($self->is_interior());
		       $name = $self->get('RGNN', 'region') unless ($name);
		       $name ||= 'wilderness';
		       my $x = $self->get('DATA', 'x');
		       my $y = $self->get('DATA', 'y');
		       return($self->{_id_} = lc("$name ($x, $y)"));
		   },
		   is_interior => sub {
		       my($self) = @_;
		       return($self->{_is_interior_}) if (defined($self->{_is_interior_}));
		       return($self->{_is_interior_} = ($self->get('DATA', 'flags') & 0x01));
		   }
		 }],
     [CLAS => [
	       [NAME => [["id", "Z*"]]],
	       [CLDT => [["primary_attribute_1", "l", { lookup => \%ATTRIBUTE }],
			 ["primary_attribute_2", "l", { lookup => \%ATTRIBUTE }],
			 ["specialization", "L", { lookup => \%SPECIALIZATION }],
			 (["minor_skill_#", "l", { lookup => \%SKILL }], ["major_skill_#", "l", { lookup => \%SKILL }]) x 5,
			 ["flags", "L", { lookup => \%PLAYABLE }],
			 ["autocalc", "L", { symflags => \%AUTOCALC_FLAGS }]],
		{ columns => 2 }],
	       [DESC => @RD_Description],
	       [FNAM => [["name", "Z*"]]],
	      ]],
     [CLOT => [
	       [NAME => [["id", "Z*"]]],
	       [BNAM => [["male_clothing", "a*"]]],
	       [CNAM => [["female_clothing", ["Z*", "a*"]]]],
	       [CTDT => [["type", "L", { lookup => \%CTDT_TYPE }], ["weight", "f"],
			 ["value", "S"], ["enchantment", "S"]]],
	       [ENAM => [["enchanting", "Z*"]]],
	       [FNAM => [["name", "Z*"]]],
	       [INDX => [["biped_object", "C", { lookup => \%BIPED_OBJECT } ]]],
	       [ITEX => [["icon", "Z*"]]],
	       [MODL => [["model", "Z*"]]],
	       [SCRI => [["script", "Z*"]]],
	      ]],
     [CNTC => [
	       [NAME => [["id", "Z*"]]],
	       [INDX => [["index", "L"]]],
	       [NPCO => [["count", "l"], ["object", ["Z32", "a32"]]]], # Contained Object
	       [SCRI => [["script", "Z*"]]],
	       [SLCS => [["n_shorts", "L"], ["n_longs", "L"], ["n_floats", "L"]]],
	       [SLFD => @RD_float_array_ess], # Script Localvar Float Data
	       [SLLD => @RD_long_array_ess], # Script Localvar Long Data
	       [SLSD => @RD_short_array_ess], # Script Localvar Short Data
	       [XCHG => [["enchant_charge", "f"]]],
	       [XHLT => [["health", "L"]]],
	       [XIDX => [["scripted_item_index", "L"]]],
	       [XSOL => [["soul", "Z*"]]],
	      ], { rdflags => [qw(ess)] }],
     [CONT => [
	       [NAME => [["id", "Z*"]]],
	       [FNAM => [["name", "Z*"]]],
	       [CNDT => [["weight", "f"]]],
	       [FLAG => [["container_flags", "L", { symflags => \%CONTAINER_FLAGS }]]],
	       [INDX => [["unknown_#", "L"]], { rdflags => [qw(ess)] }],
	       [MODL => [["model", "Z*"]]],
	       [NPCO => [["count", "l"], ["object", ["Z32", "a32"]]]],
	       [SCRI => [["script", "Z*"]]],
	      ]],
     # CHECK CS ??? (Animations? Unknowns?)
     [CREA => [
	       [NAME => [["id", "Z*"]]],
	       [AIDT => [["hello", "C"], ["unknown_#", "C"], ["fight", "C"], ["flee", "C"],
			 ["alarm", "C"], ["unknown_#", "H6"], ["services", "L", { symflags => \%AIDT_FLAGS }]]],
	       [AI_E => @RD_AI_Escort],
	       [AI_F => @RD_AI_Follow],
	       [AI_T => @RD_AI_Travel],
	       [AI_W => @RD_AI_Wander_CREA],
	       [CNAM => [["sound_gen_creature", "Z*"]]],
	       [CNDT => [["data", "Z*"]]], # rare???
	       [DNAM => [["destination", "Z*"]]],
	       [DODT => [["x", "f"], ["y", "f"], ["z", "f"], ["x_angle", "f"], ["y_angle", "f"], ["z_angle", "f"]]],
	       [FLAG => [["flags", "L"]],
		{ tostr => sub {
		      # this is a bit of a hack to get something a little more
		      # reasonable looking out of the weird CREA.FLAG subrec.
		      my $flags = $_[0]->{flags};
		      my $movement_str = flags_tostr($flags, \%CREATURE_MOVEMENT_FLAGS);
		      $movement_str =~ s/(, Movement:None|Movement:None, )//;
		      my $blood_str = flags_tostr($flags, \%CREATURE_BLOOD_FLAGS);
		      $blood_str =~ s/^\S+\s+//;
		      $blood_str = "(Red_Blood)" unless ($blood_str =~ /blood/i);
		      my $other_str = flags_tostr($flags, \%CREATURE_FLAGS);
		      $other_str =~ s/^\S+\s+//;
		      my $flags_str = $movement_str . $blood_str . $other_str;
		      $flags_str =~ s/\(\)//g;
		      $flags_str =~ s/\)\(/, /g;
		      $flags_str
		  },
		}],
	       [FNAM => [["name", "Z*"]]],
	       [INDX => @RD_Unknown_ess],
	       [MODL => [["model", "Z*"]]],
	       [NPCO => [["count", "l"], ["object", ["Z*", "a32"]]]], # Inventory Objects
	       [NPCS => [["spell", ["Z32", "a32"]]]],		    # Spells
	       [NPDT => [["type", "L", { lookup => \%CREA_TYPE }], ["lev", "L"], ["str", "L"], ["int", "L"], ["wil", "L"],
			 ["agi", "L"], ["spd", "L"], ["end", "L"], ["per", "L"], ["lck", "L"],
			 ["health", "L"], ["spell_points", "L"], ["fatigue", "L"], ["soul", "L"],
			 ["combat", "L"], ["magic", "L"], ["stealth", "L"],
			 (["attack_min_#", "L"], ["attack_max_#", "L"]) x 3,
			 ["gold", "L"]],
		{ columns => 4}],
	       [SCRI => [["script", "Z*"]]],
	       [XSCL => [["scale", "f"]]],
	      ]],
     [CREC => [			# "Creature Changes?" in savedgames
	       [NAME => [["id", "Z*"]]],
	       [AI_A => @RD_AI_Activate],
	       [AI_E => @RD_AI_Escort],
	       [AI_F => @RD_AI_Follow],
	       [AI_T => @RD_AI_Travel],
	       [AI_W => @RD_AI_Wander_CREA],
	       [INDX => [["instance", "L"]]],
	       [NPCO => [["count", "l"], ["object", ["Z*", "a32"]]]], # Inventory Objects
	       [SCRI => [["script", "Z*"]]],
	       [SLCS => [["n_shorts", "L"], ["n_longs", "L"], ["n_floats", "L"]]],
	       [SLFD => @RD_float_array_ess], # Script Localvar Float Data
	       [SLLD => @RD_long_array_ess], # Script Localvar Long Data
	       [SLSD => @RD_short_array_ess], # Script Localvar Short Data
	       [WIDX => @RD_widx],
	       [XCHG => [["enchant_charge", "f"]]],
	       [XHLT => [["health", "L"]]],
	       [XIDX => [["index", "L"]]], # ???
	       [XSCL => [["scale", "f"]]],
	       [XSOL => [["soul", "Z*"]]],
	      ], { rdflags => [qw(ess)] }],
     [DIAL => [
	       [NAME => [["id", "Z*"]]],
	       [DATA => [["type", "C", { lookup => \%DIAL_TYPE }]],
		{
		 decode => sub {
		     my($self, $buff, $parent) = @_;
		     $self->{_id_} = $parent->{_id_};
		     $self->{_subbuf_} = $buff;
		     $self->{type} = unpack("C", $buff);
		     # stash the current dialog type:name for decorating INFO tostr's
		     $CURRENT_DIAL = "$DIAL_TYPE{$self->{type}}:".$self->{_id_};
		     return($self);
		 }}],
	       [XIDX => [["index", "l"]], { rdflags => [qw(ess)] }],
	      ]],
     [DOOR => [
	       [NAME => [["id", "Z*"]]],
	       [ANAM => [["door_close_sound", "Z*"]]],
	       [FNAM => [["name", "Z*"]]],
	       [MODL => [["model", "Z*"]]],
	       [SCRI => [["script", "Z*"]]],
	       [SNAM => [["door_open_sound", "Z*"]]],
	      ]],
     [ENCH => [
	       [NAME => [["id", "Z*"]]],
	       [ENAM => @RD_Enchantment],
	       [ENDT => [["type", "L", { lookup => \%ENCHANT_TYPE }],
			 ["cost", "L"], ["charge", "L"],
			 ["autocalc", "s", { lookup => \%ENDT_AUTO }],
			 ["Unused", "s"]]],
	      ]],
     # CHECK CS ??? (what is stuff in CS dialog box in lower right?)
     [FACT => [
	       [NAME => [["id", "Z*"]],
		{ tostr => sub {
		      my($self) = @_;
		      %FACTION_RANK = (); # reset
		      #$FACTION_INDEX{$self->{id}} = $FACT_I++;
		      $self->{id};
		  }
		}],
	       [ANAM => [["faction", "a*"]]],
	       [FADT => [["attrib_1", "l", { lookup => \%ATTRIBUTE}],
			 ["attrib_2", "l", { lookup => \%ATTRIBUTE}],
			 (["at1_#", "l"], ["at2_#", "l"], ["sk1_#", "l"], ["sk2_#", "l"], ["rep_#", "l"]) x 10,
			 (["sk_#", "l"]) x 6,
			 ["unknown", "l"], ["flags", "L"]],
		{ tostr => sub {
		      my($self) = @_;
		      my @ranks = ((defined $self->{_id_}) and (defined $FACTION_RANK{$self->{_id_}})) ?
			  @{$FACTION_RANK{$self->{_id_}}} : ();
		      my @tostr = (sprintf("Attrib_1:(%s)  Attrib_2:(%s)  Flags:%s  Unknown:%d",
					   $ATTRIBUTE{$self->{attrib_1}}, $ATTRIBUTE{$self->{attrib_2}},
					   flags_tostr($self->{flags}, \%FACT_FLAGS), $self->{unknown}));
		      # (Change the following if suffix_index strategy changes)
		      my $n = 1;
		      while (defined($self->{"at1_$n"}) and defined($ranks[$n-1])) {
			  my $shim = ($n < 10) ? " " : "";
			  push(@tostr, sprintf("\t%-20s ${shim}At1_$n:%2d  ${shim}At2_$n:%2d  ${shim}Sk1_$n:%2d  ${shim}Sk2_$n:%2d  ${shim}Rep_$n:%3d",
					       "(Rank:$ranks[$n-1])", $self->{"at1_$n"}, $self->{"at2_$n"}, $self->{"sk1_$n"}, $self->{"sk2_$n"}, $self->{"rep_$n"}));
			  $n++;
		      }
		      if (DBG) {
			  # (Change the following if suffix_index strategy changes)
			  foreach my $i (1..6) {
			      defined($self->{"sk_$i"}) or abort(qq{FACT::FADT->tostr: self{sk_$i} undefined});
			      defined($SKILL{$self->{"sk_$i"}}) or abort(qq{FACT::FADT->tostr: no SKILL defined for: $self->{"sk_$i"} (sk_$i)});
			  }
		      }
		      # (Change the following if suffix_index strategy changes)
		      push(@tostr, sprintf("\t%-20s  %-20s  %-20s", map { qq{sk_$_:($SKILL{$self->{"sk_$_"}})}; } 1..3));
		      push(@tostr, sprintf("\t%-20s  %-20s  %-20s", map { qq{sk_$_:($SKILL{$self->{"sk_$_"}})}; } 4..6));

		      join("\n", @tostr);
		  }, }],
	       [FNAM => [["name", "Z*"]]],
	       [INTV => [["reaction", "l"]]],
	       [RNAM => [["rank", ["Z32", "a32"]]],
		{ tostr => sub {
		      my($self) = @_;
		      push(@{$FACTION_RANK{$self->{_id_}}}, $self->{rank});
		      "Rank:$self->{rank}";
		  }}],
	      ]],
     [FMAP => [			# ess, single record, no id
	       [MAPD => @RD_Unknown],
	       [MAPH => @RD_Unknown],
	      ], { id => sub {'()'},
		   rdflags => [qw(ess)] }],
     [GAME => [			# ess, single record, no id
	       [GMDT => [["current_cell", ["Z64", "a64"]], ["x", "l"], ["y", "l"], ["long_#", "l"], ["long_#", "l"], ["unknown_#", "H*"]]], # there is junk following the cell name ... not clear if there's a max cell name size?
	      ], { id => sub {'()'}, rdflags => [qw(ess)] }],
     [GLOB => [
	       [NAME => [["id", "Z*"]]],
	       [FLTV => [["float", "f"]]],
	       [FNAM => [["type", "a", { lookup => \%GLOBAL_TYPE }]]],
	      ]],
     [GMST => [
	       [NAME => [["id", ["Z*", "a*"]]]],
	       [FLTV => [["float", "f"]]],
	       [INTV => [["integer", "l"]]],
	       [STRV => [["string", "a*"]],
		{ tostr => sub {
		      my $str = $_[0]->{string};
		      $str =~ tr/\r//d if ($^O eq 'linux');
		      "String:$str";
		  },
		}],
	      ]],
     # CHECK CS ??? (unknowns?)
     [INFO => [
	       [INAM => [["id", "Z*"]]],
	       [ACDT => [["actor_data", "Z*"]], { rdflags => [qw(ess)] }],
	       [ANAM => [["cell", "Z*"]]],
	       [BNAM => [["result", "a*"]],
		{ tostr => sub {
		      my($self) = @_;
		      my $str = $self->{result};
		      $str =~ tr/\r//d if ($^O eq 'linux');
		      $str =~ s/\n/\n\t\t/g;
		      "Result:\t$str";
		  },
		}],
	       [CNAM => [["class", "Z*"]]],
	       [DATA => [["unknown_#", "L"], ["disposition", "L"], ["rank", "c"],
			 ["sex", "c"], ["pc_rank", "c"], ["unknown_#", "C"]],
		{ tostr => sub {
		      my($self) = @_;
		      if ($CURRENT_DIAL =~ /^Journal/i) {
			  sprintf("JournalIndex:%s", $self->{disposition});
		      } else {
			  sprintf("Disposition:%s  Rank:%s  Sex:%s  PC_Rank:%s",
				  $self->{disposition},
				  ($self->{rank} == -1) ? "None" : $self->{rank},
				  $SEX{$self->{sex}},
				  ($self->{pc_rank} == -1) ? "None" : $self->{pc_rank});
		      }
		  }
		}],
	       [DNAM => [["pc_faction", "Z*"]]],
	       [FLTV => [["result_value", "f"]]],
	       [FNAM => [["faction", "Z*"]]],
	       [INTV => [["compare_value", "l"]]],
	       [NAME => [["response", "a*"]],
		{ tostr => sub {
		      my($self) = @_;
		      my $str = $self->{response};
		      $str =~ tr/\r//d if ($^O eq 'linux');
		      if (length($str) < 60) {
			  return("Response: $str");
		      } else {
			  $str = wrap("\t", "\t", $str) if (WRAP);
			  return("Response:\n$str");
		      }
		  },
		}],
	       [NNAM => [["next_id", "Z*"]]],
	       [ONAM => [["actor", "Z*"]]],
	       [PNAM => [["prev_id", "Z*"]]],
	       [QSTF => [["quest_finished", "C"]]], # TBD check format (was: "C:")
	       [QSTN => [["quest_name", "C"]]], # TBD check format (was: "C:")
	       [QSTR => [["quest_restart", "C"]]], # TBD check format (was: "C:")
	       [RNAM => [["race", "Z*"]]],
	       [SCVR => [["index", "a"],
			 ["type", "a", { lookup => \%INFO_SCVR_TYPE}],
			 ["function", "a2", { lookup => \%INFO_FUN }],
			 ["comparison", "a", { lookup => \%INFO_SCVR_CMP }],
			 ["name", "a*"]]],
	       [SNAM => [["sound_file", "Z*"]]],
	      ]],
     [INGR => [
	       [NAME => [["id", "Z*"]]],
	       [FNAM => [["name", "Z*"]]],
	       [IRDT => [["weight", "f"], ["value", "L"],
			 (["effect_#", "l"]) x 4,
			 (["skill_#", "l"]) x 4,
			 (["attribute_#", "l"]) x 4,
			],
		{ tostr => sub {
		      my($self) = @_;
		      my @effects;
		      # (Change the following if suffix_index strategy changes)
		      foreach my $i (1..4) {
			  if ($self->{"effect_$i"} != -1) {
			      my $eix = $self->{"effect_$i"};
			      my $effect = "Effect_$i:(".($SPELL_EFFECT{$eix} || "${eix}???");
			      if ($effect =~ /_attribute$/i) {
				  push(@effects, qq{$effect/$ATTRIBUTE{$self->{"attribute_$i"}})});
			      } elsif ($effect =~ /_skill$/i) {
				  push(@effects, qq{$effect/$SKILL{$self->{"skill_$i"}})});
			      } else {
				  push(@effects, "$effect)");
			      }
			  }
		      }
		      my $effects = (@effects) ? ("\n\t" . join("\n\t", @effects)) : "";
		      sprintf("Weight:%0.2f  Value:%d$effects",
			      $self->{weight}, $self->{value});
		  }}],
	       [ITEX => [["icon", "Z*"]]],
	       [MODL => [["model", "Z*"]]],
	       [SCRI => [["script", "Z*"]]],
	      ]],
     [JOUR => [
	       [NAME => [["id", "Z*"]], { rdflags => [qw(ess)] }],
	      ]],
     [KLST => [
	       [KNAM => [["id", "Z*"]]],
	       [CNAM => [["dead_count", "L"]]],
	       [INTV => [["end_of_list", "L"]]],
	      ], { rdflags => [qw(ess)] }],
     [LAND => [
	       [INTV => [["x", "l"], ["y", "l"]]],
	       [DATA => @RD_Unknown],
	       [VCLR => [],	# (Vertex RGB Color Array, 65 x 65)
		{ decode => sub {
		      my($self, $buff, $parent) = @_;
		      $self->{_subbuf_} = $buff;
		      # my $array_length = 65 * 65;
		      $self->{_array_} = [unpack("(H6)*", $buff)];
		      return($self);
		  },
		  encode => sub {
		      my($self) = @_;
		      $self->{_subbuf_} = pack("(H6)*", @{$self->{_array_}});
		      return($self);
		  },
		  tostr => sub {
		      my($self) = @_;
		      my $str = "(Vertex RGB Color Array, 65 x 65):";
		      foreach my $i (0..64) {
			  $str .= sprintf("\n   %2d:", $i) . 
			      join(",", map { $self->{_array_}->[($i * 65) + $_] } (0..64));
		      }
		      $str;
		  }}],
	       [VHGT => [],	# (Vertex Height Array, 65 x 65)
		{ decode => sub {
		      my($self, $buff, $parent) = @_;
		      $self->{_subbuf_} = $buff;
		      my $array_length = 65 * 65;
		      #my(@data) = unpack("fcc${array_length}s", $buff); # Dave Humphries
		      my(@data) = unpack("fc${array_length}sc", $buff); # OpenMW
		      $self->{offset} = shift(@data);
		      $self->{unknown_1} = shift(@data);
		      $self->{unknown_2} = pop(@data);
		      $self->{_array_} = \@data;
		      return($self);
		  },
		  encode => sub {
		      my($self) = @_;
		      my $array_length = 65 * 65;
		      #$self->{_subbuf_} = pack("fcc${array_length}s", # Dave Humphries
		      $self->{_subbuf_} = pack("fc${array_length}sc", # OpenMW
					       $self->{offset}, $self->{unknown_1},
					       @{$self->{_array_}},
					       $self->{unknown_2});
		      return($self);
		  },
		  tostr => sub {
		      my($self) = @_;
		      my $str = qq{Offset:$self->{offset}  Unknown_1:$self->{unknown_1}  Unknown_2:$self->{unknown_2}
\t(Vertex Height Array, 65 x 65):};
		      foreach my $i (0..64) {
			  $str .= sprintf("\n   %2d:", $i) .
			      join(",", map { $self->{_array_}->[($i * 65) + $_] } (0..64));
		      }
		      $str;
		  }}],
	       [VNML =>  [], # (Vertex Normal Array, 65 x 65)
		{ decode => sub {
		      my($self, $buff, $parent) = @_;
		      $self->{_subbuf_} = $buff;
		      $self->{_array_} = [unpack("(H6)*", $buff)];
		      return($self);
		  },
		  encode => sub {
		      my($self) = @_;
		      $self->{_subbuf_} = pack("(H6)*", @{$self->{_array_}});;
		      return($self);
		  },
		  tostr => sub {
		      my($self) = @_;
		      my $str = "(Vertex Normal Array, 65 x 65):";
		      foreach my $i (0..64) {
			  $str .= sprintf("\n   %2d:", $i) .
			      join(",", map { $self->{_array_}->[($i * 65) + $_] } (0..64));
		      }
		      $str;
		  }}],
	       [VTEX => [], # (Vertex Texture Index Array, 16 x 16)
		{ decode => sub {
		      my($self, $buff, $parent) = @_;
		      $self->{_subbuf_} = $buff;
		      $self->{_array_} = [unpack("s*", $buff)];
		      return($self);
		  },
		  encode => sub {
		      my($self) = @_;
		      $self->{_subbuf_} = pack("s*", @{$self->{_array_}});
		      return($self);
		  },
		  tostr => sub {
		      my($self) = @_;
		      my $str = "(Vertex Texture Index Array, 16 x 16):";
		      foreach my $i (0..15) {
			  $str .= sprintf("\n   %2d:", $i) .
			      join(",", map { $self->{_array_}->[($i * 16) + $_] } (0..15));
		      }
		      $str;
		  }
		 }],
	       [WNAM => [(["i_#", "c*"]) x (9 * 9)], # low-LOD heightmap
		{ tostr => sub {
		      my($self) = @_;
		      my $str = "(low-LOD Heightmap, 9 x 9):";
		      foreach my $i (1..9) {
			  $str .= sprintf("\n   %2d:", ($i-1)) .
			      join(",", map { $self->{"i_".((($i-1) * 9) + $_)} } (1..9));
		      }
		      $str;
		  }}],
	      ], { id => sub {
		       my($self) = @_;
		       return($self->{_id_}) if (defined $self->{_id_});
		       my $x = $self->get('INTV', 'x');
		       my $y = $self->get('INTV', 'y');
		       return($self->{_id_} = "($x, $y)") if (defined($x) and defined($y));
		       err("Bad LAND id: missing INTV");
		       dbg(Dumper($self)) if (DBG);
		   }
		 }],
     [LEVC => [
	       [NAME => [["id", "Z*"]]],
	       [DATA => [["list_flags", "L", { symflags => \%LEVC_FLAGS }]]],
	       [INDX => [["item_count", "L"]]],
	       [NNAM => [["chance_none", "C"]]],
	       [CNAM => [["creature_id", "Z*"]]],
	       [INTV => [["level", "S"]]],
	      ]],
     [LEVI => [
	       [NAME => [["id", "Z*"]]],
	       [DATA => [["list_flags", "L", { symflags => \%LEVI_FLAGS }]]],
	       [INDX => [["item_count", "L"]]],
	       [NNAM => [["chance_none", "C"]]],
	       [INAM => [["item_id", "Z*"]]],
	       [INTV => [["level", "S"]]],
	      ]],
     [LIGH => [
	       [NAME => [["id", "Z*"]]],
	       [FNAM => [["name", "Z*"]]],
	       [ITEX => [["icon", "Z*"]]],
	       [LHDT => [["weight", "f"], ["value", "L"], ["time", "l"], ["radius", "L"],
			 ["color", "L"], ["flags", "L", { symflags => \%LHDT_FLAGS }]],
		{ tostr => sub {
		      my ($self) = @_;
		      sprintf("Weight:%0.2f  Value:%d  Time:%d  Radius:%d  Color:%s\n\tFlags:%s",
			      $self->{weight}, $self->{value}, $self->{time}, $self->{radius}, color_tostr($self->{color}), flags_tostr($self->{flags}, \%LHDT_FLAGS));
		  },
		}],
	       [MODL => [["model", "Z*"]]],
	       [SCRI => [["script", "Z*"]]],
	       [SNAM => [["sound_id", "Z*"]]],
	      ]],
     [LOCK => [
	       [NAME => [["id", "Z*"]]],
	       [FNAM => [["name", "Z*"]]],
	       [ITEX => [["icon", "Z*"]]],
	       [LKDT => [["weight", "f"], ["Value", "L"], ["Quality", "f"], ["Uses", "L"]]],
	       [MODL => [["model", "Z*"]]],
	       [SCRI => [["script", "Z*"]]],
	      ]],
     # CHECK CS ???
     [LTEX => [
	       [NAME => [["id", "Z*"]]],
	       [DATA => [["texture_path", "Z*"]]],
	       [INTV => [["index", "L"]]],
	      ]],
     [MGEF => [
	       [INDX => [["id", "l", { lookup => \%SPELL_EFFECT }]]],
	       [ASND => [["area_sound", "Z*"]]],
	       [AVFX => [["area_vfx", "Z*"]]],
	       [BSND => [["bolt_sound", "Z*"]]],
	       [BVFX => [["bolt_vfx", "Z*"]]],
	       [CSND => [["cast_sound", "Z*"]]],
	       [CVFX => [["cast_vfx", "Z*"]]],
	       [DESC => @RD_Description],
	       [HSND => [["hit_sound", "Z*"]]],
	       [HVFX => [["hit_vfx", "Z*"]]],
	       [ITEX => [["icon", "Z*"]]],
	       [MEDT => [["school", "L", { lookup => \%MAGIC_SCHOOL }], ["base_cost", "f"],["flags", "L:%s\n      ", { symflags => \%MGEF_FLAGS }],
			 ["red", "L"], ["green", "L"], ["blue", "L"],
			 ["speed", "f"], ["size", "f"], ["sizecap", "f"]]],
	       [PTEX => [["Particle_Texture", "Z*"]]],
	      ]],
     [MISC => [
	       [NAME => [["id", "Z*"]]],
	       [FNAM => [["name", "Z*"]]],
	       [ITEX => [["icon", "Z*"]]],
	       [MCDT => [["weight", "f"], ["value", "L"], ["key_for_lock", "L", { lookup => \%YESNO }]]],
	       [MODL => [["model", "Z*"]]],
	       [SCRI => [["script", "Z*"]]],
	      ]],
     [NPCC => [			# "NPC Changes?" records in savedgames
	       [NAME => [["id", "Z*"]]],
	       [AI_E => @RD_AI_Escort],
	       [AI_F => @RD_AI_Follow],
	       [AI_T => @RD_AI_Travel],
	       [AI_W => @RD_AI_Wander_NPC],
	       [NPCO => [["count", "l"], ["object", ["Z*", "a32"]]]], # Inventory Objects
	       [NPDT => @RD_Unknown],
	       [SCRI => [["script", "Z*"]]],
	       [SLCS => [["n_shorts", "L"], ["n_longs", "L"], ["n_floats", "L"]]],
	       [SLFD => @RD_float_array_ess], # Script Localvar Float Data
	       [SLLD => @RD_long_array_ess], # Script Localvar Long Data
	       [SLSD => @RD_short_array_ess], # Script Localvar Short Data
	       [WIDX => @RD_widx],
	       [XCHG => [["enchant_charge", "f"]]],
	       [XHLT => [["health", "L"]]],
	       [XIDX => [["index", "L"]]], # ???
	       [XSOL => [["soul", "Z*"]]],
	      ], { rdflags => [qw(ess)] }],
     # CHECK CS ???
     [NPC_ => [
	       [NAME => [["id", "Z*"]]],
	       [FNAM => [["name", "Z*"]]],
	       [AIDT => [["hello", "C"], ["unknown_#", "C"], ["fight", "C"], ["flee", "C"], ["alarm", "C"],
			 ["unknown_#", "H6"], ["services", "L", { symflags => \%AIDT_FLAGS }]]],
	       [AI_A => @RD_AI_Activate],
	       [AI_E => @RD_AI_Escort],
	       [AI_F => @RD_AI_Follow],
	       [AI_T => @RD_AI_Travel],
	       [AI_W => @RD_AI_Wander_NPC],
	       [ANAM => [["faction", "Z*"]]],
	       [BNAM => [["head_model", "Z*"]]],
	       [CNAM => [["class", "Z*"]]],
	       [CNDT => [["data", "Z*"]]],
	       [DNAM => [["destination", "Z*"]]],
	       [DODT => [["x", "f"], ["y", "f"], ["z", "f"], ["x_angle", "f"], ["y_angle", "f"], ["z_angle", "f"]]],
	       [FLAG => [["flags", "L", { symflags => \%NPC_FLAGS }]]],
	       [KNAM => [["hair_model", "Z*"]]],
	       [MODL => [["model", "Z*"]]],
	       [NPCO => [["count", "l"], ["object", ["Z*", "a32"]]]], # Inventory Objects
	       [NPCS => [["spell", ["Z32", "a32"]]]],		      # Spells
	       [NPDT => [],
		{
		 decode => sub {
		     my($self, $buff, $parent) = @_;
		     $self->{_id_} = $parent->{_id_};
		     $self->{_subbuf_} = $buff;
		     $self->{_parent_} = $parent;
		     my $blen = length($buff);
		     if ($blen == 12) {
			 ($self->{level}, $self->{disposition}, $self->{factionindex}, $self->{rank},
			  $self->{unk1}, $self->{unk2}, $self->{unk3}, $self->{gold}) =
			      unpack("SC6L", $buff);
		     } elsif ($blen == 52) {
			 my $i = 0;
			 foreach my $skill_level (unpack("x[SC8]C27", $buff)) {
			     $self->{lc($SKILL{$i++})} = $skill_level;
			 }
			 ($self->{level}, $self->{str}, $self->{int}, $self->{wil}, $self->{agi}, $self->{spd},
			  $self->{end}, $self->{per}, $self->{lck}, $self->{reputation}, $self->{health},
			  $self->{magicka}, $self->{fatigue}, $self->{disposition}, $self->{factionindex},
			  $self->{rank}, $self->{gold}) = unpack("SC8x[C27]CSSSCCCxL", $buff);
		     } else {
			 err("DECODER barfed on NPC_.NPDT, Invalid length: $blen, expected 52 or 12!");
		     }
		     return($self);
		 },
		 encode => sub {
		     my($self) = @_;
		     if (exists $self->{magicka}) {
			 #warn("DUMP=".Dumper($self));
			 $self->{_subbuf_} =
			     pack("SC8C27CSSSCCCxL",
				  # S
				  $self->{level},
				  # C8
				  $self->{str}, $self->{int}, $self->{wil}, $self->{agi},
				  $self->{spd}, $self->{end}, $self->{per}, $self->{lck},
				  # C27
				  $self->{block}, $self->{armorer}, $self->{medium_armor}, $self->{heavy_armor},
				  $self->{blunt_weapon}, $self->{long_blade}, $self->{axe}, $self->{spear},
				  $self->{athletics}, $self->{enchant}, $self->{destruction}, $self->{alteration},
				  $self->{illusion}, $self->{conjuration}, $self->{mysticism}, $self->{restoration},
				  $self->{alchemy}, $self->{unarmored}, $self->{security}, $self->{sneak},
				  $self->{acrobatics}, $self->{light_armor}, $self->{short_blade}, $self->{marksman},
				  $self->{mercantile}, $self->{speechcraft}, $self->{hand_to_hand},
				  # C
				  $self->{reputation},
				  # S3
				  $self->{health}, $self->{magicka}, $self->{fatigue},
				  # C3
				  $self->{disposition}, $self->{factionindex}, $self->{rank},
				  # L
				  $self->{gold});
			 assert(length($self->{_subbuf_}) == 52, "Invalid NPDT length (@{[length($self->{_subbuf_})]})") if (ASSERT);
		     } else {
			 $self->{_subbuf_} =
			     pack("SC6L", $self->{level}, $self->{disposition}, $self->{factionindex}, $self->{rank},
				  $self->{unk1}, $self->{unk2}, $self->{unk3},  $self->{gold});
		     }
		     return($self);
		 },
		 #fieldnames => sub { grep {!/^_/} keys %{$_[0]}; }, # NOTYET check this works (and implement ordering)
		 tostr => sub {
		     my($self) = @_;
		     my $factionindex = $self->{factionindex};
		     my $rank = $self->{rank};
		     if (exists $self->{str}) { # long form
			 my $skills = "";
			 my $n = 0;
			 foreach my $skill (sort values %SKILL) {
			     next if ($skill eq 'None');
			     $skills .= (($n++ % 6) == 0) ? "\n\t" : "  ";
			     $skills .= "$skill:$self->{lc($skill)}";
			 }
			 sprintf "Level:%d\n\tStr:%d  Int:%d  Wil:%d  Agi:%d  Spd:%d  End:%d  Per:%d  Lck:%d\n\tReputation:%d  Health:%d  Magicka:%d  Fatigue:%d  Disposition:%d\n\tFactionIndex:%s  Rank:%s  Gold:%d\n\t(Skills):$skills",
			     $self->{level}, $self->{str}, $self->{int}, $self->{wil}, $self->{agi}, $self->{spd},
				 $self->{end}, $self->{per}, $self->{lck}, $self->{reputation}, $self->{health}, $self->{magicka},
				     $self->{fatigue}, $self->{disposition}, $factionindex, $rank, $self->{gold};
		     } else {	# short form (autocalced)
			 sprintf "Level:%d  Disposition:%d  FactionIndex:%s  Rank:%s  Gold:%d",
			     $self->{level}, $self->{disposition}, $factionindex, $rank, $self->{gold};
		     }
		 }
		}],
	       [RNAM => [["race", "Z*"]]],
	       [SCRI => [["script", "Z*"]]],
	      ]],
     [PCDT => [			# ess, single record, no id
	       [AADT => @RD_Unknown],
	       [ANIS => @RD_Unknown],
	       [BNAM => [["birthsign", "Z*"]]],
	       [CNAM => @RD_Unknown],
	       [DNAM => [["dialog_topic", "Z*"]]],
	       [ENAM => [(["unknown_#", "l"]) x 2]],
	       [FNAM => [["long_#", "l"], ["long_#", "l:%-2d"], ["long_#", "l"], ["faction", "Z16"], ["float_#", "f"], ["float_#", "f"], ["long_#", "l"], ["long_#", "l"]]],
	       [KNAM => [ (["unknown_#", "c"], ["spell_#", ["Z35:%-25s", "a35"]], ["long_#", "l:%d\n\t"]) x 10 ]], # hotkeys
	       [LNAM => [(["unknown_#", "l"]) x 2]],
	       [MNAM => [["mnam", "Z*"]]],
	       [NAM0 => [["nam0", "Z*"]]],
	       [NAM1 => [["nam1", "Z*"]]],
	       [NAM2 => [["nam2", "Z*"]]],
	       [NAM3 => [["nam3", "Z*"]]],
	       [NAM9 => @RD_Unknown],
	       [PNAM => @RD_Unknown],
	       [SNAM => @RD_Unknown],
	      ], { id => sub {'()'},
		   rdflags => [qw(ess)] }],
     [PGRD => [
	       [NAME => [["name", "Z*"]]],
	       [DATA => [["x", "l"], ["y", "l"], ["granularity", "S"], ["pointcount", "S"]]],
	       [PGRP => [],
		{ decode => sub {
		      my($self, $buff, $parent) = @_;
		      $self->{_id_} = $parent->{_id_};
		      $self->{_subbuf_} = $buff;
		      my $blen = length($buff);
		      my @points;
		      while ($buff) {
			  if (length($buff) < 16) {
			      err("DECODER barfed on PGRD.PGRP, Invalid length: $blen, should be multiple of 16!");
			      last;
			  }
			  my($x,$y,$z,$color,$nconn,$unk,$rest) = unpack("l3C2H4a*", $buff);
			  push(@points, {x=>$x, y=>$y, z=>$z, color=>$color, nconn=>$nconn, unk=>$unk});
			  $buff = $rest;
		      }
		      $self->{points} = \@points;
		      my $dpc = $parent->{SH}->{DATA}->[0]->{pointcount};
		      my $pc = scalar(@points);
		      if ($pc != $dpc) {
			  err("DECODER barfed on PGRD.PGRP, DATA->pointcount ($dpc) != number of points in PGRP ($pc)!");
		      }
		      return($self);
		  },
		  encode => sub {
		      my($self) = @_;
		      my $buff;
		      foreach my $p (@{$self->{points}}) {
			  my $color = $p->{color};
			  if (lc($p->{color}) eq 'red') {
			      $color = 0;
			  } elsif (lc($p->{color}) eq 'blue') {
			      $color = 1;
			  }
			  $buff .= pack("l3C2H4", $p->{x}, $p->{y}, $p->{z}, $color, $p->{nconn}, $p->{unk});
		      }
		      $self->{_subbuf_} = $buff;
		      return($self);
		  },
		  tostr => sub {
		      my($self) = @_;
		      my $idx = 0;
		      my @str = ("Points:");
		      foreach my $p (@{$self->{points}}) {
			  my $color = $p->{color};
			  if ($color =~ /^[01]$/) {
			      $color = $PGCOLOR{$color};
			  }
			  push(@str, sprintf("[%3d]  x:%5d  y:%5d  z:%5d  color:%s  nconn:%d  unknown:%s",
					     $idx, $p->{x}, $p->{y}, $p->{z}, $color, $p->{nconn}, $p->{unk}));
			  $idx++;
		      }
		      return(join("\n\t", @str));
		  },
		}],
	       [PGRC => [],
	       	{ decode => sub {
	       	      my($self, $buff, $parent) = @_;
	       	      $self->{_id_} = $parent->{_id_};
	       	      $self->{_parent_} = $parent;
	       	      $self->{_subbuf_} = $buff;
	       	      my $blen = length($buff);
	       	      @{$self->{connections}} = unpack("L*", $buff);
	       	      return($self);
	       	  },
	       	  encode => sub {
		      my($self) = @_;
		      $self->{_subbuf_} = pack("L*", @{$self->{connections}});
		      return($self);
	       	  },
	       	  tostr => sub {
		      my($self) = @_;
		      my $str;
		      my @points = @{$self->{_parent_}->{SH}->{PGRP}->[0]->{points}};
		      my $pointcount = $self->{_parent_}->{SH}->{DATA}->[0]->{pointcount};
		      err("PGRD.PGRC ($self->{_id_}) (N points=@{[scalar(@points)]} != pointcount($pointcount)")
			  if (scalar(@points) != $pointcount);
		      my @conn = @{$self->{connections}};
		      my @str = ("Connections:");
		      #my @str = ("Connections:" . " " . join(" ", @conn));
		      my $ci = 0;
		      for (my $p1=0; $p1<$pointcount; $p1++) {
			  my $nconn = $points[$p1]->{nconn};
			  my @ps;
			  for (my $j=0; $j<$nconn; $j++) {
			      push(@ps, $conn[$ci++]);
			  }
			  push(@str, sprintf("%3d -> %s", $p1, join(", ", @ps))) if (@ps);
		      }
		      return(join("\n\t", @str));
	       	  },
	       	}]
	      ], { id => sub { # PGRD->id
		       my($self) = @_;
		       return($self->{_id_}) if (defined $self->{_id_});
		       my $name = $self->get('NAME', 'name');
		       my $x = $self->get('DATA', 'x');
		       my $y = $self->get('DATA', 'y');
		       return($self->{_id_} = (($x == 0 and $y == 0) ? $name : "$name ($x, $y)"));
		   }}],
     [PROB => [
	       [NAME => [["id", "Z*"]]],
	       [FNAM => [["name", "Z*"]]],
	       [ITEX => [["icon", "Z*"]]],
	       [MODL => [["model", "Z*"]]],
	       [PBDT => [["weight", "f"], ["value", "L"], ["quality", "f"], ["uses", "L"]]],
	       [SCRI => [["script", "Z*"]]],
	      ]],
     [PROJ => [			# projectiles (at least those in-flight at time of save)
	       [PNAM => [
			 ["unknown_#", "H8"],
			 ["speed", "f"],
			 ["unknown_#", "H8"],
			 ["unknown_#", "H8"],
			 ["flight_time", "f"],
			 ["unknown_#", "H8"],
			 ["unknown_#", "H8"],
			 ["speed_x", "f"],
			 ["speed_y", "f"],
			 ["speed_z", "f"],
			 ["x", "f"],
			 ["y", "f"],
			 ["z", "f"],
			 ["unknown_#", "H72"],
			 ["shooter", "Z32"],
			 ["ammo", "Z32"],
			 ["weapon", "Z32"],
			]],
	      ], { id => sub {'()'},
		   rdflags => [qw(ess)] } ],
     [QUES => [
	       [NAME => [["id", "Z*"]]],
	       [DATA => [["info_id", "Z*"]]],
	      ], { rdflags => [qw(ess)] }],
     [RACE => [
	       [NAME => [["id", "Z*"]]],
	       [DESC => @RD_Description],
	       [FNAM => [["name", "Z*"]]],
	       [NPCS => [["spell", ["Z32", "a32"]]]], # Spells
	       [RADT => [
			 (["skill_#", "l", { lookup => \%SKILL }], ["bonus_#", "L"]) x 7,
			 (["attr_male_#", "l", { lookup => \%ATTRIBUTE }], ["attr_female_#", "l", { lookup => \%ATTRIBUTE }]) x 8,
			 ["male_height", "f"], ["female_height", "f"],
			 ["male_weight", "f"], ["female_weight", "f"],
			 ["flags", "L", { symflags => \%RADT_FLAGS }]],
		{
		 tostr => sub {
		     my($self) = @_;
		     my $radt = sprintf "Flags:%s  Male_Height:%0.2f  Male_Weight:%0.2f  Female_Height:%0.2f  Female_Weight:%0.2f\n\t\tSkill Bonus:",
			 flags_tostr($self->{flags}, \%RADT_FLAGS), $self->{male_height}, $self->{male_weight},
			     $self->{female_height}, $self->{female_weight};
		     my $total_bonus = 0;
		     foreach my $i (1..7) {
			 my($skill_id, $bonus) = ($self->{"skill_$i"}, $self->{"bonus_$i"});
			 $total_bonus += $bonus;
			 if (DBG) {
			     abort("Null Bonus: ".Dumper($self)) unless defined $bonus;
			     abort("Null skill_id:$skill_id: ".Dumper($self)) unless defined $skill_id;
			     abort("Null SKILL for skill_id:$skill_id: ".Dumper($self)) unless defined $SKILL{$skill_id};
			 }
			 $radt .= sprintf("\n\t\t%-12s %3d", $SKILL{$skill_id}, $bonus) if ($skill_id > -1);
		     }
		     $radt .= "\n\t\t(Bonus Total: $total_bonus)\n\t\tBase Attributes: Male/Female";
		     my $i = 1;
		     foreach my $attr (qw(Strength Intelligence Willpower Agility Speed Endurance Personality Luck)) {
			 my($male, $female) = ($self->{"attr_male_$i"}, $self->{"attr_female_$i"});
			 $radt .= sprintf("\n\t\t%-12s    %3d  %3d", $attr, $male, $female);
			 $i++;
		     }
		     $radt;
		 },
		}],
	      ]],
     [REFR => [
	       [NAME => [["id", "Z*"]]],
	       [AADT => @RD_Unknown],
	       [ACDT => $RD_Actor_Data],
	       [ACSC => @RD_Unknown],
	       [ACSL => @RD_Unknown],
	       [ACTN => [["unknown_#", "L"]]], # Actor Flags ???
	       [ANIS => [["unknown_#", "H*"]]],
	       [APUD => @RD_Unknown],
	       [CHRD => @RD_long_array_ess],
	       [CSHN => [["currentstate_hit_target", "Z*"]], { rdflags => [qw(ess)] }],
	       [CSTN => [["currentstate_target", "Z*"]], { rdflags => [qw(ess)] }],
	       [DATA => @RD_Unknown],
	       [FGTN => [["friend_group_member", "Z*"]]],
	       [FRMR => [], { @RD_reference }],
	       [ND3D => [["unknown_#", "C"]]],
	       [STPR => @RD_Unknown],
	       [TGTN => [["target_group_member", "Z*"]]],
	       [WNAM => [["readied_spell", "Z*"]]],
	       [XNAM => [["enchanted_item", "Z*"]]],
	       [YNAM => @RD_Unknown],
	       [XSCL => [["scale", "f"]]],
	      ], { rdflags => [qw(ess)] }],
     [REGN => [
	       [NAME => [["id", "Z*"]]],
	       [BNAM => [["sleep_creature_id", "Z*"]]],
	       [CNAM => [["red", "C"], ["green", "C"], ["blue", "C"], ["unused", "C"]]],
	       [FNAM => [["name", "Z*"]]],
	       [SNAM => [["sound_id", ["Z32", "a32"]], ["chance", "C"]]],
	       [WEAT => [],
		{
		 decode => sub {
		     my($self, $buff, $parent) = @_;
		     $self->{_id_} = $parent->{_id_};
		     $self->{_subbuf_} = $buff;
		     my $blen = length($buff);
		     if ($blen == 10) {
			 ($self->{clear}, $self->{cloudy}, $self->{foggy}, $self->{overcast},
			  $self->{rain}, $self->{thunder}, $self->{ash}, $self->{blight},
			  $self->{snow}, $self->{blizzard}) = unpack("C10", $buff);
		     } elsif ($blen == 8) {
			 ($self->{clear}, $self->{cloudy}, $self->{foggy},
			  $self->{overcast}, $self->{rain}, $self->{thunder},
			  $self->{ash}, $self->{blight}) = unpack("C8", $buff);
		     } else {
			 err("DECODER barfed on REGN.WEAT, Invalid length: $blen, expected 10 or 8!");
		     }
		     return($self);
		 },
		 encode => sub {
		     my($self) = @_;
		     if (exists $self->{blizzard}) {
			 $self->{_subbuf_} =
			     pack("C10",
				  $self->{clear}, $self->{cloudy}, $self->{foggy}, $self->{overcast},
				  $self->{rain}, $self->{thunder}, $self->{ash}, $self->{blight},
				  $self->{snow}, $self->{blizzard});
		     } else {
			 $self->{_subbuf_} = 
			     pack("C8",
				  $self->{clear}, $self->{cloudy}, $self->{foggy}, $self->{overcast},
				  $self->{rain}, $self->{thunder}, $self->{ash}, $self->{blight});
		     }
		     return($self);
		 },
		 #fieldnames => sub { grep {!/^_/} keys %{$_[0]}; }, # NOTYET check this works (and implement ordering)
		 tostr => sub {
		     my($self) = @_;
		     if (exists $self->{blizzard}) {
			 sprintf("Clear:%d  Cloudy:%d  Foggy:%d  Overcast:%d\n\tRain:%d  Thunder:%d  Ash:%d  Blight:%d\n\tSnow:%d  Blizzard:%d",
				 $self->{clear}, $self->{cloudy}, $self->{foggy}, $self->{overcast}, $self->{rain},
				 $self->{thunder}, $self->{ash}, $self->{blight}, $self->{snow}, $self->{blizzard});
		     } else {
			 sprintf("Clear:%d  Cloudy:%d  Foggy:%d  Overcast:%d\n\tRain:%d  Thunder:%d  Ash:%d  Blight:%d",
				 $self->{clear}, $self->{cloudy}, $self->{foggy}, $self->{overcast},
				 $self->{rain}, $self->{thunder}, $self->{ash}, $self->{blight});
		     }
		 },
		}],
	       [WNAM => [["name", "L"]], { rdflags => [qw(ess)] }],
	      ]],
     [REPA => [
	       [NAME => [["id", "Z*"]]],
	       [FNAM => [["name", "Z*"]]],
	       [ITEX => [["icon", "Z*"]]],
	       [MODL => [["model", "Z*"]]],
	       [RIDT => [["weight", "f"], ["value", "L"], ["uses", "L"], ["quality", "f"]]],
	       [SCRI => [["script", "Z*"]]],
	      ]],
     [SCPT => [
	       [SCHD => [["id", ["Z32", "a32"]], ["num_shorts", "L"], ["num_longs", "L"], ["num_floats", "L"],
			 ["data_size", "L"], ["local_var_size", "L"]]],
	       [RNAM => [["runflags", "H*"]], { rdflags => [qw(ess)] }],
	       [SCDT => [["bytecode", "H*:%.0s (compiled script code)"]]],
	       [SCTX => [["script_text", "a*"]],
		{ tostr => sub {
		      my $str = $_[0]->{script_text};
		      $str =~ tr/\r//d if ($^O eq 'linux');
		      "Script_Text:\n$str";
		  },
		}],
	       [SCVR => [["variables", "a*"]],
		{
		 tostr => sub { "Script_Variables: " . join(',', split(/\000/, $_[0]->{variables})) },
		}],
	       [SLCS => [["n_shorts", "L"], ["n_longs", "L"], ["n_floats", "L"]], { rdflags => [qw(ess)] }],
	       [SLFD => @RD_float_array_ess], # Script Localvar Float Data
	       [SLLD => @RD_long_array_ess], # Script Localvar Long Data
	       [SLSD => @RD_short_array_ess], # Script Localvar Short Data
	      ]],
     [SKIL => [
	       [INDX => [["id", "l", { lookup => \%SKILL }]]],
	       [DESC => @RD_Description],
	       [SKDT => [["attribute", "l", { lookup => \%ATTRIBUTE }],
			 ["specialization", "L", { lookup => \%SPECIALIZATION }],
			 (["use_value_#", "f"]) x 4], # TBD check
	       { tostr => sub {
		     my($self) = @_;
		     my $str = sprintf("Attribute:(%s)  Specialization:(%s)",
				       $ATTRIBUTE{$self->{attribute}},
				       $SPECIALIZATION{$self->{specialization}});
		     my $n = 1;
		     foreach my $action (@{$SKILL_ACTIONS{$self->{_id_}}}) {
			 $str .= sprintf("\n\tUse_Value_$n(%s):%0.2f", $action, $self->{"use_value_$n"});
			 $n++;
		     }
		     $str;
		 }}],
	      ]],
     [SNDG => [
	       [NAME => [["id", "Z*"]]],
	       [CNAM => [["creature_id", "Z*"]]],
	       [DATA => [["Type", "L", { lookup => \%SNDG_DATA }]]],
	       [SNAM => [["sound_id", "Z*"]]],
	      ]],
     [SOUN => [
	       [NAME => [["id", "Z*"]]],
	       [DATA => [["volume", "C"], ["min_range", "C"], ["max_range", "C"]],
	       { tostr => sub {
		     my($self) = @_;
		     sprintf("Volume:%0.2f  Min_Range:%d  Max_Range:%d",
			     $self->{volume}/255, $self->{min_range}, $self->{max_range});
		 }
	       }],
	       [FNAM => [["filename", "Z*"]]],
	      ]],
     [SPEL => [
	       [NAME => [["id", "Z*"]]],
	       [ENAM => @RD_Enchantment],
	       [FNAM => [["name", "Z*"]]],
	       [SPDT => [["type", "L", { lookup => \%SPEL_TYPE }], ["Spell_Cost", "L"],
			 ["flags", "L", { symflags => \%SPEL_FLAGS }]]],
	      ]],
     [SPLM => [			# ess, single record, no id
	       [NAME => [["name", "L"]]],
	       [CNAM => [["unknown_#", "L"], ["unknown_#", "Z*"]]],
	       [NAM0 => [["unknown_#", "C"]]],
	       [NPDT => [["name", ["Z32", "a32"]], ["unknown_#", "H16"], ["magnitude", "l"],
			 ["seconds_active", "f"], ["long_#", "l"], ["long_#", "l"]]],
	       [SPDT => [["type", "L", { lookup => \%SPLM_TYPE }], ["name", ["Z40", "a40"]], ["long_#", "L"], ["long_#", "L"],
			 ["caster", ["Z32", "a32"]], ["item", ["Z32", "a32"]], ["long_#", "L"], ["unknown_#", "H80"]]],
	       [TNAM => [["target", "Z*"]]],
	       [VNAM => [["unknown_#", "L"]]],
	       [XNAM => [["unknown_#", "C"]]],
	       [INAM => [["unknown_#", "H10"], ["name", "Z23"], ["unknown_#", "H*"]]],
	      ], { id => sub {'()'},
		   rdflags => [qw(ess)] }],
     [SSCR => [
	       [DATA => [["id", ["Z*", "a*"]]]],
	       [NAME => [["script", ["Z*", "a*"]]]],
	      ]],
     [STAT => [
	       [NAME => [["id", "Z*"]]],
	       [MODL => [["model", "Z*"]]],
	      ]],
     [STLN => [			# stolen items
	       [NAME => [["id", "Z*"]]],
	       [FNAM => [["owner_faction", "Z*"]]],
	       [ONAM => [["owner_actor", "Z*"]]],
	      ], { rdflags => [qw(ess)] }],
     [TES3 => [
	       [HEDR => [["version", "f"], ["is_master", "L"], ["author", "a32"],
			 ["description", "a256"], ["n_records", "L"]],
		{
		 tostr => sub { my($self) = @_;
				my $ver = sprintf("%0.2f", $self->{version});
				$ver =~ s/0+$//;
				my $description = $self->{description};
				$description =~ tr/\r//d if ($^O eq 'linux');
				my $author = $self->{author};
				# only chop off terminating nulls
				$description =~ s!\000+$!!;
				$author =~ s!\000+$!!;
				sprintf(qq{${MARGIN}Version:$ver  Is_Master:%s  Author:"%s"\n${MARGIN}Description:"%s"\n${MARGIN}N_Records:%d}, ($self->{is_master}) ? "True" : "False", $author, $description, $self->{n_records}); },
		}],
	       [MAST => [["master", "Z*"]]],
	       [DATA => [],
		{
		 decode => sub {
		     my($self, $buff, $parent) = @_;
		     $self->{_id_} = $parent->{_id_};
		     $self->{_subbuf_} = $buff;
		     my($l1, $l2) = unpack("L2", $buff);
		     $self->{length} = $l1 + ($l2 << 32);
		     dbg("TES3.DATA decoding  l1=$l1  l2=$l2  length=$self->{length}") if (DBG);
		     $self;
		 },
		 encode => sub {
		     my($self) = @_;
		     my $l1 = ($self->{length} & 0xffffffff);
		     my $ld = ($self->{length} - 0xffffffff);
		     my $l2 = ($ld > 0) ? $ld : 0;
		     dbg("TES3.DATA encoding  l1=$l1  l2=$l2  length=$self->{length}") if (DBG);
		     $self->{_subbuf_} = pack("L2", $l1, $l2);
		     return($self);
		 },
		 #fieldnames => sub { grep {!/^_/} keys %{$_[0]}; }, # NOTYET check this works (and implement ordering)
		 tostr => sub {
		     my($self) = @_;
		     return("Length:$self->{length}");
		 },
		}],
	       [GMDT => [["unknown_#", "H48"], ["current_cell", ["Z64", "a64"]], ["unknown_#", "L"], ["pc_name", ["Z32", "a32"]]],
		{ rdflags => [qw(ess)] }],
	       [SCRD => [(["unknown_#", "L"]) x 5], { rdflags => [qw(ess)] }],
	       [SCRS => [["screenshot", "H*"]], { rdflags => [qw(ess)] }],
	      ], {
		  id => sub { '()' },
		 }],
     [VFXM => [			# Visual FX (ess, single record, no id) ???
	       [VNAM => [(["unknown_#", "L"]) x 6,
			 ["short", "S"], ["unknown_#", "H44"],
			 ["name_#", ["Z36", "a36"]], ["name_#", ["Z68", "a68"]]]],
	      ], { id => sub {'()'},
		   rdflags => [qw(ess)] }],
     [WEAP => [
	       [NAME => [["id", "Z*"]]],
	       [ENAM => [["enchanting", "Z*"]]],
	       [FNAM => [["name", "Z*"]]],
	       [ITEX => [["icon", "Z*"]]],
	       [MODL => [["model", "Z*"]]],
	       [SCRI => [["script", "Z*"]]],
	       [WPDT => [["weight", "f"], ["value", "L"], ["type", "S", { lookup => \%WEAPON_TYPE }],
			 ["health", "S:%d\n\t"], ["speed", "f"],
			 ["reach", "f"], ["enchantment", "S:%d\n\t"], ["chop_min", "C"], ["chop_max", "C"],
			 ["slash_min", "C"], ["slash_max", "C:%d\n\t"], ["thrust_min", "C"], ["thrust_max", "C"],
			 ["flags", "L", { symflags => \%WEAPON_FLAGS }]]],
	      ]],
    );				# End of @RECDEFS

my %NAMED_TYPE;		    # those rectypes that use NAME subrec for their ID
my %FORMAT_SUBTYPE;	    # map unique fieldnames to a rectype:subrectype
my %NO_ID_TYPE =	    # rectypes that do not have an ID
    map {$_,1} (qw(TES3 FMAP GAME PCDT SPLM VFXM ));

# TES3::Record->new_from_recbuf "factory' for creating instances of the various record types
sub new_from_recbuf {
    my(undef, $rectype, $recbuf, $hdrflags) = @_;
    abort("undefined recbuf") unless defined $recbuf;
    bless({ _rectype_ => $rectype,
	    _hdrflags_ => $hdrflags,
	    _recbuf_ => $recbuf }, $rectype);
}

# factory that creates new TES3::Records from reading records from filehandle
my $hdr_size = 16;
sub new_from_input {
    my($class, $fh, $expected_type, $plugin) = @_;
    my $rec_hdr = "";
    my $n_read = read($fh, $rec_hdr, $hdr_size);
    if (not $n_read) {
	if (defined $n_read) {
	    return(undef);	# EOF
	} else {
	    abort(qq{Error on read() ($!)});
	}
    }
    if ($n_read != $hdr_size) {
	my $inp_offset = tell($fh) - $n_read;
	# TBD: this condition indicates file corruption. it would be good to attempt to rewind and scan ahead for next viable record
	abort(qq{new_from_input(): Read Error on header (at byte: $inp_offset): asked for $hdr_size bytes, got $n_read});
    }
    # I suspect $reclen2 is the high word of a 64-bit double long, it is effectively unused.
    my($rectype, $reclen, $reclen2, $hdrflags) = unpack("a4LLL", $rec_hdr);
    return(undef) unless defined $rectype;
    if (not $TES3::Record::RECTYPES{$rectype}) {
	my $inp_offset = tell($fh) - $n_read;
	err(qq{new_from_input(): Type Error (at byte: $inp_offset): Unknown Record Type: "$rectype"});
	# create a phony object for unknown record
	no strict "refs";
	my $method;
	$method = "${rectype}::decode";
	*$method = sub { return($_[0]); };
	$method = "${rectype}::id";
	*$method = sub { return("(unknown)"); };
	$method = "${rectype}::tostr";
	*$method = sub { return(""); };
    }
    if (defined($expected_type) and $expected_type ne $rectype) {
	my $inp_offset = tell($fh) - $n_read;
	msg(qq{new_from_input(): Type Error (at byte: $inp_offset): Expected: "$expected_type", got: "$rectype"});
    }
    my $recbuf = "";
    $n_read = read($fh, $recbuf, $reclen);
    if ($n_read != $reclen) {
	my $inp_offset = tell($fh) - $n_read;
	# TBD: this condition indicates file corruption. it would be good to attempt to rewind and scan ahead for next viable record
	abort(qq{new_from_input(): Read Error (at byte: $inp_offset, rec_type="$rectype"): asked for $reclen bytes, got $n_read});
    }
    return(bless({ _rectype_ => $rectype,
		   _hdrflags_ => $hdrflags,
		   _recbuf_ => $recbuf }, $rectype)); # return a TES3 object
} # new_from_input

# tr->copy()
# return a copy of current existing record (tr)
sub copy {
    my($self) = @_;
    my $new_tr = TES3::Record->new_from_recbuf($self->rectype, $self->recbuf, $self->hdrflags);
    $new_tr->decode;
    return($new_tr);
}

# tr->write_rec()
sub write_rec {
    my($self, $fh) = @_;
    if (DBG) {
	abort("null rectype: self=".Dumper($self)) if not defined $self->rectype;
	abort("null reclen: self=".Dumper($self)) if not defined $self->reclen;
	abort("null hdrflags: self=".Dumper($self)) if not defined $self->hdrflags;
    }
    $self->encode() unless (defined $self->{_recbuf_}); # TBD - should re-encode if modified! (but then new() should set modified flag???)
    print $fh pack("a4LLLa*", $self->rectype, $self->reclen, (my $reclen2 = 0), $self->hdrflags, $self->recbuf);
}

# tr->recbuf
sub recbuf { $_[0]->{_recbuf_} }

# tr->delete_subtype
# delete all subrecords of given type and sets _modified_ flag
sub delete_subtype {
    my($self, $subtype) = @_;
    $subtype = uc($subtype);
    if (delete $self->{SH}->{$subtype}) {
	$self->{SL} = [grep { $_->subtype ne $subtype } @{$self->{SL}}];
	$self->{_modified_} = 1;
    }
    return($self);
}

# tr->decode(force)
sub decode {
    my($self, $force) = @_;
    return($self) if (defined($self->{SH}) and not $force);
    # decode the subrecords for this record
    my $rectype = $self->{_rectype_};
    my $recbuf = $self->{_recbuf_} or abort("decode(): recbuf not set: ".Dumper($self));
    my @parts = eval { unpack("(a4L/a*)*", $recbuf); };
    if ($@) {
	# eval'ed unpack choked, so try a safer (slightly slower) decoder
	@parts = ();
	my $p = 0;
	my $reclen = length($recbuf);
	while ($p < $reclen) {
	    my($subtype, $sublen) = unpack("a4L", substr($recbuf, $p));
	    $p += 8;
	    if (defined $sublen) { # MultiMark.esp, I'm looking at you
		my $subbuf = substr($recbuf, $p, $sublen);
		if (defined $subbuf) {
		    push(@parts, $subtype, $subbuf);
		} else {
		    err("tr->decode(): ${rectype}.${subtype} has malformed subbuf");
		}
		$p += $sublen;
	    } else {
		if ($TES3::Record::RECTYPES{$rectype}->{$subtype}) {
		    err("tr->decode(): ${rectype}.${subtype} has malformed recbuf");
		} else {
		    err(qq{tr->decode(): $rectype has malformed subtype: "$subtype"});
		}
	    }
	}
    }
    $CURRENT_GROUP = undef;
    while (my($subtype, $subbuf) = splice(@parts, 0, 2)) {
	my $tsr = {};
	my $package = "${rectype}::${subtype}";
	bless($tsr, $package);
	$CURRENT_GROUP = $subtype
	    if ($TYPE_INFO{$rectype}->{group}->{$subtype}->{start});
	eval { $tsr->decode($subbuf, $self); };
	if ($@) {
	    if ($@ =~ /Can't locate object method/) {
		# magically create subrecord class for unknown subtypes
		err("Encountered unknown subtype: ${rectype}::${subtype}");
		no strict "refs";
		# tsr->tostr
		my $method = "${package}::tostr";
		*$method = sub {
		    use strict "refs";
		    unknown_data($_[0]->{_subbuf_});
		};
		use strict "refs";
		gen_subrec_methods($rectype, $subtype, [["unknown", "H*"]], {});
		$tsr->decode($subbuf, $self);
	    } else {
		die $@;
	    }
	}
	# When we encounter a subrecord (tsr) with fieldname "id" we use that as the official ID for the record
	# a few record types need custom methods to derive their unique record ID.
	$self->{_id_} = lc($tsr->{id}) if (defined $tsr->{id}); # Note! record IDs are lowercased for easy comparison!
	# inline $tr->append()
	push(@{$self->{SL}}, $tsr);
	push(@{$self->{SH}->{$subtype}}, $tsr);
    }
    return($self);
} # decode

# tr->encode()
sub encode {
    my($self) = @_;
    $self->{_recbuf_} = join("", map { pack("a4L/a*", $_->subtype, $_->encode()->subbuf) } $self->subrecs());
    return($self);
}

# tr->modified()
sub modified {
    ($_[1]) ? $_[0]->{_modified_} = 1 : $_[0]->{_modified_};
}

# tr->set()
sub set {
    my($self, $opt, $newval) = @_; # opt is hashref with keys: "i", "t", "f"
    unless (defined $newval) {
	abort(qq{Usage: set(\$option_hash, \$newvalue)
option_hash can have the keys: "i"(indices), "t"(subtype), or "f"(fields)

Example: set all fields named "count" to 0:
set({f=>"count"}, 0)
});
	return;
    }
    my @indices = defined($opt->{i}) ? @{$opt->{i}} : (0 .. $#{$self->{SL}});
    my $wanted_type = defined($opt->{t}) ? uc($opt->{t}) : "";
    foreach my $i (@indices) {	# narrow by indices
	my $tsr = $self->{SL}->[$i];
	my $subtype = $tsr->subtype;
	next if ($wanted_type and ($wanted_type ne $subtype)); # narrow by type
	if (defined($opt->{f})) { # narrow by field
	    my $key = lc($opt->{f});
	    if (defined($tsr->{$key})) {
		if ($tsr->{$key} ne $newval) {
		    $tsr->{$key} = $newval;
		    $self->{_modified_} = 1;
		}
	    }
	} else {
	    # set all fields
	    while (my($key, $val) = each %{$tsr}) {
		if ($val ne $newval) {
		    $tsr->{$key} = $newval;
		    $self->{_modified_} = 1;
		}
	    }
	}
    }
    return($self);
} # tr->set()

# tr->delete()  - delete matching subrecords
sub delete {
    my($self, $opt, $match) = @_; # opt is hashref with keys: "i", "t", "f"
    unless (defined $opt) {
	abort(qq{Usage: delete(\$option_hash, \$match)
option_hash can have the keys: "i"(indices), "t"(subtype), or "f"(fields)

match is a regular expression for matching values. If undef, then all values
match.

Example:
# delete subrecords with type WHGT
\$tr->delete({t=>'whgt'});
# delete subrecords with indices 2 and 3:
\$tr->delete({i=>[2,3]});
# delete all subrecords with fields named "spell" with value matching: "fireball":
\$tr->delete({f=>"spell"}, 'fireball');
});
	return;
    }
    $match = '.' unless defined $match;
    my @indices = defined($opt->{i}) ? @{$opt->{i}} : (0 .. $#{$self->{SL}});
    my $wanted_type = defined($opt->{t}) ? uc($opt->{t}) : "";
    foreach my $i (@indices) {	# narrow by indices
	my $tsr = $self->{SL}->[$i];
	my $subtype = $tsr->subtype;
	next if ($wanted_type and ($wanted_type ne $subtype)); # narrow by type
	if (defined($opt->{f})) { # narrow by field
	    # delete subrecords with fields that have matching values
	    my $key = lc($opt->{f});
	    if (defined($tsr->{$key})) {
		if ($tsr->{$key} =~ /$match/i) {
		    $tsr->{DELETED}++;
		    $self->{_modified_} = 1;
		}
	    }
	} else {
	    # delete subrecords that matched specified type
	    $tsr->{DELETED}++;
	    $self->{_modified_} = 1;
	}
    }
    if ($self->{_modified_}) {
	my @subrecs = @{$self->{SL}};
	delete $self->{SL};
	delete $self->{SH};
	foreach my $tsr (@subrecs) {
	    $self->append($tsr) unless ($tsr->{DELETED});
	}
    }
    return($self);
} # tr->delete()

# tr->dump()
sub dump {
    my($self, $opt) = @_; # opt is hashref with keys: "i", "t", "f"
    my $banner = qq{Record: @{[$self->rectype]} "@{[$self->id]}" Flags:@{[$self->hdrflagstr]}\n};
    my @indices = defined($opt->{i}) ? @{$opt->{i}} : (0 .. $#{$self->{SL}});
    my $wanted_type = defined($opt->{t}) ? uc($opt->{t}) : "";
    foreach my $i (@indices) {	# narrow by indices
	my $tsr = $self->{SL}->[$i];
	my $subtype = $tsr->subtype;
	next if ($wanted_type and ($wanted_type ne $subtype)); # narrow by type
	if (defined($opt->{f})) { # narrow by field
	    my $key = lc($opt->{f});
	    if (defined($tsr->{$key})) {
		if ($banner) { print $banner; undef $banner; }
		print "$key = $tsr->{$key}\n"; # print just that field
	    }
	} else {
	    if ($banner) { print $banner; undef $banner; }
	    print " [$i] $subtype: ",$tsr->tostr,"\n"; # print entire subrec
	}
    }
    return('');			# passthrough
}

# tr->split_groups()
sub split_groups {
    my($self) = @_;
    my @groups;
    my @this_group;
    foreach my $tsr ($self->subrecs()) {
	my $package = ref($tsr);
	dbg("split_groups: package is $package") if (DBG);
	if ($TYPE_INFO{$tsr->rectype}->{group}->{$tsr->subtype}->{start}) {
	    push(@groups, [@this_group]);
	    @this_group = ();
	}
	push(@this_group, $tsr);
    }
    push(@groups, [@this_group]); # collect last group
    return(\@groups);
}

# decode flags of a record field
my %flag_cache;
sub flags_tostr {
    my($flags, $flagdefs) = @_;
    return($flag_cache{"$flags.$flagdefs"}) if (defined $flag_cache{"$flags.$flagdefs"});
    my @list = ();
    while (my($name, $val) = each %$flagdefs) {
	next if (length($name) == 1);
	if (($flags & $val) or ($flags == 0 and $val == 0)) {
	    $name =~ s/([[:alnum:]]+)/ucfirst($1)/ge;
	    push(@list, $name);
	}
    }
    return($flag_cache{$flags.$flagdefs} = sprintf("0x%04x", $flags)." (".join(', ', sort @list).")");
}

sub color_tostr {
    my($color) = @_;
    my $r = $color & 0xff;
    my $g = (($color >> 8) & 0xff);
    my $b = (($color >> 16) & 0xff);
    if (VERBOSE) {
	return(sprintf("RGB=0x%0x ($r,$g,$b)", $color));
    } else {
	return("RGB=($r,$g,$b)");
    }
}

sub gen_custom {
    my($package, $optref) = @_;
    # generate custom methods and data structures for record classes and subclasses
    #dbg("gen_custom($package)") if (DBG);
    while (my($opt, $val) = each (%$optref)) {
	if (ref($val) eq 'CODE') {
	    # define a new method
	    no strict "refs";
	    my $method = "${package}::${opt}";
	    #dbg("defining custom method: $method") if (DBG);
	    *$method = do { no strict 'refs'; $val };
	} elsif ($opt eq 'rdflags') {
	    # define rdflags for recs and subrecs
	    $RDFLAGS{$package} = {map {$_,1} @{$val}};
	} elsif ($opt eq 'columns') {
	    $COLUMNS{$package} = $val;
	} else {
	    abort("Oops! Unknown record option: $opt = $val");
	}
    }
}

# NOTYET
sub pretty_columns {
    my($fnameref, $fmtref) = @_;
    my $print_format;
    my @fieldnames = @$fnameref;
    my @formats = @$fmtref;
    my %columns;
    foreach my $fname (@fieldnames) {
	my $column_name = $fname;
	$column_name =~ s/_\d+$//;
	push(@{$columns{$column_name}}, [$fname, shift(@formats)]);
    }
    foreach my $column_name (sort keys %columns) {
	# NOTYET
    }
    # return our pretty columns
    @{$fnameref} = @fieldnames;
    @{$fmtref} = @formats;
    return($print_format);
}

sub gen_subrec_methods {
    my($rectype, $subtype, $subdefref, $suboptref) = @_;
    $TES3::Record::RECTYPES{$rectype}->{$subtype}++;
    my $decode_pack_format;
    my $encode_pack_format;
    my $method;
    my $package = "${rectype}::${subtype}";
    gen_custom($package, $suboptref);
    if (@{$subdefref}) {
	# generic codec subs
	my $decode_pack_format;
	my $encode_pack_format;
	my @fieldnames;
	my %suffix_index;
	my @formats;
	my $lookup;
	my $symflags;
	foreach (@{$subdefref}) {
	    if (ref eq 'ARRAY') {
		my($fieldname, $fmt, $opt) = @{$_};
		$fieldname = lc($fieldname);
		$NAMED_TYPE{$rectype} = 1 if (($subtype eq 'NAME') and ($fieldname eq 'id'));
		if (my($basename) = ($fieldname =~ /^(.+)_\#$/)) { # when fieldname ends in: _#
		    # make a unique numbered fieldname for this record.
		    $fieldname = $basename . "_" . ++$suffix_index{$basename};
		}
		push(@fieldnames, $fieldname);
		my $pfmt;
		my $custom_format;
		if (ref($fmt) eq 'ARRAY') {
		    # different decoder/encoder defs
		    my($decode_fmt, $encode_fmt) = @$fmt;
		    ($decode_fmt, $custom_format) = split(/:/, $decode_fmt, 2);
		    $decode_pack_format .= ($pfmt = $decode_fmt);
		    $encode_pack_format .= $encode_fmt;
		} else {
		    # standard definition pair
		    ($fmt, $custom_format) = split(/:/, $fmt, 2);
		    $decode_pack_format .= ($pfmt = $fmt);
		    $encode_pack_format .= $fmt;
		}
		if (my $hashref = $opt->{lookup}) {
		    $lookup->{$fieldname} = $hashref;
		}
		if (my $hashref = $opt->{symflags}) {
		    $symflags->{$fieldname} = $hashref;
		}
		my $label = $fieldname;
		$label =~ s/([[:alnum:]]+)/ucfirst($1)/ge;
		$label =~ s/^(..)$/uc($1)/e;
		$label =~ s/_id$/_ID/i;
		$label =~ s/idx$/Idx/i;
		if (defined($custom_format)) {
		    push(@formats, ($custom_format) ? "$label:$custom_format" : $label);
		} else {
		    if ($pfmt =~ /^[aZH]/) {
			push(@formats, "$label:%s");
		    } elsif ($pfmt =~ /^f/) {
			push(@formats, "$label:\%0.2f");
		    } elsif ($pfmt =~ /^[LCS]/i) {
			if (defined $lookup->{$fieldname} or defined $symflags->{$fieldname}) {
			    push(@formats, "$label:%s");
			} else {
			    push(@formats, "$label:%d");
			}
		    } else {
			abort(qq{($package): Don't know how to stringify: "$pfmt"});
		    }
		}
	    } else {
		abort("$package: Invalid subrecord definition structure.");
	    }
	}
	no strict "refs";
	# tsr->decode - unpack fields of a subrec (_subbuf_) into our self hash
	unless ($package->can('decode')) {
	    $method = "${package}::decode";
	    *$method = sub {
		use strict "refs";
		my($self, $subbuf, $parent) = @_;
		$self->{_id_} = $parent->{_id_};
		my(@vals) = unpack($decode_pack_format, $self->{_subbuf_} = $subbuf);
		assert(scalar(@vals) == scalar(@fieldnames),
		       "decode(): number of field values (@vals) does not match number of field names (@fieldnames)") if (ASSERT);
		$self->{$_} = shift(@vals) foreach (@fieldnames);
		return($self);
	    };
	}

	# tsr->encode - pack fields of our self hash into a subrec buffer
	unless ($package->can('encode')) {
	    $method = "${package}::encode";
	    *$method = sub {
		use strict "refs";
		my($self) = @_;
		$self->{_subbuf_} = pack($encode_pack_format, map {$self->{$_}} @fieldnames);
		return($self);
	    };
	}

	# tsr->tostr - convert subrec to printable string
	unless ($package->can('tostr')) {
	    my $print_format;
#	    if (scalar(@fieldnames) > 3) {
#		$print_format = pretty_columns(\@fieldnames, \@formats);
#	    } else {
#		$print_format = join("  ", @formats);
#	    }
	    if (my $ncol = $COLUMNS{$package}) {
		my $width = int(78 / $ncol);
		my $n = 0;
		my @columnized_lines;
		my @line;
		my @fnames = @fieldnames;
		while (my $fmt = shift @formats) {
		    my $fname = shift @fnames;
		    my $fwidth = $width - length($fname);
		    $fmt =~ s/%\d*/\%${fwidth}/;
		    if ($FORMAT_INFO{$rectype}->{$subtype}->{$fname}->{BOL}) {
			if (@line) {
			    push(@columnized_lines, join("  ", @line));
			    @line = ();
			    $n = 0;
			}
		    }
		    push(@line, $fmt);
		    if (++$n == $ncol) {
			push(@columnized_lines, join("  ", @line));
			@line = ();
			$n = 0;
		    }
		}
		push(@columnized_lines, join("  ", @line)) if (@line);
		$print_format = join("\n\t", @columnized_lines);
	    } else {
		my $last_format = ' ';
		foreach my $fmt (@formats) {
		    if ($last_format =~ /\s$/) {
			$print_format .= $fmt;
		    } else {
			$print_format .= '  ' . $fmt;
		    }
		    $last_format = $fmt;
		}
	    }
	    my $check_lookups = grep { defined $lookup->{$_} } @fieldnames;
	    my $check_symflags = grep { defined $symflags->{$_} } @fieldnames;
	    $method = "${package}::tostr";
	    if ($check_lookups or $check_symflags) {
		*$method = sub {
		    use strict "refs";
		    my($self) = @_;
		    my @values;
		    foreach my $fieldname (@fieldnames) {
			if (defined $lookup->{$fieldname}) {
			    if (my $symval = $lookup->{$fieldname}->{$self->{$fieldname}}) {
				if (DBG) {
				    push(@values, "$self->{$fieldname} ($symval)");
				} else {
				    push(@values, "($symval)");
				}
			    } else {
				err(qq{${package}::tostr(ID=$self->{_id_}): do not know how to lookup symbolic value for: "$fieldname" ($self->{$fieldname})});
				push(@values, "$self->{$fieldname}");
			    }
			} elsif (defined $symflags->{$fieldname}) {
			    if (my $symval = flags_tostr($self->{$fieldname}, $symflags->{$fieldname})) {
				if (DBG) {
				    push(@values, "$self->{$fieldname} [$symval]");
				} else {
				    push(@values, "[$symval]");
				}
			    } else {
				err(qq{${package}::tostr(ID=$self->{_id_}): do not know how to calculate symbolic flags for: "$fieldname"});
				push(@values, "$self->{$fieldname}");
			    }
			} else {
			    push(@values, $self->{$fieldname});
			}
		    }
		    sprintf($print_format, @values);
		};
	    } else {
		*$method = sub {
		    use strict "refs";
		    my($self) = @_;
		    #warn qq{FORMAT: $print_format\n\tfieldnames: @fieldnames\n};
		    sprintf($print_format, map { $self->{$_} } @fieldnames);
		};
	    }
	}			# tsr->tostr

	# tsr->fieldnames
	unless ($package->can('fieldnames')) {
	    $method = "${package}::fieldnames";
	    *$method = sub { @fieldnames; };
	}
    } 				# finished processing list of subrec fields

    no strict "refs";

    # tsr->new(Hashinit, Parent)
    $method = "${package}::new";
    *$method = sub {
	use strict "refs";
	my($class, $hashref, $parent) = @_;
	$hashref->{_id_} = $parent->{_id_};
	bless($hashref, $class);
    };

    # tsr->subbuf()
    $method = "${package}::subbuf";
    *$method = sub {
	use strict "refs";
	return($_[0]->{_subbuf_});	# $_[0] is self
    };

    # tsr->fulltype()
    $method = "${package}::fulltype";
    *$method = sub { "${rectype}.${subtype}"; };

    # tsr->rectype()
    $method = "${package}::rectype";
    *$method = sub { $rectype; };

    # tsr->subtype()
    $method = "${package}::subtype";
    *$method = sub { $subtype; };
}				# gen_subrec_methods

sub gen_class {
    my($recdefref) = @_;
    my($rectype, $subrecdefs, $optref) = @{$recdefref};
    my(@recdefs) = @{$subrecdefs};
    gen_custom($rectype, $optref);
    my $method;
    eval {
	no strict 'refs';
	# make class "$rectype" inherit from TES3::Record
	@{"${rectype}::ISA"} = qw(TES3::Record);
    };
    foreach my $defref (@recdefs) {
	gen_subrec_methods($rectype, @{$defref});
    }
    gen_subrec_methods($rectype, DELE => [["DELETED", "L"]]); # TBD is this a reference number?

    no strict "refs";
    # definitions of methods for record classes

    # (RECTYPE)->new()
    # sets _modified_ flag (via append)
    $method = "${rectype}::new";
    *$method = sub {
	use strict "refs";
	my($rectype, $init) = @_;
	my $self = { _hdrflags_ => 0 }; # _recbuf_ is undef for write_rec to check
	bless($self, $rectype);
	#dbg("(RECTYPE)->new() dump init=".Dumper($init));
	if (defined $init and ref($init) eq 'ARRAY') {
	    if (ref($init->[0]) eq 'ARRAY') {
		# allow caller to pass in an array of structs to be constructed into subrec objects
		foreach my $subrecref (@$init) {
		    my($subtype, $subhash) = @{$subrecref};
		    no strict 'refs';
		    dbg("($rectype)->new(): subtype=$subtype") if (DBG);
		    assert(length($subtype) == 4, "expected a subtype") if (ASSERT);
		    $self->append("${rectype}::${subtype}"->new($subhash));
		}
	    } else {
		# or alternatively pass in array of subrec objects
		$self->append($_) foreach (@$init);
	    }
	}
	$self;
    };

    # (RECTYPE)->DESTROY()
    $method = "${rectype}::DESTROY";
    *$method = sub {
	use strict "refs";
	my($self) = @_;
	delete $self->{SL};
	delete $self->{SH};
    };

    # $tr->append(@SUBRECS)
    # appends given subrecords and sets _modified_ flag
    $method = "${rectype}::append";
    *$method = sub {
	use strict "refs";
	my($self, @subrecs) = @_;
	if (@subrecs) {
	    push(@{$self->{SL}}, @subrecs);
	    foreach my $tsr (@subrecs) {
		$tsr->{_id_} = $self->{_id_};
		push(@{$self->{SH}->{$tsr->subtype()}}, $tsr);
	    }
	    $self->{_modified_} = 1;
	}
	$self;
    };

    # $tr->rectype()
    $method = "${rectype}::rectype";
    *$method = sub { $rectype; };

    # $tr->hdrflagstr()
    unless ($rectype->can('hdrflagstr')) {
	$method = "${rectype}::hdrflagstr";
	*$method = sub {
	    use strict "refs";
	    flags_tostr($_[0]->{_hdrflags_}, \%HDR_FLAGS) if (defined $_[0]->{_hdrflags_});
	};
    }

    # $tr->hdrflags() - get/set _hdrflags_
    unless ($rectype->can('hdrflags')) {
	$method = "${rectype}::hdrflags";
	*$method = sub { ($_[1]) ? $_[0]->{_hdrflags_} = $_[1] : $_[0]->{_hdrflags_}; };
    }

    # tr->id() - get/set _id_
    unless ($rectype->can('id')) {
	$method = "${rectype}::id";
	*$method = sub { ($_[1]) ? $_[0]->{_id_} = $_[1] : $_[0]->{_id_} };
    }

    # tr->recbuf() - get/set _recbuf_
    unless ($rectype->can('recbuf')) {
	$method = "${rectype}::recbuf";
	*$method = sub { ($_[1]) ? $_[0]->{_recbuf_} = $_[1] : $_[0]->{_recbuf_}; };
    }

    # tr->reclen()
    unless ($rectype->can('reclen')) {
	$method = "${rectype}::reclen";
	*$method = sub { length($_[0]->{_recbuf_}); };
    }

    # tr->subrecs([WANTED_SUBTYPE])
    unless ($rectype->can('subrecs')) {
	$method = "${rectype}::subrecs";
	*$method = sub {
	    assert(defined $_[0]->{SL}, "undefined SL") if (ASSERT);
	    if ($_[1]) {
		my $subtype = uc($_[1]);
		return(grep { $_->subtype eq $subtype } @{$_[0]->{SL}});
	    } else {
		return(@{$_[0]->{SL}});
	    }
	};
    }

    # $tr->tostr()
    unless ($rectype->can('tostr')) {
	$method = "${rectype}::tostr";
	*$method = sub {
	    use strict "refs";
	    my($self) = @_;
	    my $dialstr = (($rectype eq 'INFO') and (defined $CURRENT_DIAL)) ? " ($CURRENT_DIAL)" : '';
	    qq{Record: $rectype "@{[$self->id]}"$dialstr Flags:@{[$self->hdrflagstr()]}\n} .
		join("\n", map { (($TYPE_INFO{$rectype}->{group}->{$_->subtype}->{start}) ?
				  $GROUPMARGIN : $MARGIN).$_->subtype().": ".$_->tostr() } @{$self->{SL}});
	};
    }

    # $tr->get() (actually "getfirst" might be more appropriate) (maybe getfirstfield)
    $method = "${rectype}::get";
    *$method = sub {
	use strict "refs";
	my($self, $subtype, $field) = @_;
	$subtype = uc($subtype);
	return(undef) unless (defined $self->{SH}->{$subtype});
	if (defined $field) {
	    # return a field
	    return($self->{SH}->{$subtype}->[0]->{lc($field)});
	} else {
	    # return entire subrec
	    return($self->{SH}->{$subtype}->[0]);
	}
    };

    # getfield is a convenience function that remembers seen subtypes for
    # given field names, so you can get a value from a record based on only
    # its field name without having to remember the subrecord type
    $method = "${rectype}::getfield";
    *$method = sub {
	use strict "refs";
	my($self, $field) = @_;
	$field = lc($field);
	if (my($subtype, $fieldname) = ($field =~ /^([^:])+:([^:]+)$/)) {
	    # explicit subtype: given
	    return($self->{SH}->{uc($subtype)}->[0]->{$fieldname});
	} elsif (defined($FORMAT_SUBTYPE{$rectype}->{$field})) {
	    return($self->{SH}->{$FORMAT_SUBTYPE{$rectype}->{$field}}->[0]->{$field});
	} else {
	    my @subtypes;
	    foreach my $subtype (keys %{$self->{SH}}) {
		if (defined($self->{SH}->{$subtype}->[0]->{$field})) {
		    push(@subtypes, $subtype);
		}
	    }
	    if (scalar(@subtypes) == 1) {
		# found unique field
		my $subtype = shift(@subtypes);
		$FORMAT_SUBTYPE{$rectype}->{$field} = $subtype;
		#print "DBG: ${rectype}::$subtype field=$field\n";
		return($self->{SH}->{$subtype}->[0]->{$field});
	    } elsif (@subtypes) {
		msgonce(qq{$rectype: Specified field name: "$field" is not unique. It occurs in: [@subtypes]
You could try: "$subtypes[0]:$field"});
	    }
	}
	msgonce(qq{$rectype: Unknown field name: "$field"});
	return("");
    };

    # $tr->getall() (maybe getallfields)
    $method = "${rectype}::getall";
    *$method = sub {
	use strict "refs";
	my($self, $subtype, $field) = @_;
	$subtype = uc($subtype);
	$field = lc($field);
	return() unless (defined $self->{SH}->{$subtype});
	if (defined $field) {
	    # return matching field from all subrecs of type
	    return(map { $_->{lc($field)} } @{$self->{SH}->{$subtype}});
	} else {
	    # return all complete subrecs of given type
	    return(@{$self->{SH}->{$subtype}});
	}
    };

} # gen_class

sub generate_classes {
    gen_class($_) foreach (@RECDEFS);
}

##################################################
# OBJECT MERGING METHODS
package LEVC;
our %user_delete_creature;
sub merge {
    my($self, $self_plugin, $merge_list) = @_;
    my($last_plugin, $last_tr) = @{$merge_list->[-1]};
    # strategy: last guy wins for List Flags
    my $last_list_flags = $last_tr->get('DATA', 'list_flags');
    # strategy: last guy wins for "Chance_None"
    my $last_chance = $last_tr->get('NNAM', 'chance_none');
    # interpret the initial leveled list definition
    my %levlist;
    my $firstdef;
    my $creature_id;
    foreach my $tsr ($self->subrecs) {
	my $subtype = $tsr->subtype;
	if ($subtype eq 'CNAM') {
	    $creature_id = $tsr->{creature_id};
	} elsif ($subtype eq 'INTV') {
	    # increment count of times this id appears at this level
	    $firstdef->{$creature_id}->{$tsr->{level}}++;
	}
    }
    foreach my $creature_id (keys %{$firstdef}) {
	foreach my $level (keys %{$firstdef->{$creature_id}}) {
	    $levlist{$creature_id}->{$level} = $firstdef->{$creature_id}->{$level};
	}
    }
    foreach (@{$merge_list}) {
	my($plugin, $tr) = @{$_};
	abort(qq{LEVC::merge: tried to merge "$tr->{_id_}" into "$self->{_id_}"\n})
	    if ($self->{_id_} ne $tr->{_id_});
	my $element_id;
	my $currdef;
	# For each item in list per plugin
	foreach my $tsr ($tr->subrecs) {
	    my $subtype = $tsr->subtype;
	    if ($subtype eq 'CNAM') {
		$creature_id = $tsr->{creature_id};
	    } elsif ($subtype eq 'INTV') {
		# increment count of times this id appears at this level
		$currdef->{$creature_id}->{$tsr->{level}}++;
	    }
	}
	# Additions/Changes to list
	foreach my $element_id (keys %{$currdef}) {
	    foreach my $level (keys %{$currdef->{$element_id}}) {
		if ((not defined $firstdef->{$element_id}) or
		    (not defined $firstdef->{$element_id}->{$level}) or
		    ($currdef->{$element_id}->{$level} != $firstdef->{$element_id}->{$level})) {
		    $levlist{$element_id}->{$level} = $currdef->{$element_id}->{$level};
		}
	    }
	}
	# Deletions from original definition
	foreach my $element_id (keys %{$firstdef}) {
	    if (not defined $currdef->{$element_id}) {
		delete $levlist{$element_id};
	    } else {
		foreach my $level (keys %{$firstdef->{$element_id}}) {
		    if (not defined $currdef->{$element_id}->{$level}) {
			delete $levlist{$element_id}->{$level};
		    }
		}
	    }
	}
    }
#    my $newrec = [[NAME => { id => $id }],
#		  [DATA => { list_flags => $last_list_flags }],
#		  [NNAM => { chance_none => $last_chance }],
#		  [INDX => { item_count => $indx }]];
#    my $merged_tr = LEVC->new($newrec);
#    return($merged_tr);
} # LEVC::merge

package LEVI;
our %user_delete_item;
sub merge {
    my($self, $merge_list) = @_;
    my %delete_item = map { lc, 1 } @opt_multipatch_delete_item;
} # LEVI::merge


### END OF TES3::Record
##################################################

### MAIN

package main;

BEGIN {
    Util->import(qw(abort assert dbg err mkpath msg msgonce prn RELOAD));
}

TES3::Record::generate_classes();

### MAIN CONSTANTS

use constant { MIN_TES3_PLUGIN_SIZE => 324 };

### MAIN GLOBALS (Miscellaneous)

my $T3 = new TES3::Util;
my $MASTER_ID;			# data loaded from masters
my $GLOBCHARS = '*?';		# for filename globbing on Windows
my $RECTYPE_LEN = 4;
my $DUMP_RAWOUT;

# plugins which are never cleaned
# name -> reason for not cleaning
my %CLEAN_PLUGIN =
    (
     'bloodmoon.esm'             => 'Bethesda Master',
     'fogpatch.esp'              => 'does not need cleaning',
     'gmst fix.esp'              => 'intentionally contain Evil GMSTs',
     'gmst vaccine.esp'          => 'intentionally contain Evil GMSTs',
     'mashed lists.esp'          => 'does not need cleaning',
     'merged_dialogs.esp'        => 'does not need cleaning, but you should delete it anyway',
     'merged_leveled_lists.esp'  => 'does not need cleaning, but you should use "tes3cmd multipatch" instead',
     'merged_objects.esp'        => 'does not need cleaning',
     'morrowind.esm'             => 'Bethesda Master',
     'multipatch.esp'            => 'does not need cleaning',
     'tribunal.esm'              => 'Bethesda Master',
    );

# plugins which do not need to be examined for multipatching
# name -> reason for not examining
my %NOPATCH_PLUGIN =
    (
     'bloodmoon.esm'             => 'Bethesda Master',
     'cellnamepatch.esp'         => 'does not need patching (obsolete)',
     'fogpatch.esp'              => 'does not need patching (obsolete)',
     'mashed lists.esp'          => 'does not need patching',
     'merged_dialogs.esp'        => 'does not need patching, but you should delete it anyway',
     'merged_leveled_lists.esp'  => 'does not need patching, but you should use "tes3cmd multipatch" instead',
     'merged_objects.esp'        => 'does not need patching',
     'morrowind.esm'             => 'Bethesda Master',
     'multipatch.esp'            => 'does not need patching',
     'tribunal.esm'              => 'Bethesda Master',
    );

# name -> seconds since the epoch
my %ORIGINAL_DATE =
    (
     'morrowind.bsa' => 1024695106,  # Fri Jun 21 17:31:46 2002
     'morrowind.esm' => 1024695106,  # Fri Jun 21 17:31:46 2002
     'tribunal.bsa'  => 1035940926,  # Tue Oct 29 20:22:06 2002
     'tribunal.esm'  => 1035940926,  # Tue Oct 29 20:22:06 2002
     'bloodmoon.bsa' => 1051807050,  # Thu May  1 12:37:30 2003
     'bloodmoon.esm' => 1051807050,  # Thu May  1 12:37:30 2003
    );

my $lint_no_expansion_funs;
my $lint_header_fields;
my $lint_modified_info;
my $lint_expansion_functions;

my %GMST_TYPE = ('i' => [INTV => 'integer'], 'f' => [FLTV => 'float'], 's' => [STRV => 'string']);

my @lint_tribunal_functions =
    (qw(AddToLevCreature
	AddToLevItem
	ClearForceJump
	ClearForceMoveJump
	ClearForceRun
	DisableLevitation
	EnableLevitation
	ExplodeSpell
	ForceJump
	ForceMoveJump
	ForceRun
	GetCollidingActor
	GetCollidingPC
	GetForceJump
	GetForceMoveJump
	GetForceRun
	GetPCJumping
	GetPCRunning
	GetPCSneaking
	GetScale
	GetSpellReadied
	GetSquareRoot
	GetWaterLevel
	GetWeaponDrawn
	GetWeaponType
	HasItemEquipped
	ModScale
	ModWaterLevel
	PlaceItem
	PlaceItemCell
	RemoveFromLevCreature
	RemoveFromLevItem
	SetDelete
	SetScale
	SetWaterLevel
      ));

my @lint_bloodmoon_functions =
    (qw(BecomeWerewolf
	GetPCInJail
	GetPCTraveling
	GetWerewolfKills
	IsWerewolf
	PlaceAtMe
	SetWerewolfAcrobatics
	TurnMoonRed
	TurnMoonWhite
	UndoWerewolf
      ));

my @lint_bethesda_leveled_lists =
    ('BM_Imperial Guard Random Weapon',
     'Imperial Guard Random Helmet',
     'Imperial Guard Random LPauldron',
     'Imperial Guard Random RPauldron',
     'Imperial Guard Random Shield',
     'Imperial Guard Random Skirt',
     'Imperial Guard Random Weapon',
     'bm_ex_berserkers',
     'bm_ex_felcoast',
     'bm_ex_felcoast_40',
     'bm_ex_felcoast_60',
     'bm_ex_felcoast_sleep',
     'bm_ex_hirforest',
     'bm_ex_hirforest_40',
     'bm_ex_hirforest_60',
     'bm_ex_hirforest_sleep',
     'bm_ex_horker_h20',
     'bm_ex_horker_lake',
     'bm_ex_isinplains',
     'bm_ex_isinplains_40',
     'bm_ex_isinplains_60',
     'bm_ex_isinplains_sleep',
     'bm_ex_moemountains',
     'bm_ex_moemountains_40',
     'bm_ex_moemountains_60',
     'bm_ex_moemountains_sleep',
     'bm_ex_reaver_archers',
     'bm_ex_reavers',
     'bm_ex_rieklingpatrols',
     'bm_ex_rieklingpatrols_20',
     'bm_ex_rieklingpatrols_40',
     'bm_ex_rieklingpatrols_60',
     'bm_ex_smugglers',
     'bm_ex_wolfpack',
     'bm_ex_wolfpack_20',
     'bm_ex_wolfpack_40',
     'bm_ex_wolfpack_60',
     'bm_frysehag_all',
     'bm_in_berserker_20',
     'bm_in_berserker_40',
     'bm_in_berserker_60',
     'bm_in_frysehag_20',
     'bm_in_frysehag_40',
     'bm_in_frysehag_8',
     'bm_in_icecaves',
     'bm_in_icecaves_40',
     'bm_in_icecaves_60',
     'bm_in_nordburial',
     'bm_in_nordburial_40',
     'bm_in_nordburial_60',
     'bm_random_nordictomb',
     'bm_random_nordsilver',
     'bm_random_riekling_loot',
     'bm_randomboots_smugglers',
     'bm_randomcuirass_smugglers',
     'bm_randomgreaves_smugglers',
     'bm_randomhealth_smugglers',
     'bm_randomhelmet_smugglers',
     'bm_randomleft_smugglers',
     'bm_randomloot_smugglers',
     'bm_randomright_smugglers',
     'bm_randomshield_smugglers',
     'bm_randomweapon_berserker',
     'bm_randomwpn_smugglers',
     'bm_werewolf_Connor',
     'bm_werewolf_wilderness01',
     'bm_werewolf_wilderness02',
     'bm_werewolf_wilderness03',
     'bm_werewolf_wilderness04',
     'bm_werewolf_wilderness05',
     'bm_werewolf_wilderness06',
     'bm_werewolf_wilderness07',
     'bm_werewolf_wilderness08',
     'bm_werewolf_wilderness09',
     'db_assassins',
     'ex_RedMtn_all_lev[+]0',
     'ex_RedMtn_all_lev[+]2',
     'ex_RedMtn_all_lev-2',
     'ex_RedMtn_all_sleep',
     'ex_ascadianisles_lev[+]0',
     'ex_ascadianisles_lev[+]2',
     'ex_ascadianisles_lev-1',
     'ex_ascadianisles_sleep',
     'ex_azurascoast_lev[+]0',
     'ex_azurascoast_lev[+]2',
     'ex_azurascoast_lev-1',
     'ex_azurascoast_sleep',
     'ex_bittercoast_lev[+]0',
     'ex_bittercoast_lev[+]2',
     'ex_bittercoast_lev-1',
     'ex_bittercoast_sleep',
     'ex_grazelands_lev[+]0',
     'ex_grazelands_lev[+]2',
     'ex_grazelands_lev-1',
     'ex_grazelands_sleep',
     'ex_molagmar_lev[+]0',
     'ex_molagmar_lev[+]2',
     'ex_molagmar_lev-1',
     'ex_molagmar_sleep',
     'ex_sheogorad_lev[+]0',
     'ex_sheogorad_lev[+]2',
     'ex_sheogorad_lev-1',
     'ex_sheogorad_sleep',
     'ex_shore_all_lev[+]0',
     'ex_shore_all_lev[+]2',
     'ex_shore_all_lev-2',
     'ex_shore_cliffracer_lev[+]0',
     'ex_shore_cliffracer_lev[+]2',
     'ex_shore_cliffracer_lev-2',
     'ex_shore_mudcrab',
     'ex_westgash_lev[+]0',
     'ex_westgash_lev[+]2',
     'ex_westgash_lev-1',
     'ex_westgash_sleep',
     'ex_wild_all_lev[+]0',
     'ex_wild_all_lev[+]2',
     'ex_wild_all_lev-1',
     'ex_wild_all_sleep',
     'ex_wild_netch_lev[+]0',
     'ex_wild_netch_lev[+]2',
     'ex_wild_netch_lev-1',
     'ex_wild_rat_lev[+]0',
     'ex_wild_rat_lev[+]2',
     'ex_wild_rat_lev-2',
     'goblin_health',
     'goblin_weapons_random',
     'h2o_all_lev[+]0',
     'h2o_all_lev[+]2',
     'h2o_all_lev-2',
     'h2o_slaughterfish',
     'in_6th_all_lev[+]0',
     'in_6th_all_lev[+]2',
     'in_6th_all_lev-2',
     'in_6th_ash_lev[+]0',
     'in_6th_ash_lev[+]2',
     'in_6th_ash_lev-2',
     'in_cave_alit_lev[+]0',
     'in_cave_alit_lev[+]2',
     'in_cave_alit_lev-1',
     'in_cave_all_lev[+]0',
     'in_cave_all_lev[+]2',
     'in_cave_all_lev-1',
     'in_cave_kagouti_lev[+]0',
     'in_cave_kagouti_lev[+]2',
     'in_cave_kagouti_lev-1',
     'in_cave_nix_lev[+]0',
     'in_cave_nix_lev[+]2',
     'in_cave_nix_lev-1',
     'in_dae_all_lev[+]0',
     'in_dae_all_lev[+]2',
     'in_dae_all_lev-2',
     'in_dae_atronach_lev[+]0',
     'in_dae_atronach_lev[+]2',
     'in_dae_atronach_lev-2',
     'in_dae_clanfear_lev[+]0',
     'in_dae_clanfear_lev[+]2',
     'in_dae_clanfear_lev-2',
     'in_dae_dremora_lev[+]0',
     'in_dae_dremora_lev[+]2',
     'in_dae_dremora_lev-2',
     'in_durzogs',
     'in_dwe_all_lev[+]0',
     'in_dwe_all_lev[+]2',
     'in_dwe_all_lev-2',
     'in_dwe_all_tribunal',
     'in_dwe_cent_lev[+]0',
     'in_dwe_cent_lev[+]2',
     'in_dwe_cent_lev-2',
     'in_egg_all_lev[+]0',
     'in_egg_all_lev[+]2',
     'in_egg_all_lev-1',
     'in_egg_kwama_blight_lev[+]0',
     'in_egg_kwama_blight_lev[+]2',
     'in_egg_kwama_blight_lev-1',
     'in_egg_kwama_lev[+]0',
     'in_egg_kwama_lev[+]2',
     'in_egg_kwama_lev-1',
     'in_egg_kwama_mined',
     'in_egg_scrib_lev[+]0',
     'in_egg_scrib_lev[+]2',
     'in_egg_scrib_lev-1',
     'in_goblins',
     'in_tomb_all_lev[+]0',
     'in_tomb_all_lev[+]2',
     'in_tomb_all_lev-2',
     'in_tomb_all_lev_trib',
     'in_tomb_bone_lev[+]0',
     'in_tomb_bone_lev[+]2',
     'in_tomb_bone_lev-2',
     'in_tomb_skele_lev[+]0',
     'in_tomb_skele_lev[+]2',
     'in_tomb_skele_lev-2',
     'in_vamp_cattle',
     'in_vamp_cattle_aun',
     'in_vamp_cattle_ber',
     'in_vamp_cattle_qua',
     'l_b_Bandit_goods',
     'l_b_amulets',
     'l_b_loot_tomb',
     'l_b_loot_tomb01',
     'l_b_loot_tomb02',
     'l_b_loot_tomb03',
     'l_b_rings',
     'l_m_amulets',
     'l_m_armor',
     'l_m_armor_boots',
     'l_m_armor_bracers',
     'l_m_armor_cuirass',
     'l_m_armor_gauntlet',
     'l_m_armor_helmet',
     'l_m_armor_shields',
     'l_m_belts',
     'l_m_enchantitem_hlaalu_rank0',
     'l_m_enchantitem_hlaalu_rank4',
     'l_m_enchantitem_hlaalu_rank6',
     'l_m_enchantitem_imperial_rank0',
     'l_m_enchantitem_redoran_rank2',
     'l_m_enchantitem_redoran_rank4',
     'l_m_enchantitem_redoran_rank6',
     'l_m_enchantitem_redoran_rank8',
     'l_m_enchantitem_telvanni_rank01',
     'l_m_enchantitem_telvanni_rank6',
     'l_m_enchantitem_telvanni_rank8',
     'l_m_enchantitem_temple_rank0_1',
     'l_m_enchantitem_temple_rank0_2',
     'l_m_enchantitem_temple_rank4',
     'l_m_enchantitem_temple_rank6',
     'l_m_enchantitem_temple_rank8_1',
     'l_m_enchantitem_temple_rank8_2',
     'l_m_potion',
     'l_m_potion_h',
     'l_m_rings',
     'l_m_wpn_melee',
     'l_m_wpn_melee_axe',
     'l_m_wpn_melee_blunt',
     'l_m_wpn_melee_long blade',
     'l_m_wpn_melee_short blade',
     'l_m_wpn_melee_spear',
     'l_m_wpn_missle',
     'l_m_wpn_missle_arrow',
     'l_m_wpn_missle_bolt',
     'l_n_amulet',
     'l_n_apparatus',
     'l_n_armor',
     'l_n_armor_boots',
     'l_n_armor_bracers',
     'l_n_armor_cuirass',
     'l_n_armor_gauntlet',
     'l_n_armor_greaves',
     'l_n_armor_helmet',
     'l_n_armor_pauldron',
     'l_n_armor_shields',
     'l_n_lockpicks',
     'l_n_probe',
     'l_n_repair item',
     'l_n_rings',
     'l_n_smuggled_goods',
     'l_n_soul gem',
     'l_n_wpn_melee',
     'l_n_wpn_melee_axe',
     'l_n_wpn_melee_blunt',
     'l_n_wpn_melee_long blade',
     'l_n_wpn_melee_short blade',
     'l_n_wpn_melee_spear',
     'l_n_wpn_melee_tomb',
     'l_n_wpn_missle',
     'l_n_wpn_missle_arrow',
     'l_n_wpn_missle_bolt',
     'l_n_wpn_missle_bow',
     'l_n_wpn_missle_thrown',
     'l_n_wpn_missle_xbow',
     'l_vamp_cattle',
     'misc_com_redware_bowl',
     'random ashlander weapon',
     'random ebony weapon',
     'random excellent melee weapon',
     'random gold',
     'random gold_lev_05',
     'random gold_lev_10',
     'random gold_lev_15',
     'random gold_lev_20',
     'random orcish armor',
     'random_Golden_saint_shield',
     'random_Golden_saint_weapon',
     'random_adamantium',
     'random_alchemy_diff',
     'random_alit_hide',
     'random_ampoule_pod',
     'random_armor_bonemold',
     'random_armor_chitin',
     'random_armor_fur',
     'random_armor_glass',
     'random_armor_iron',
     'random_armor_netch_leather',
     'random_armor_steel',
     'random_ash_salts',
     'random_ash_yam',
     'random_bear_pelt',
     'random_belladonna_plant',
     'random_belladonna_spriggan',
     'random_bittergreen_petals',
     'random_black_anther',
     'random_black_lichen',
     'random_boar_leather',
     'random_bonemeal',
     'random_book_dunmer',
     'random_book_imperial_dunmer',
     'random_book_imperial_hlaalu',
     'random_book_skill',
     'random_book_wizard_all',
     'random_book_wizard_evil',
     'random_bulbs',
     'random_bunglers_bane',
     'random_cabbage',
     'random_chokeweed',
     'random_coda_flower',
     'random_com_kitchenware',
     'random_comberry',
     'random_common_de_fclothes_01',
     'random_common_de_mclothes_01',
     'random_coprinus',
     'random_corkbulb_root',
     'random_cornberry',
     'random_corprus_weepings',
     'random_crab_meat',
     'random_daedra_heart',
     'random_daedra_skin',
     'random_daedric_weapon',
     'random_de_blueware_01',
     'random_de_cheapfood_01_nc',
     'random_de_cheapfood_01_ne',
     'random_de_pants',
     'random_de_pos_01',
     'random_de_pos_01_nc',
     'random_de_robe',
     'random_de_shirt',
     'random_de_shoes_common',
     'random_de_weapon',
     'random_diamond',
     'random_dreugh_wax',
     'random_drinks_01',
     'random_drinks_nord',
     'random_drinksndrugs_imp',
     'random_dwarven_all',
     'random_dwarven_ingredients',
     'random_dwarven_misc',
     'random_dwemer_armor',
     'random_dwemer_coins',
     'random_dwemer_weapon',
     'random_ebony',
     'random_ectoplasm',
     'random_expensive_de_fclothes_02',
     'random_expensive_de_mclothes_02',
     'random_exquisite_de_fclothes1',
     'random_exquisite_de_mclothes1',
     'random_extravagant_de_fclothes1',
     'random_extravagant_de_mclothes1',
     'random_fire_petal',
     'random_fire_salts',
     'random_food',
     'random_frost_salts',
     'random_gem',
     'random_ghoul_heart',
     'random_glass_weapon',
     'random_gold_kanet',
     'random_golden_sedge',
     'random_gravetar',
     'random_green_lichen',
     'random_guar_hide',
     'random_hackle-lo_leaf',
     'random_heartwood',
     'random_heather',
     'random_holly',
     'random_horker_tusk',
     'random_hound_meat',
     'random_hypha_facia',
     'random_imp_armor',
     'random_imp_silverware',
     'random_imp_weapon',
     'random_ingredient',
     'random_ingredient_diff',
     'random_iron_fur_armor',
     'random_iron_weapon',
     'random_kagouti_hide',
     'random_kresh_fiber',
     'random_kwama egg',
     'random_kwama_cuttle',
     'random_loot_bonewalker',
     'random_loot_bonewalker_greater',
     'random_loot_special',
     'random_marshmerrow',
     'random_moon_sugar',
     'random_muck',
     'random_netch_leather',
     'random_noble_sedge',
     'random_nordic_weapons',
     'random_nordictomb_rare',
     'random_orcish_weapons',
     'random_pearl',
     'random_pos',
     'random_potion_bad',
     'random_racer_plumes',
     'random_rat_meat',
     'random_rawglass',
     'random_red_guard_cloth_01',
     'random_red_lichen',
     'random_riekling_loot',
     'random_roobrush',
     'random_russula',
     'random_rye',
     'random_saltrice',
     'random_scales',
     'random_scamp_skin',
     'random_scathecraw',
     'random_scrap_metal',
     'random_scrib_jelly',
     'random_scroll_all',
     'random_shalk_resin',
     'random_silver_weapon',
     'random_skooma',
     'random_smuggler_1-5',
     'random_smuggler_11[+]',
     'random_smuggler_6-10',
     'random_snowbear_pelt',
     'random_snowwolf_pelt',
     'random_spines',
     'random_stalks',
     'random_steel_weapon',
     'random_stoneflower_petals',
     'random_sweetpulp',
     'random_timsa',
     'random_trama_root',
     'random_vampire_dust',
     'random_void_salts',
     'random_weapon_melee_basic',
     'random_wickwheat',
     'random_willow_anther',
     'random_wolf_pelt');

my @lint_bethesda_doors =
    ('BM_IC_door_01',
     'BM_IC_door_pelt',
     'BM_IC_door_pelt_dark',
     'BM_IC_door_pelt_wolf',
     'BM_KA_door',
     'BM_KA_door_dark',
     'BM_KA_door_dark_02',
     'BM_KA_door_dark_SG',
     'BM_KA_door_dark_udyr',
     'BM_KarstCav_Door',
     'BM_kartaag_Door',
     'BM_mazegate_01',
     'BM_mazegate_02',
     'BM_mazegate_03',
     'CharGen Exit Door',
     'CharGen_cabindoor',
     'CharGen_ship_trapdoor',
     'EX_MH_door_02',
     'EX_MH_door_02_ignatius',
     'EX_MH_door_02_sadri',
     'EX_MH_door_02_velas',
     'EX_MH_temple_door_01',
     'EX_MH_temple_door_01_ch',
     'Ex_BM_tomb_door_01',
     'Ex_BM_tomb_door_02',
     'Ex_BM_tomb_door_03',
     'Ex_BM_tomb_door_skaalara',
     'Ex_Cave_Door_01_Koal',
     'Ex_DE_ship_cabindoor',
     'Ex_Dae_door_static',
     'Ex_De_SN_Gate',
     'Ex_De_Shack_Door',
     'Ex_MH_Door_01',
     'Ex_MH_Palace_gate',
     'Ex_MH_Pav_Gate_Door',
     'Ex_MH_Pav_Ladder_01',
     'Ex_MH_sewer_trapdoor_01',
     'Ex_MH_sewer_trapdoor_sadri',
     'Ex_MH_swr_trapdr_blkd',
     'Ex_S_door',
     'Ex_S_door_double',
     'Ex_S_door_double_GH',
     'Ex_S_door_double_fixed',
     'Ex_S_door_double_fixing',
     'Ex_S_door_rigmor',
     'Ex_S_door_rigmor2',
     'Ex_V_cantondoor_01',
     'Ex_V_palace_grate_02',
     'Ex_co_ship_cabindoor',
     'Ex_colony_bardoor',
     'Ex_colony_door01.NIF',
     'Ex_colony_door01_1B.NIF',
     'Ex_colony_door02',
     'Ex_colony_door02_1',
     'Ex_colony_door02_2',
     'Ex_colony_door02b_2',
     'Ex_colony_door03',
     'Ex_colony_door03 int',
     'Ex_colony_door03_1',
     'Ex_colony_door03_1_uryn',
     'Ex_colony_door03_2',
     'Ex_colony_door03_4',
     'Ex_colony_door03_4a',
     'Ex_colony_door03_int',
     'Ex_colony_door04',
     'Ex_colony_door04_1',
     'Ex_colony_door04_2',
     'Ex_colony_door04_2b',
     'Ex_colony_door04_3',
     'Ex_colony_door04b_3',
     'Ex_colony_door04c_3',
     'Ex_colony_door05',
     'Ex_colony_door05_2',
     'Ex_colony_door05_3',
     'Ex_colony_door05_int',
     'Ex_colony_door05_int_a',
     'Ex_colony_door05_int_b',
     'Ex_colony_door05_int_c',
     'Ex_colony_door05a_4',
     'Ex_colony_door05b_4',
     'Ex_colony_door05c_4',
     'Ex_colony_door06',
     'Ex_colony_door07',
     'Ex_colony_door08',
     'Ex_colony_minedoor',
     'Ex_imp_loaddoor_02',
     'Ex_redoran_hut_01_a',
     'In_DB_door01',
     'In_DB_door_oval',
     'In_DB_door_oval_02',
     'In_DB_door_oval_relvel',
     'In_DE_LLshipdoor_Large',
     'In_De_Shack_Trapdoor',
     'In_De_Shack_Trapdoor_01',
     'In_Hlaalu_Door_01',
     'In_MH_Pav_Ladder',
     'In_MH_door_01',
     'In_MH_door_01_velas',
     'In_MH_door_02',
     'In_MH_door_02_bar1_uni',
     'In_MH_door_02_bar2_uni',
     'In_MH_door_02_bar3_uni',
     'In_MH_door_02_bar4_uni',
     'In_MH_door_02_chapel',
     'In_MH_door_02_hels_uni',
     'In_MH_door_02_play',
     'In_MH_door_02_throne1',
     'In_MH_door_02_throne2',
     'In_MH_jaildoor_01',
     'In_MH_trapdoor_01',
     'In_M_sewer_door_01',
     'In_OM_door_round',
     'In_S_door',
     'In_impsmall_d_hidden_01',
     'In_thirsk_door',
     'In_thirsk_door_main_1',
     'In_thirsk_door_main_1_b',
     'In_thirsk_door_main_2',
     'In_thirsk_door_main_2_b',
     'Indalen_closet_door',
     'PrisonMarker',
     'Rent_Ghost_Dusk_Door',
     'Rent_MH_Guar_Door',
     'Rent_colony_door',
     'Velothi_Sewer_Door',
     'chargen customs door',
     'chargen door captain',
     'chargen door exit',
     'chargen door hall',
     'chargen_shipdoor',
     'chargendoorjournal',
     'clutter_whouse_door_01',
     'clutter_whouse_door_02',
     'door_cavern_doors00',
     'door_cavern_doors00_velas',
     'door_cavern_doors10',
     'door_cavern_doors20',
     'door_cavern_vassir_un',
     'door_dwe_00_exp',
     'door_dwrv_double00',
     'door_dwrv_double01',
     'door_dwrv_inner00',
     'door_dwrv_load00',
     'door_dwrv_loaddown00',
     'door_dwrv_loadup00',
     'door_dwrv_main00',
     'door_load_darkness00',
     'door_ravenrock_mine',
     'door_sotha_imp_door',
     'door_sotha_load',
     'door_sotha_mach_door',
     'door_sotha_mach_door2',
     'door_sotha_pre_load',
     'ex_BM_ringdoor',
     'ex_S_door_rounded',
     'ex_S_fence_gate',
     'ex_S_fence_gate_uni',
     'ex_ashl_door_01',
     'ex_ashl_door_02',
     'ex_cave_door_01',
     'ex_co_ship_trapdoor',
     'ex_common_door_01',
     'ex_common_door_balcony',
     'ex_dae_door_load_oval',
     'ex_de_ship_trapdoor',
     'ex_emp_tower_01_a',
     'ex_emp_tower_01_b',
     'ex_h_pcfort_exdoor_ 01',
     'ex_h_pcfort_exdoor_ 02',
     'ex_h_pcfort_exdoor_ 03',
     'ex_h_pcfort_exdoor_ 03-3',
     'ex_h_pcfort_trapdoor_01-2',
     'ex_h_trapdoor_01',
     'ex_imp_loaddoor_01',
     'ex_imp_loaddoor_03',
     'ex_nord_door_01',
     'ex_nord_door_01-back',
     'ex_nord_door_01_ignatius',
     'ex_nord_door_01_ignatius1',
     'ex_nord_door_02',
     'ex_nord_door_gyldenhul',
     'ex_nord_door_lair',
     'ex_nord_door_wolf',
     'ex_r_pcfort_d_01',
     'ex_r_pcfort_d_01-2',
     'ex_r_pcfort_d_01-3',
     'ex_r_pcfort_d_02',
     'ex_r_trapdoor_01',
     'ex_redoran_barracks_door',
     'ex_t_door_01',
     'ex_t_door_01_pc_hold_a',
     'ex_t_door_01_pc_hold_b',
     'ex_t_door_02',
     'ex_t_door_02_pc_hold_a',
     'ex_t_door_02_pc_hold_b',
     'ex_t_door_slavepod_01',
     'ex_t_door_sphere_01',
     'ex_t_door_stone_large',
     'ex_v_palace_grate_01',
     'ex_velothi_loaddoor_01',
     'ex_velothi_loaddoor_02',
     'ex_velothicave_door_01',
     'ex_velothicave_door_03',
     'ex_vivec_grate_01',
     'hlaal_loaddoor_01',
     'hlaalu_loaddoor_ 02',
     'hlaalu_loaddoor_ 02_balyn',
     'in_ar_door_01',
     'in_ashl_door_01',
     'in_ashl_door_02',
     'in_ashl_door_02_sha',
     'in_c_door_arched',
     'in_c_door_wood_square',
     'in_ci_door_01',
     'in_ci_door_01_indoor',
     'in_com_trapbottom_01',
     'in_com_traptop_01',
     'in_dae_door_01',
     'in_de_shack_door',
     'in_de_ship_cabindoor',
     'in_de_shipdoor_toplevel',
     'in_h_trapdoor_01',
     'in_hlaalu_door',
     'in_hlaalu_door_uni',
     'in_hlaalu_loaddoor_01',
     'in_hlaalu_loaddoor_02',
     'in_impsmall_d_cave_01',
     'in_impsmall_door_01',
     'in_impsmall_door_01_shrine',
     'in_impsmall_door_jail_01',
     'in_impsmall_loaddoor_01',
     'in_impsmall_trapdoor_01a',
     'in_m_sewer_trapdoor_01',
     'in_m_sewer_trapdoor_01_blkd',
     'in_r_s_door_01',
     'in_r_trapdoor_01',
     'in_redoran_barrack_door',
     'in_redoran_hut_door_01',
     'in_redoran_ladder_01',
     'in_strong_vaultdoor00',
     'in_strong_vaultdoor_tela_UNIQUE',
     'in_t_door_small',
     'in_t_door_small_load',
     'in_t_housepod_door_exit',
     'in_t_l_door_01',
     'in_t_s_plain_door',
     'in_v_s_jaildoor_01',
     'in_v_s_jaildoor_frelene',
     'in_v_s_trapdoor_01',
     'in_v_s_trapdoor_02',
     'in_velothismall_ndoor_01',
     'in_velothismall_ndoor_01_jeanne',
     'in_velothismall_ndoor_agrippina',
     'in_vivec_grate_door_01',
     'pelagiad_halfway_room',
     'rent_balmora_council_door',
     'rent_balmora_eight_door',
     'rent_balmora_lucky_door',
     'rent_balmora_south_door',
     'rent_caldera_shenk_door',
     'rent_ebon_six_door',
     'rent_maargan_andus_door',
     'rent_vivec_black_door',
     'rent_vivec_flower_door',
     'rent_vivec_lizard_door',
     'smora_fara_door',
     'vivec_grate_door_02');

# JMS - "do" seems to behave differently under Windows now, so this code is busted
#	unless (do $program_file) {	# load perl file --- BUSTED!
#	    abort("Error processing $program_file ($@)") if ($@);
#	}
sub load_perl {
    my($program_file) = (@_);
    if ($program_file) {
	dbg("loading program-file: $program_file") if (DBG);
	my $prog;
	if (open(PROG, "<", $program_file)) {
	    local $/ = undef;
	    $prog = join("", <PROG>);
	    close(PROG);
	} else {
	    abort(qq{Error opening "$program_file" ($!)});
	}
	my $value = eval($prog);
	abort("Error processing $program_file ($@)") if ($@);
	return($value);
    }
}

my $Usage1 = qq{Usage: tes3cmd COMMAND OPTIONS plugin...

VERSION: $::VERSION

tes3cmd is a powerful low-level command line tool that can examine, edit, and
delete records from a TES3 plugin for Morrowind. It can also generate various
patches and clean plugins too.

COMMANDS
};
my $Usage2 = qq{
FOR HELP ON INDIVIDUAL COMMANDS:

  tes3cmd help <command>

GENERAL HELP:

OPTIONS given to commands may be abbreviated, as long as the abbreviations are
unique.

Commands mostly for Morrowind Players: "clean", "header --synchronize". and
"multipatch" (also see: the "fixit" command which rolls these together).

Commands mostly for Modders: "dump", "esp/esm", "modify", and "delete".

tes3cmd uses Perl regular expressions for string matching, the full
documentation can be found here:
  http://perldoc.perl.org/perlre.html
You should at least be aware that the characters "\\.?*+|^\$()[]{}" have
special meaning in a regular expression and that they are unlike characters
used for matching on a Windows command line.
};


### MAIN COMMAND DISPATCH TABLE
my %COMMAND;
%COMMAND =
    (
     active =>
     { description => qq{Add/Remove/List Plugins in your load order},
       options => [@STDOPT,
		   'off' => \$opt_active_off,
		   'on'  => \$opt_active_on],
       preprocess => \&cmd_active,
       usage => qq{Usage: tes3cmd active OPTIONS plugin1.esp [plugin2.esp...]

OPTIONS:
 --debug
	turn on debug messages

 --off
	deactivate given plugins

 --on
	activate given plugins

DESCRIPTION:

Activates/Deactivates the specified plugins. When no options are specified,
just prints current active load order.

},
     },

     clean =>
     { description => qq{Clean plugins of Evil GMSTs, junk cells, and more},
       options => [@STDOPT,
		   @MODOPT,
		   'active',
		   'all'           => \$opt_clean_all,
		   'ignore-plugin=s@',
		   'instances'     => \$opt_clean_instances,
		   'cell-params'   => \$opt_clean_cell_params,
		   'dups'          => \$opt_clean_dups,
		   'gmsts'         => \$opt_clean_gmsts,
		   'junk-cells'    => \$opt_clean_junk_cells,
		   'no-cache',
		   'output-dir',
		   'replace'       => \$opt_overwrite, # alias for backwards compatibility
		   'overwrite'],

       preprocess => sub {
	   unless ($opt_clean_instances or $opt_clean_cell_params or $opt_clean_dups or $opt_clean_gmsts or $opt_clean_junk_cells) {
	       # turn on all safe cleaning options if none are selected.
	       $opt_clean_instances = $opt_clean_cell_params = $opt_clean_dups = $opt_clean_gmsts = $opt_clean_junk_cells = 1;
	   }
	   if ($opt_clean_all) {
	       # turn on all cleaning options (in future we may add some that are possibly unsafe)
	       $opt_clean_instances = $opt_clean_cell_params = $opt_clean_dups = $opt_clean_gmsts = $opt_clean_junk_cells = 1;
	   }
       },
       process => \&cmd_clean,
       usage => qq{Usage: tes3cmd clean OPTIONS plugin...

OPTIONS:
 --debug
	turn on debug messages

 --active
	only process specified plugins that are active. If none specified,
	process all active plugins. Plugins will be processed in the same
	order as your normal game load order.

 --backup-dir
	where backup files get stored. The default is:
	"morrowind/tes3cmd/backups"

 --cell-params
	clean cell subrecords AMBI,WHGT duped from masters

 --dups
	clean other complete records duped from masters

 --gmsts
	clean Evil GMSTs

 --hide-backups
	any created backup files will get stashed in the backup directory
	(--backup-dir)

 --ignore-plugin* <plugin-name>
        skips specified plugin if it appears on command line. plugin name is
        matched by exact, but caseless, string comparison.

 --instances
	clean object instances from cells when duped from masters

 --junk-cells
	clean junk cells (no new info from definition in masters)

 --no-cache
	do not create cache files (used for speedier cleaning)

 --output-dir <dir>
	set output directory to <dir> (default is where input plugin is)

 --overwrite
	overwrite original plugin with clean version (original is backed up)

DESCRIPTION:

Cleans plugins of various junk. If no cleaning options are selected, the
default is to assume the options:

  --instances --cell-params --dups --gmsts --junk-cells

The goal of the "clean" command is that it should always be safe to use it
with no options to get the default cleaning behavior. The different cleaning
operations are explained below:

Much of what is considered "dirt" is with respect to a plugin's masters.
Plugins that do not have masters cannot be checked for duplicate object
definitions and instances (references), cell parameters and junk-cells.

Object Instances (--instances)

  The clean command will clean objects in the plugin that match objects in any
  of its masters. Object instances in cells (sometimes called "references",
  but "object instance" is a more accurate descriptive term) are defined as
  byte sequences starting in the subrecord following a FRMR subrecord, and
  match only if this is the same byte sequence as in the master, along with
  the same Object-Index from the FRMR. NAM0 subrecords are not part of object
  instances, and if instances are deleted from a cell, the NAM0 subrecord for
  the cell is updated to reflect any changing instance count.

Cell Params (--cell-params)

  The subrecords for AMBI (ambient lighting) and WHGT (water height) for
  interior cells are often duplicated from the master of a plugin when the
  plugin is saved in the Construction Set.

Duplicate Records (--dups)

  Object definitions for various record types defined in a master are
  sometimes unnecessarily duplicated in dependent plugins, and this option
  will safely clean them. Only objects that have identical flags and byte
  sequences will be cleaned.

Evil GMSTs (--gmsts)

  An Evil GMST is defined as a GMST from the list of 11 Tribunal GMSTs or 61
  Bloodmoon GMSTs that are inadvertently introduced to a plugin by the
  Construction Set with specific values. Other GMSTs or GMSTs from those lists
  that do not have the specific Evil Values are NOT cleaned by this function.

  To clean GMSTs that are not Evil, you can use the command:
    "tes3cmd delete --type gmst"

Junk Cells (--junk-cells)

  Junk cells are bogus external CELL records that crop up in many plugins due
  to a Construction Set bug. They contain only NAME, DATA and sometimes RGNN
  subrecords with data identical to the master. (In addition, interior cells
  will also be removed if they do not introduce any new information).

Cache Files Feature

  tes3cmd will normally create cached data files for your masters in the
  subdirectory: "morrowind/tes3cmd/cache". If you do not wish tes3cmd to create
  cache files, you can use the --no-cache option. (But it is recommended you
  do use them for speedier cleaning).

EXAMPLES:

# clean my plugin of only Evil GMSTs:
tes3cmd clean --gmsts "my plugin.esp"

# clean 2 plugins and put the cleaned versions in a subdirectory "Clean":
tes3cmd clean --output-dir Clean "my plugin1.esp" "my plugin2.esp"

# clean all plugins in the current directory, replacing the originals with
# the cleaned versions and save the diagnostic output to a file (clean.txt):
tes3cmd clean --overwrite *.esm *.esp > clean.txt
},
     },

     common =>
     { description => qq{Find record IDs common between two plugins},
       options => [@STDOPT],
       preprocess => \&cmd_common,
       usage => qq{Usage: tes3cmd common OPTIONS plugin1 plugin2

OPTIONS:
 --debug
	turn on debug messages

DESCRIPTION:

Prints the IDs of records that the 2 given plugins have in common.

EXAMPLES:

# Show the records in common between my plugin and Morrowind.esm:
tes3cmd common "my plugin.esp" "Morrowind.esm"
},
     },

     delete =>
     { description => qq{Delete records/subrecords/object instances from plugin},
       options => [@STDOPT,
		   @MODOPT,
		   'active',
		   'ignore-plugin=s@',
		   'instance-match=s',
		   'instance-no-match=s',
		   'exact-id=s@',
		   'exterior',
		   'flag=s@',
		   'id=s@',
		   'interior',
		   'match=s@',
		   'no-match|M=s@',
		   'sub-match=s',
		   'sub-no-match=s',
		   'type=s@'],
       process => \&cmd_delete,
       usage => qq{Usage: tes3cmd delete OPTIONS plugin...

OPTIONS:
 --debug
	turn on debug messages

 --active
	only process specified plugins that are active. If none specified,
	process all active plugins. Plugins will be processed in the same
	order as your normal game load order.

 --backup-dir
	where backup files get stored. The default is:
	"morrowind/tes3cmd/backups"

 --exact-id* <id-string>
	only delete records whose ids exactly match given <id-string>

 --exterior
	only delete if record is an Exterior CELL

 --flag* <flag>
	only delete records with given flag. Flags may be given symbolically
	as: (deleted, persistent, ignored, blocked), or via their numeric
	values (i.e. persistent is 0x400).

 --hide-backups
	any created backup files will get stashed in the backup directory
	(--backup-dir)

 --id* <id-regex>
	only delete records whose ids match regular expression pattern
	<id-regex>

 --ignore-plugin* <plugin-name>
        skips specified plugin if it appears on command line. plugin name is
        matched by exact, but caseless, string comparison.

 --instance-match <regex>
	Only delete the object instances that match <regex> in the matching cell

 --instance-no-match <regex>
	Only delete object instances in the cell that do not match <regex>

 --interior
	only delete if record is an Interior CELL

 --match* <regex>
	only delete records that match given regular expression <regex>
	If more than one of these switches is supplied, ALL must match
	for a record to be processed.

 --no-match*|--M* <regex>
	only delete records that do not match given regular expression
	<regex>
	If more than one of these switches is supplied, if ANY match,
	that record will be skipped.

 --sub-match <regex>
	only delete the subrecords that match <regex>

 --sub-no-match <regex>
	only delete the subrecords that do not match <regex>

 --type* <record-type>
	only delete records with the given <record-type>

 Note: starred (*) options can be repeated, and matching of strings is not
 case-sensitive.

DESCRIPTION:

Deletes entire records, or subrecords from records, or object instances from
cell records. You can really damage things with this command, so be careful!

One thing you should be extra careful with is deleting objects from cells.
When objects from a master are "moved" by a plugin, a MVRF group appears
before the object instance that starts with a FRMR subrecord. If you really
want to delete that object, you probably want to delete both the FRMR object
instance and the preceeding MVRF group. A future version of tes3cmd may handle
this situation more elegantly.

Note: documentation for regular expressions:
  http://perldoc.perl.org/perlre.html

EXAMPLES:

# Delete all records with IDs matching the pattern: "foo":
# (Note that this doesn't also delete records that may depend on "foo").
tes3cmd delete --id foo "my plugin.esp"

# Delete all GMST records from a plugin:
tes3cmd delete --type gmst plugin.esp

# Delete all records flagged as "ignored":
tes3cmd delete --flag ignored plugin.esp

# Delete the poisonbloom spell subrecords from all current "_mca_" NPCs in quicksave.ess:
tes3cmd delete --type npc_ --match _mca_ --sub-match spell:poisonbloom quicksave.ess
},
     },

     diff =>
     { description => qq{Report differences between two plugins},
       options => [@STDOPT,
		   'ignore-type=s@'   => \@opt_diff_ignore_types,
		   '1-not-2|e1'       => \$opt_diff_1_not_2,
		   '2-not-1|e2'       => \$opt_diff_2_not_1,
		   'equal'            => \$opt_diff_equal,
		   'sortsubrecs'      => \$opt_diff_sortsubrecs,
		   'types'            => \$opt_diff_types,
		   'not-equal|ne'     => \$opt_diff_not_equal],

       preprocess => sub {
	   my(@plugins) = @_;
	   unless ($opt_diff_1_not_2 or $opt_diff_2_not_1 or $opt_diff_equal or $opt_diff_not_equal or $opt_diff_types) {
	       $opt_diff_1_not_2 = $opt_diff_2_not_1 = $opt_diff_equal = $opt_diff_not_equal = $opt_diff_types = 1;
	   }
	   cmd_diff(@plugins);
       },
       usage => qq{Usage: tes3cmd diff OPTIONS plugin1 plugin2

OPTIONS:
 --debug
	turn on debug messages

 --ignore-type* <record-type>
	ignore given type(s)

 --1-not-2|--e1
	report records in plugin1 that do not exist in plugin2

 --2-not-1|--e2
	report records in plugin2 that do not exist in plugin1

 --equal
	report records in plugin1 that are equal in plugin2

 --not-equal|--ne
	report records in plugin1 that are different in plugin2

 --sortsubrecs
	two records being compared may be functionally equivalent but
	differ because their subrecords are in different order. This
	switch will first sort subrecords before comparison so
	subrecord order will not matter for comparison.

 Note: starred (*) options can be repeated, and matching of strings is not
 case-sensitive.

DESCRIPTION:

Prints a report on the differences between the two TES3 files.
A summary report with up to four sections is printed to standard output
that gives an overview of differences, as lists of record IDs.
(Report sections that would have no items are not printed).

When records in plugin1 are different in plugin2, each of these records is
printed in detail to a file "plugin1-diff.txt" and "plugin2-diff.txt", which
can then be compared textually using a tool such as WinMerge or the ediff
function of Emacs. Note that the output records will be sorted alphabetically
by record type to make the comparison using these tools easier.

To reduce a great deal of "uninteresting" differences when diffing savegames,
the the ModIndex field of CELL.FRMR records are automatically ignored. (Note
that in this case, the ObjIndex appears to only be incremented by one).

EXAMPLES:

# Print report on differences between 2 savegames (output to diff.out):
tes3cmd diff "save1000.ess" "save2000.ess" > diff.out

# You can also use the --ignore-type switch to ignore further subfields in
# order to help reduce the amount of differences as in the following example.
# Report on differences, but ignore the subfields CREA.AIDT and CELL.ND3D:
tes3cmd diff --ignore-type crea.aidt --ignore-type cell.nd3d testa0000.ess testb0000.ess > diff.out

# Just print the records that differ
tes3cmd diff --not-equal "my plugin1.esp" plugin2.esp
},
     },

     dump =>
     { description => qq{Dump records as text for easy study},
       options => [@STDOPT,
		   'active',
		   'binary',
		   'exact-id=s@',
		   'exterior',
		   'flag=s@',
		   'format=s@'		  => \@opt_dump_format,
		   'no-quote'		  => \$opt_dump_no_quote,
		   'header',
		   'id=s@',
		   'ignore-plugin=s@',
		   'instance-match=s',
		   'instance-no-match=s',
		   'interior',
		   'list',
		   'match=s@',
		   'no-banner|B',
		   'no-match|M=s@',
		   'wrap',
		   'raw-with-header=s'   => \$opt_dump_raw_with_header,
		   'raw=s'               => \$opt_dump_raw,
		   'separator=s',
		   'type=s@'],
       preprocess =>  sub {

	   # translate the obsolete command switches
	   if ($opt_dump_raw_with_header) {
	       msg(qq{Note: --raw-with-header is obsolete, you can now use:\n\t--binary --header --output <filename>});
	       $opt_dump_raw = $opt_dump_raw_with_header;
	       $opt_dump_header = 1;
	       $opt_dump_binary = 1;
	       $opt_output = $opt_dump_raw_with_header;
	   } elsif ($opt_dump_raw) {
	       msg(qq{Note: --raw is obsolete, you can now use:\n\t--binary --output <filename>});
	       $opt_dump_binary = 1;
	       $opt_output = $opt_dump_raw;
	   }
	   abort("did you forget to give a filename for raw output?")
	       if (defined($opt_dump_raw) and $opt_dump_raw =~ /^-/);

	   # write out the header here as we would like to be able to append to it from multiple input plugins
	   if ($opt_dump_binary) {
	       if ($opt_dump_header) {
		   $DUMP_RAWOUT = open_for_output($opt_output);
		   print $DUMP_RAWOUT make_header();
	       } else {
		   if (-f $opt_output) {
		       msg(qq{Appending to: "$opt_output"});
		       $DUMP_RAWOUT = open_for_append($opt_output);
		   } else {
		       msg(qq{Creating: "$opt_output"});
		       $DUMP_RAWOUT = open_for_output($opt_output);
		   }
	       }
	   }
       },

       process => \&cmd_dump,
       postprocess => sub {
	   if ($opt_dump_binary) {
	       close($DUMP_RAWOUT);
	       if ($opt_dump_header) {
		   $opt_header_update_record_count = 1;
		   update_header($opt_output, [qw(QUIET NOBACKUP)]);
	       }
	       print "\nRaw records saved in $opt_output\n";
	   }
       },
       usage => qq{Usage: tes3cmd dump OPTIONS plugin...

OPTIONS:
 --debug
	 turn on debug messages

 --active
	only process specified plugins that are active. If none specified,
	process all active plugins. Plugins will be processed in the same
	order as your normal game load order.

 --binary
	output raw binary records. (Default is to output human readable text)

 --header
	output an initial TES3 header record.

 --ignore-plugin* <plugin-name>
        skips specified plugin if it appears on command line. plugin name is
        matched by exact, but caseless, string comparison.

 --instance-match <regex>
	when printing cells, only print the matching object instances in the
	cell

 --instance-no-match <regex>
	when printing cells, only print the non-matching object instances in
	the cell

 --exact-id* <id-string>
	only dump records whose ids exactly match given <id-string>

 --exterior
	only match if record is an Exterior CELL

 --flag* <flag>
	only dump records with given flag. Flags may be given symbolically
	as: (deleted, persistent, ignored, blocked), or via their numeric
	values (i.e. persistent is 0x400).

 --format* <formatstring>
	Only print out given fields, with fields specified by names enclosed
	with "%". For example, the NPC_ screen name field would be: \%name\%
	If multiple formats are given each defines a separate line of output.
	Output fields are automatically quoted if they contain whitespace.
	(see also --no-quote).

 --id* <id-regex>
	only process records whose ids match regular expression pattern
	<id-regex>

 --interior
	only match if record is an Interior CELL

 --list
	only list the ids of the records to be dumped, instead of the entire record

 --match* <regex>
	only process records that match given regular expression <regex>
	If more than one of these switches is supplied, ALL must match
	for a record to be dumped.

 --no-banner|--B
	do not print banner identifying the current plugin

 --no-match*|--M* <regex>
	only process records that do not match given regular expression
	<regex>
	If more than one of these switches is supplied, if ANY match,
	that record will be skipped.

 --no-quote
	Turn off automatic quoting of output fields in the --format switches.

 --output <filename>
	Specify the name of the output file where records are dumped.

 --wrap
	Wrap some long fields for more nicely formatted output.

 --raw <file>
	[Obsolete: use --binary --output <file>]
	dump raw records to <file>, instead of as text. If <file> exists, records
	are appended to the end.

 --raw-with-header <file>
	[Obsolete: use --binary --header --output <file>]
	dump raw records with an initial TES3 header record to <file>

 --separator <string>
	separate subrecords with given <string>. Normally subrecords are
	separated by line-breaks. You can use this option to change that so
	they are all printed on one line.

 --type* <record-type>
	only dump records with the given <record-type>

 Note: starred (*) options can be repeated, and matching of strings is not
 case-sensitive.

DESCRIPTION:

Dumps the plugin to stdout in text form for easy perusal or in raw form for
extracting a subset of records to create a new plugin. For large plugins, the
text output can be voluminous. In the text output, a starred subrecord
indicates it is related to following subrecords.

Note: documentation for regular expressions:
  http://perldoc.perl.org/perlre.html

EXAMPLES:

# Print out NPC's by Id and Name and Faction:
tes3cmd dump --type npc_ --format "\%id\% \%name\% \%faction\%" Morrowind.esm

# List all the records in the plugin, just one per line, by type and ID:
tes3cmd dump --list "Drug Realism.esp"

# Dump all records from a plugin. we redirect the output to a file as there
# can be a lot of output:
tes3cmd dump "DwemerClock.esp" > "DwemerClock-dump.txt"

# Dump all records with IDs exactly matching "2247227652827822061":
tes3cmd dump --exact-id 2247227652827822061 LGNPC_AldVelothi_v1_20.esp

# Dump all the DIAL and INFO records from a plugin:
tes3cmd dump --type dial --type info "abotWhereAreAllBirdsGoing.esp"

# Dump all records flagged as persistent (by name) OR blocked (by value)
tes3cmd dump --flag persistent --flag 0x2000 "Suran_Underworld_2.5.esp"

# Dump all object instances in cells that match "galbedir":
# (this will just show you the cell header, and subrecords just for Galbedir
# and her desk and chest in the cell: "Balmora, Guild of Mages"):
tes3cmd dump --instance-match "name:.*galbedir" Morrowind.esm
},
     },

     esm =>
     { description => qq{Convert plugin (esp) to master (esm)},
       options => [@STDOPT,
		   'ignore-plugin=s@',
		   'overwrite'],
       process => \&cmd_esm,
       usage => qq{Usage: tes3cmd esm OPTIONS plugin...

OPTIONS:
 --debug
	turn on debug messages

 --ignore-plugin* <plugin-name>
        skips specified plugin if it appears on command line. plugin name is
        matched by exact, but caseless, string comparison.

 --overwrite
	overwrite output if it exists

DESCRIPTION:

Copies input plugin (.esp) to a master (.esm). If the output file already
exists, you must add the --overwrite option to overwrite it.

EXAMPLES:

# output is: "my plugin.esm"
tes3cmd esm "my plugin.esp"
},
     },

     esp =>
     { description => qq{Convert master (esm) to plugin (esp)},
       options => [@STDOPT,
		   'ignore-plugin=s@',
		   'overwrite'],
       process => \&cmd_esp,
       usage => qq{Usage: tes3cmd esp OPTIONS master...

OPTIONS:
 --debug
	turn on debug messages

 --ignore-plugin* <plugin-name>
        skips specified plugin if it appears on command line. plugin name is
        matched by exact, but caseless, string comparison.

 --overwrite
	overwrite output if it exists

DESCRIPTION:

Copies input master (.esm) to a plugin (.esp). If the output file already
exists, you must add the --overwrite option to overwrite it.

EXAMPLES:

# output is: "my plugin.esp"
tes3cmd esp "my plugin.esm"
},
     },

     fixit =>
     { description => qq{tes3cmd fixes everything it knows how to fix},
       options => [@STDOPT,
		   @MODOPT,
		   'ignore-plugin=s@'],
       preprocess => \&cmd_fixit,
       usage => qq{Usage: tes3cmd fixit OPTIONS

OPTIONS:
 --debug
	turn on debug messages

 --backup-dir
	where backup files get stored. The default is:
	"morrowind/tes3cmd/backups"

 --hide-backups
	any created backup files will get stashed in the backup directory
	(--backup-dir)

 --ignore-plugin* <plugin-name>
        skips specified plugin if it appears on command line. plugin name is
        matched by exact, but caseless, string comparison.

DESCRIPTION:

The fixit command does the following operations:
- Cleans all your plugins ("tes3cmd clean")
- Synchronizes plugin headers to your masters ("tes3cmd header --synchronize")
- Generates a patch for merged leveled lists and more ("tes3cmd multipatch")
- Resets Dates on Bethesda data files ("tes3cmd resetdates")
},
     },

     header =>
     { description => qq{Read/Write plugin Author/Description, sync to masters...},
       options => [@STDOPT,
		   @MODOPT,
		   'active',
		   'author=s'              => \$opt_header_author,
		   'description=s'         => \$opt_header_description,
		   'ignore-plugin=s@',
		   'multiline'             => \$opt_header_multiline,
		   'synchronize'           => \$opt_header_synchronize,
		   'update-masters'        => \$opt_header_update_masters,
		   'update-record-count'   => \$opt_header_update_record_count],

       preprocess => sub {
	   $opt_header_update_masters = $opt_header_update_record_count = 1
	       if ($opt_header_synchronize);
       },
       process => \&cmd_header,
       usage => qq{Usage: tes3cmd header OPTIONS plugin...

OPTIONS:
 --debug
	turn on debug messages

 --active
	only process specified plugins that are active. If none specified,
	process all active plugins. Plugins will be processed in the same
	order as your normal game load order.

 --author <author>
	set the Author field to <author>

 --backup-dir
	where backup files get stored. The default is:
	"morrowind/tes3cmd/backups"

 --description <desc>
	set the Description field to <desc>

 --hide-backups
	any created backup files will get stashed in the backup directory
	(--backup-dir)

 --ignore-plugin* <plugin-name>
        skips specified plugin if it appears on command line. plugin name is
        matched by exact, but caseless, string comparison.

 --multiline
	multi-line output for listing field contents

 --synchronize
	same as: --update-masters --update-record-count

 --update-masters
	updates master list to reflect new versions

 --update-record-count
	update record count in header

DESCRIPTION:

When no options are given, the author and description are printed.

Author and Description field values are normally replaced by the given string.
But if the string begins with a "+", the existing value is appended with the
new given value.

If a given value contains the string "\\n", it will be replaced by a CRLF.

Note:
 - the Author value should fit in $TES3::HDR_AUTH_LENGTH bytes.
 - the Description value should fit in $TES3::HDR_DESC_LENGTH bytes.

If the value supplied will not fit into the plugin header field, you will be
warned.

The --update-masters (or --synchronize) option will clear any warnings
Morrowind gives when it starts up that say: "One or more plugins could not
find the correct versions of the master files they depend on..."

EXAMPLES:

# Show the Author/Description fields for a plugin:
tes3cmd header "my plugin.esp"

# Set the Author field to "john.moonsugar":
tes3cmd header --author john.moonsugar "plugin.esp"

# Append " and friends" to the Author field:
tes3cmd header --author "+ and friends" "plugin.esp"

# Append a Version number to a plugin Description field:
tes3cmd header --description "+\\nVersion: 1.0" "plugin.esp"

# update header field for the number of records in the plugin (if incorrect)
# and sync the list of masters to the masters installed in "Data Files"
tes3cmd header --synchronize "my plugin.esp"
},
     },

     help =>
     { preprocess => sub {
	   my $cmd_name = shift(@ARGV);
	   if (defined($cmd_name) and
	       defined(my $cmd_ref = $COMMAND{$cmd_name})) {
	       die($cmd_ref->{usage}."\n");
	   } else {
	       die(join("",
			$Usage1,
			(map { (/^(help|-)/ or (not defined $COMMAND{$_}->{description})) ? "" :
				  "  $_\n    $COMMAND{$_}->{description}.\n" } (sort keys %COMMAND)),
			$Usage2));
	   }
       },
     },

     -lint =>
     { description => qq{Scan plugins and report possible problems},
       options => [@STDOPT,
		   'active',
		   'all'		    => \$opt_lint_all,
		   'autocalc-spells'	    => \$opt_lint_autocalc_spells,
		   'bloodmoon-dependency'   => \$opt_lint_bloodmoon_dependency,
		   'cell-00'		    => \$opt_lint_cell_00,
		   'clean'		    => \$opt_lint_clean,
		   'deprecated-lists'	    => \$opt_lint_deprecated_lists,
		   'dialogue-teleports'     => \$opt_lint_dialogue_teleports,
		   'duplicate-info'	    => \$opt_lint_duplicate_info,
		   'duplicate-records'	    => \$opt_lint_duplicate_records,
		   'expansion-dependency'   => \$opt_lint_expansion_dependency,
		   'evil-gmsts'		    => \$opt_lint_evil_gmsts,
		   'fogbug'		    => \$opt_lint_fogbug,
		   'fogsync'		    => \$opt_lint_fogsync,
		   'getsoundplaying'	    => \$opt_lint_getsoundplaying,
		   'ignore-plugin=s@',
		   'junk-cells'		    => \$opt_lint_junk_cells,
		   'master-sync'	    => \$opt_lint_master_sync,
		   'menumode'		    => \$opt_lint_menumode,
		   'missing-author'	    => \$opt_lint_missing_author,
		   'missing-description'    => \$opt_lint_missing_description,
		   'missing-version'	    => \$opt_lint_missing_version,
		   'modified-info'	    => \$opt_lint_modified_info,
		   'modified-info_id'	    => \$opt_lint_modified_info_id,
		   'record-count'	    => \$opt_lint_record_count,
		   'overrides'		    => \$opt_lint_overrides,
		   'no-bloodmoon-functions' => \$opt_lint_no_bloodmoon_functions,
		   'no-tribunal-functions'  => \$opt_lint_no_tribunal_functions,
		   'scripted-doors'	    => \$opt_lint_scripted_doors,
		  ],
       preprocess => sub {
	   if ($opt_lint_recommended) {
	       $opt_lint_bloodmoon_dependency = 1;
	       $opt_lint_clean = 1;
	       $opt_lint_deprecated_lists = 1;
	       $opt_lint_dialogue_teleports = 1;
	       $opt_lint_duplicate_records = 1;
	       $opt_lint_evil_gmsts = 1;
	       $opt_lint_expansion_dependency = 1;
	       $opt_lint_fogbug = 1;
	       $opt_lint_fogsync = 1;
	       $opt_lint_junk_cells = 1;
	       $opt_lint_modified_info_id = 1;
	   } elsif ($opt_lint_all) {
	       $opt_lint_autocalc_spells = 1;
	       $opt_lint_bloodmoon_dependency = 1;
	       $opt_lint_cell_00 = 1;
	       $opt_lint_clean = 1;
	       $opt_lint_deprecated_lists = 1;
	       $opt_lint_dialogue_teleports = 1;
	       $opt_lint_duplicate_info = 1;
	       $opt_lint_duplicate_records = 1;
	       $opt_lint_expansion_dependency = 1;
	       $opt_lint_evil_gmsts = 1;
	       $opt_lint_fogbug = 1;
	       $opt_lint_fogsync = 1;
	       $opt_lint_getsoundplaying = 1;
	       $opt_lint_junk_cells = 1;
	       $opt_lint_master_sync = 1;
	       $opt_lint_menumode = 1;
	       $opt_lint_missing_author = 1;
	       $opt_lint_missing_description = 1;
	       $opt_lint_missing_version = 1;
	       $opt_lint_modified_info = 1;
	       $opt_lint_modified_info_id = 1;
	       $opt_lint_record_count = 1;
	       $opt_lint_overrides = 1;
	       $opt_lint_no_bloodmoon_functions = 1;
	       $opt_lint_no_tribunal_functions = 1;
	       $opt_lint_scripted_doors = 1;
	   }

	   $lint_no_expansion_funs = 1    if ($opt_lint_no_tribunal_functions or $opt_lint_no_bloodmoon_functions);
	   $lint_header_fields = 1	  if ($opt_lint_missing_author or $opt_lint_missing_description or
					      $opt_lint_missing_version or $opt_lint_record_count);
	   $lint_modified_info = 1	  if ($opt_lint_modified_info or $opt_lint_modified_info_id);
	   $lint_expansion_functions = 1  if ($opt_lint_bloodmoon_dependency or $opt_lint_expansion_dependency);
       },
       process => \&cmd_lint,
       usage => qq{Usage: tes3cmd lint OPTIONS plugin...

OPTIONS:
 --active
	only process specified plugins that are active. If none specified,
	process all active plugins. Plugins will be processed in the same
	order as your normal game load order.

 --all/recommended
	Enable all or recommended output options. When --recommended is
	selected only the following options are enabled:
	--bloodmoon-dependency, --clean, --deprecated-lists,
	--duplicate-records, --evil-gmsts, --fog-sync, --fogbug,
	--junk-cells, --modified-info-id, --expansion-dependency

 --autocalc-spells
	The plugin defines autocalc'ed spells.

 --bloodmoon-dependency
	The plugin uses Bloodmoon specific functions, so it needs version
	1.6.1820, but the plugin does not list Bloodmoon.esm in its list of
	Masters. This is similar to the --expansion-dependency option, but it
	is for Bloodmoon only.

 --cell-00
	This means that an apparently dirty copy of cell (0, 0) is included in
	the plugin. This cell is often accidentally modified since it is the
	default cell displayed in the cell view window.

 --clean
	If this option is used, then a plugin that is not flagged with any of
	the other options will be flagged "CLEAN". It really just means:
	"found nothing of interest".

 --deprecated-lists
	This flag indicates that the plugin makes deprecated use of scripting
	functions to modify standard Bethesda Leveled Lists. This is bad
	because these lists will then be stored in the user's savegame just
	like any other changed object. Since savegames load after all plugins
	(including "Mashed Lists.esp" or "multipatch.esp" which contains
	merged leveled lists), this means that merged leveled lists will be
	ignored. Note that this warning only applies to changes to Bethesda
	lists. Changes to leveled lists specific to the mod will not be
	flagged. For more about the problem of using scripting functions to
	modify Bethesda lists see:
	http://www.uesp.net/wiki/Tes3Mod:Leveled_Lists

 --dialogue-teleports
	Crashes can happen when the functions Position/PositionCell are called
	in dialogue results. It is recommended that you do these kinds of
	teleports via a script and start the script in the dialogue results
	instead.

 --duplicate-info
	indicates the exact INFO dialog with the same ID, text and filter
	exists in one of the masters of this plugin. This may be a problem, or
	maybe not. Sometimes duplicate dialog is intentional in order for
	dialog sorting to be correct. It's only a mistake if it really was
	unintentional.

 --duplicate-records
	These are records in the plugin that are exact duplicates of records
	that occur in one of the masters. These are sometimes referred to as
	"dirty" or "unclean" entries.

 --evil-gmsts
	You know this one! This means that some of the "72 Evil GMSTs" are
	present in this plugin and that they have the same exact value as the
	original GMST in the master .esm. Other GMSTs not in the list of known
	Evil GMSTs or GMSTs that have been modified from their original values
	are not flagged. Note that it is also possible to have other GMSTs
	show up in the DUP-REC list, but those are not from the list of 72
	GMSTs that would get introduced by the Construction Set.

 --expansion-dependency
	The plugin requires either Tribunal or Bloodmoon because it uses
	engine features not present in the original Morrowind such as startup
	scripts or Tribunal functions, but the plugin has not listed any
	expansions in its list of Masters. This is not necessarily a problem,
	but it may contradict the Readme for the           mod sometimes.

 --fog-sync
	This option indicates that for some reason that the fog density setting
	in the CELL.DATA subrecord is not equal to the fog density setting in
	the CELL.AMBI subrecord. This is unusual, it's probably caused by
	editing the plugin in Enchanted Editor, and it's probably harmless,
	but you can resync the values by editing that cell in the Construction
	Set.

 --fogbug
	The plugin has an interior CELL with a fog density of 0.0, and the
	cell is not marked to "behave as exterior". This circumstance can
	trigger the "fog bug" in some graphics cards, resulting in the cell
	being rendered as a black or featureless blank screen.

 --getsoundplaying
	The plugin appears to use the scripting function GetSoundPlaying to
	detect events (as opposed to managing the playing of sound files).
	GetSoundPlaying fails consistently on a small number of users'
	systems, so these users will encounter problems with these scripts.
	Note that tes3lint uses regular expressions to detect the purpose for
	using GetSoundPlaying, and it will sometimes get false positives. For
	more about the GetSoundPlaying problem see:
	http://sites.google.com/site/johnmoonsugar/Home/morrowind-scripting-tips

 --ignore-plugin* <plugin-name>
        skips specified plugin if it appears on command line. plugin name is
        matched by exact, but caseless, string comparison.

 --junk-cells
	These are bogus external CELL records that crop up in many plugins,
	due to a Construction Set bug. They contain only NAME, DATA and
	sometimes RGNN subrecords, and the flags in the DATA subrecord are
	unchanged from the flags in the Master.

 --master_sync
	Checks the plugin is in sync with its masters by checking their size
	against the size recorded in the plugin header. This is usually never
	a problem, but it means that Morrowind will give the warning: "One of
	the files that "(plugin)" is dependent on has changed since the last
	save..."

 --menumode
	The plugin contains scripts that do not check menumode. Each script
	will be printed in the details section. This may or may not be
	intentional.

 --missing-author
	The plugin header is missing the Author field. It is strongly
	recommended that authors put their name or handle in the Author field.

 --missing-description
	The plugin header is missing a description field. It is strongly
	recommended that a short description of the plugin is entered in this
	field.

 --missing-version
	The plugin header description field is missing a "Version: X.Y"
	string. It is strongly recommended that the version number be added to
	the description. This version number is very helpful in documenting
	which version of the plugin a user is using. This information is used
	by tools such as Wrye Mash and mlox. The regular expression pattern
	used by Wrye Mash to match the version is: "^(Version:?)
	*([-0-9\\.]*\\+?) *\\r?\$". (mlox will match a much wider variety of
	version number formats). It is safest to use a string of the format:
	"Version: X.Y", on a line by itself.

 --modified-info
	indicates that an INFO dialog with the same ID exists in the master,
	but this plugin has modified the text or the filter. This is quite
	common when a plugin intentionally modifies a master's dialog, but it
	often a problem when due to unintentional changes. There may be an
	associated "modified-info-id".

 --modified-info-id
	indicates that the exact same INFO dialog text exists in this plugin
	as in a master, but under a different ID. When associated with a
	"modified-info", this situation may be due to creating new dialog by
	copying the original, and then accidentally editing the original
	instead of the copy which may cause bad dialog problems and should
	probably be investigated further.

 --no-bloodmoon-functions
	Bloodmoon.esm is listed as a master, but lint did not detect any usage
	of Bloodmoon functions. (Note that there may be other reasons for
	listing Bloodmoon as a master).

 --no-tribunal-functions
	Tribunal.esm is listed as a master, but lint did not detect any usage
	of Tribunal functions. (Note that there may be other reasons for
	listing Tribunal as a master).

 --overrides
	The plugin contains record(s) that override the record with the same
	ID in one of its masters.

 --record-count
	This means that the number of records recorded in the TES3 plugin
	header field does not match the actual number of records in the
	plugin. This situation is not known to cause any errors or warnings in
	the CS or in the Morrowind game itself, so it's just presented as a
	matter of interest.

 --scripted-doors
	The plugin adds scripts to Bethesda doors, which has the potential
	to break any script in the same cell that uses the CellChanged
	function. CellChanged in that cell will always return 0 from now on.
	See: http://sites.google.com/site/johnmoonsugar/Home/morrowind-scripting-tips

DESCRIPTION

The lint command normally only prints output for interesting things it finds.
If it finds nothing for a plugin, no output is generated unless the --clean
option is given. When something interesting is found, a flag is printed after
the plugin name. On following lines, an indented report is printed that gives
more detail about the flagged items.

},
     },

     modify =>
     {
      description => qq{Powerful batch record modification via user code extensions},
      options => [@STDOPT,
		  @MODOPT,
		  'active',
		  'exact-id=s@',
		  'exterior',
		  'flag=s@',
		  'id=s@',
		  'ignore-plugin=s@',
		  'interior',
		  'match=s@',
		  'no-match|M=s@',
		  'program-file=s'     => \$opt_modify_program_file,
		  'replace=s'          => \$opt_modify_replace,
		  'replacefirst=s'     => \$opt_modify_replacefirst,
		  'run=s'              => \$opt_modify_run,
		  'sub-match=s',
		  'sub-no-match=s',
		  'type=s@'],

      preprocess => sub {
	  # load Perl program if specified with --program-file
	  load_perl($opt_modify_program_file);
	  $opt_modify_run = 'main($R);' unless ($opt_modify_run);
      },

      process => \&cmd_modify,

      usage => qq{Usage: tes3cmd modify OPTIONS plugin...

OPTIONS:
 --debug
	turn on debug messages

 --active
	only process specified plugins that are active. If none specified,
	process all active plugins. Plugins will be processed in the same
	order as your normal game load order.

 --backup-dir
	where backup files get stored. The default is:
	"morrowind/tes3cmd/backups"

 --exact-id* <id-string>
	only modify records whose ids exactly match given <id-string>

 --exterior
	only match if record is an Exterior CELL

 --flag* <flag>
	only modify records with given flag. Flags may be given symbolically
	as: (deleted, persistent, ignored, blocked), or via their numeric
	values (i.e. persistent is 0x400).

 --hide-backups
	any created backup files will get stashed in the backup directory
	(--backup-dir)

 --id* <id-regex>
	only modify records whose ids match regular expression pattern
	<id-regex>

 --ignore-plugin* <plugin-name>
        skips specified plugin if it appears on command line. plugin name is
        matched by exact, but caseless, string comparison.

 --interior
	only match if record is an Interior CELL

 --match* <regex>
	only modify records that match given regular expression <regex>
	If more than one of these switches is supplied, ALL must match
	for a record to be processed.

 --no-match*|--M* <regex>
	only modify records that do not match given regular expression
	<regex>
	If more than one of these switches is supplied, if ANY match,
	that record will be skipped.

 --program-file <file>
	load Perl code to run on each matched record from file named: <file>

 --replace "/a/b/"
	replace regular expression pattern "a" with value "b" for every field
	value in every matching record. you can use any character instead of
	the slash as long as it does not occur in "a" or "b". This is a very
	powerful alternative to the --run option, as it only requires
	understanding of regular expressions, no perl coding is necessary.

 --replacefirst "/a/b/"
	just like --replace, but only replaces the first match.

 --run "<code>"
	specify a string of Perl <code> to run on each matched record

 --sub-match <regex>
	only modify the subrecords that match <regex>. When this option (or
	--sub-no-match) are used, modification only applies to matching
	subrecords. Without either of these options modifications are
	performed on whole records.

 --sub-no-match <regex> only modify the subrecords that do not match <regex>.
	(see also --sub-match above).

 --type* <record-type>
	only modify records with the given <record-type>

 Note: starred (*) options can be repeated, and matching of strings is not
 case-sensitive.

This command allows you to do complex batch modifications of plugin records.
You can really damage things with this command, so be careful!

Note: documentation for regular expressions:
  http://perldoc.perl.org/perlre.html

Example(s):

# Just print the the cell "Ashmelech" from Morrowind.esm. (no modification).
tes3cmd modify --type cell --id ashmelech --run "\$R->dump" Morrowind.esm

# Add the prefix "PC_" to the ID of all the statics in a plugin:
tes3cmd modify --type stat --sub-match "id:" --replace "/^/PC_/" pc_data.esp

# Problem: Aleanne's clothing mods do not have restocking inventory
# Solution: create a small patch to change the counts for inventory containers
#   to negative numbers so they will be restocking.
# Step 0: confirm the problem, showing the non-negative counts:
tes3cmd dump --type cont ale_clothing_v?.esp
# Step 1: Create the patch file ale_patch.esp containing just the container records:
tes3cmd dump --type cont --raw-with-header ale_patch.esp ale_clothing_v?.esp
# Step 2: Change all the count fields for the containers in Aleanne's Clothing to -3 (for restocking wares)
tes3cmd modify --type cont --run "\$R->set({f=>'count'}, -3)" ale_patch.esp
# Note: on Linux, the quoting would be a little different:
tes3cmd modify --type cont --run '\$R->set({f=>"count"}, -3)' ale_patch.esp

# You can also specify a list of indices to restrict which subrecords are modified.
# First, show the subrecord indices for container "_aleanne_chest" from: ale_clothing_v0.esp:
tes3cmd modify --type cont --run "\$R->dump" ale_clothing_v0.esp
# Then only modify the last 3 items:
tes3cmd modify --type cont --run "\$R->set({i=>[-3..-1],f=>'count'}, 4)" ale_clothing_v0.esp
},
     },

     "-run" =>
     {
      description => qq{Run user code extensions},
      options => [@STDOPT,
		  @MODOPT,
		  'active',
		  'exact-id=s@',
		  'exterior',
		  'flag=s@',
		  'id=s@',
		  'ignore-plugin=s@',
		  'interior',
		  'match=s@',
		  'no-match|M=s@',
		  'program-file=s'     => \$opt_modify_program_file,
		  'sub-match=s',
		  'sub-no-match=s',
		  'type=s@'],

      preprocess => sub {
	  # load Perl program if specified with --program-file
	  load_perl($opt_run_program_file);
      },

      process => \&cmd_run,

      usage => qq{Usage: tes3cmd run programfile OPTIONS plugin...

Loads a tes3cmd extension "programfile" to perform custome processing of plugins.

OPTIONS:
 --debug
	turn on debug messages

 --active
	only process specified plugins that are active. If none specified,
	process all active plugins. Plugins will be processed in the same
	order as your normal game load order.

 --backup-dir
	where backup files get stored. The default is:
	"morrowind/tes3cmd/backups"

 --exact-id* <id-string>
	only modify records whose ids exactly match given <id-string>

 --exterior
	only match if record is an Exterior CELL

 --flag* <flag>
	only modify records with given flag. Flags may be given symbolically
	as: (deleted, persistent, ignored, blocked), or via their numeric
	values (i.e. persistent is 0x400).

 --hide-backups
	any created backup files will get stashed in the backup directory
	(--backup-dir)

 --id* <id-regex>
	only modify records whose ids match regular expression pattern
	<id-regex>

 --ignore-plugin* <plugin-name>
        skips specified plugin if it appears on command line. plugin name is
        matched by exact, but caseless, string comparison.

 --interior
	only match if record is an Interior CELL

 --match* <regex>
	only modify records that match given regular expression <regex>
	If more than one of these switches is supplied, ALL must match
	for a record to be processed.

 --no-match*|--M* <regex>
	only modify records that do not match given regular expression
	<regex>
	If more than one of these switches is supplied, if ANY match,
	that record will be skipped.

 --sub-match <regex>
	only modify the subrecords that match <regex>. When this option (or
	--sub-no-match) are used, modification only applies to matching
	subrecords. Without either of these options modifications are
	performed on whole records.

 --sub-no-match <regex> only modify the subrecords that do not match <regex>.
	(see also --sub-match above).

 --type* <record-type>
	only modify records with the given <record-type>

 Note: starred (*) options can be repeated, and matching of strings is not
 case-sensitive.

This command allows you to do complex batch modifications of plugin records.
You can really damage things with this command, so be careful!

Note: documentation for regular expressions:
  http://perldoc.perl.org/perlre.html

Example(s):

# Run your homegrown extension
tes3cmd run myprog.pl ...

},
     },

     multipatch =>
     { description => qq{Patches problems, merges leveled lists, etc.},
       options => [@STDOPT,
		   'cellnames'       => \$opt_multipatch_cellnames,
		   'delete-creature|dc=s@' => \@opt_multipatch_delete_creature,
		   'delete-item|di=s@'     => \@opt_multipatch_delete_item,
		   'fogbug'          => \$opt_multipatch_fogbug,
		   'merge-lists'     => \$opt_multipatch_merge_lists,
		   'merge-objects'   => \$opt_multipatch_merge_objects,
		   'no-activate'     => \$opt_multipatch_no_activate,
		   'no-cache',
		   'summons-persist' => \$opt_multipatch_summons_persist],

       preprocess => sub {
	   unless ($opt_multipatch_cellnames or $opt_multipatch_fogbug or
		   $opt_multipatch_merge_lists or $opt_multipatch_summons_persist or
		   $opt_multipatch_merge_objects) {
	       # by default turn on all options if none are selected
	       $opt_multipatch_cellnames = $opt_multipatch_fogbug =
		   $opt_multipatch_merge_lists = $opt_multipatch_merge_objects =
		   $opt_multipatch_summons_persist = 1;
	   }
	   %LEVC::user_delete_creature = map { lc, 1 } @opt_multipatch_delete_creature;
	   %LEVI::user_delete_item = map { lc, 1 } @opt_multipatch_delete_item;
	   cmd_multipatch();
       },
       usage => qq{Usage: tes3cmd multipatch

OPTIONS:
 --debug
	turn on debug messages

 --cellnames
	resolve conflicts with renamed external cells

 --fogbug
	fix interior cells with the fog bug

 --merge-lists
	merges leveled lists used in your active plugins. Note that when you
	use this feature, you do NOT also need other merged lists plugins like
	"Mashed Lists.esp" from Wrye Mash.

	This option has the following sub-options which can be used to remove
	creatures and items (by exact id match) from all leveled lists in
	which they occur:

	--delete-creature*|--dc* <creature-id>
	--delete-item*|--di* <item-id>

 --merge-objects
	merges leveled lists used in your active plugins. Note that when you
	use this feature, you do NOT also need other merged object plugins like
	"Merged_Objects.esp" from TesTool. (NOT IMPLEMENTED YET).

 --no-activate
	do not automatically activate multipatch.esp

 --no-cache
	do not create cache files (used for speedier operation)

 --summons-persist
	fixes summoned creatures crash by making them persistent

DESCRIPTION:

The multipatch produces a patch file based on your current load order to solve
various problems. You should regenerate your multipatch whenever you change
your load order. The goal of the "multipatch" command is that it should always
be safe to use it with no options to get the default patching behavior (if you
do find any problems, please report them and they will be fixed ASAP). When no
options are specified, the following default options are assumed:

  --cellnames --fogbug --merge-lists --merge-objects --summons-persist

The different patching operations are explained below:

Cell Name Patch (--cellnames)

  Creates a patch to ensure renamed cells are not accidentally reverted to
  their original name.

  This solves the following plugin conflict that causes bugs:
  * Master A names external CELL (1, 1) as: "".
  * Plugin B renames CELL (1, 1) to: "My City".
  * Plugin C modifies CELL (1, 1), using the original name "", reverting
    renaming done by plugin B.
  * References in plugin B (such as in scripts) that refer to "My City" break.

  This option works by scanning your currently active plugin load order for
  cell name reversions like those in the above example, and ensures whenever
  possible that cell renaming is properly maintained.

Fog Bug Patch (--fogbug)

  Some video cards are affected by how Morrowind handles a fog density setting
  of zero in interior cells with the result that the interior is pitch black,
  except for some light sources, and no amount of light, night-eye, or gamma
  setting will make the interior visible. This is known as the "fog bug".

  This option creates a patch that fixes all fogbugged cells in your active
  plugins by setting the fog density of those cells to a non-zero value.

Merge Leveled Lists (--merge-lists)

  This feature is similar to what you get with Wrye Mash's "Mashed Lists.esp".
  However, you should not use more than one plugin to merge leveled lists.

Merge Objects (--merge-objects)

  This feature is similar to what you get with TesTools's "Merged_Objects.esp".
  However, you should not use more than one plugin to merge objects.
  (NOT IMPLEMENTED YET)

Summoned creatures persists (--summons-persist)

  There is a bug in Morrowind that can cause the game to crash if you leave a
  cell where an NPC has summoned a creature. The simple workaround is to flag
  summoned creatures as persistent. The Morrowind Patch Project implements
  this fix, however other mods coming later in the load order often revert it.
  This option to the multipatch ensures that known summoned creatures are
  flagged as persistent. The Morrowind Code Patch also fixes this bug, making
  this feature redundant.

EXAMPLES:

# Create the patch plugin "multipatch.esp" with all default patch options on:
tes3cmd multipatch
},
     },

     overdial =>
     { description => qq{Identify overlapping dialog (a source of missing topic bugs)},
       options => [@STDOPT,
		   'active',
		   'ignore-plugin=s@',
		   'single' => \$opt_overdial_single],
       preprocess => \&cmd_overdial,
       usage => qq{Usage: tes3cmd overdial OPTIONS plugin...

OPTIONS:
 --debug
	turn on debug messages

 --active
	only process specified plugins that are active. If none specified,
	process all active plugins. Plugins will be processed in the same
	order as your normal game load order.

 --ignore-plugin* <plugin-name>
        skips specified plugin if it appears on command line. plugin name is
        matched by exact, but caseless, string comparison.

 --single
	only test to see if dialog in the first plugin is overlapped. (by
	default all plugins are checked against all other plugins, which is an
	n-squared operation, meaning "possibly very slow").

DESCRIPTION:

Prints the IDs of dialog records that overlap from the set of given plugins.

An overlap is defined as a dialog (DIAL) Topic from one plugin that entirely
contains a dialog Topic from another plugin as a substring. For example, the
mod "White Wolf of Lokken" has a dialog topic "to rescue me" which overlaps
with the dialog topic "rescue me" from "Suran Underworld", which causes the
"Special Guest" quest from SU to get stuck because Ylarra will not offer the
topic "rescue me" when you find her in her cell.

Note that overlap is only a potential problem if the plugins are loaded in the
order they are listed in the output.

Example(s):

# Show dialog overlaps between Lokken and SU:
tes3cmd overdial "BT_Whitewolf_2_0.esm" "Suran_Underworld_2.5.esp"
},
     },

     recover =>
     { description => qq{Recover usable records from plugin with 'bad form' errors},
       options => [@STDOPT,
		   'ignore-plugin=s@',
		   @MODOPT],
       process => \&cmd_recover,
       usage => qq{Usage: tes3cmd recover OPTIONS plugin...

OPTIONS:
 --debug
	turn on debug messages

 --backup-dir
	where backup files get stored. The default is:
	"morrowind/tes3cmd/backups"

 --hide-backups
	any created backup files will get stashed in the backup directory
	(--backup-dir)

 --ignore-plugin* <plugin-name>
        skips specified plugin if it appears on command line. plugin name is
        matched by exact, but caseless, string comparison.

DESCRIPTION:

Attempts to recover readable records from a damaged plugin. You should only
use this when Morrowind gives the following type of error on your plugin:

  "Trying to load a bad form in TES3File::NextForm"

The main reason you would get this error is if the file has been physically
corrupted, where records have been overwritten with random binary junk, or
if the file has been truncated, or otherwise damaged.

This is not for fixing what is commonly referred to as "savegame corruption",
which is almost always not actual corruption but bad data.

In any case, you will get detailed output on what tes3cmd finds damaged.

EXAMPLE(S):

# fix my damaged plugin:
tes3cmd recover "my plugin.esp"
},
     },

     resetdates =>
     { description => qq{Reset dates of Bethesda Data Files to original settings},
       options => [@STDOPT],
       preprocess => \&cmd_resetdates,
       usage => qq{Usage: tes3cmd resetdates

OPTIONS:
 --debug
	turn on debug messages

DESCRIPTION:

Resets the dates of the Bethesda masters (.esm) and archives (.bsa) to their
original settings. This may help those people who have problems with textures
and meshes being overridden by the vanilla resources (e.g. as can happen with
the Steam version of Morrowind).

Example(s):

# fix the date settings of Bethesda data files:
tes3cmd resetdates
},
     },

     -stats =>
     { description => qq{Print out statistics on specified plugin(s)},
       options => [@STDOPT,
		   'active',
		  ],
       process => sub {
	   my($plugin) = @_;
	   dbg("cmd_stats($plugin)") if (DBG);
	   my $fun = sub {
	       my($rec_match, $rectype, $tr, $print_rec) = rec_match($plugin, @_); # calls tr->decode
	       return unless ($rec_match);
	       $STATS{$plugin}->{nrecords}++;
	       $STATS{$plugin}->{nrectype}->{$rectype}++;
	       foreach my $subtype (keys %{$tr->{SH}}) {
		   $STATS{$plugin}->{listtype}->{qq{${rectype}.${subtype}}}++
		       if (scalar(@{$tr->{SH}->{$subtype}} > 1));
	       }
	   };
	   process_plugin_for_input($plugin, $fun) or return(0);
       },
       postprocess => sub {
	   my $nplugins = scalar(keys %STATS);
	   print qq{Number of plugins: $nplugins\n};
	   my %listtype;
	   foreach my $plugin (keys %STATS) {
	       foreach my $type (sort keys %{$STATS{$plugin}->{listtype}}) {
		   $listtype{$type} += $STATS{$plugin}->{listtype}->{$type};
	       }
	   }
	   print qq{List-type Subrecords:\n};
	   foreach my $type (sort keys %listtype) {
	       print qq{$type\t$listtype{$type}\n};
	   }
       },
       usage => qq{Usage: tes3cmd stats OPTIONS plugin...\n},
     },

     '-undelete' =>
     { description => qq{Modifies plugins to undelete object instances (references)},
       options => [@STDOPT],
       process => \&cmd_undelete,
       usage => qq{Usage: tes3cmd undelete OPTIONS plugin...

OPTIONS:
 --debug
	turn on debug messages

 --active
	only process specified plugins that are active. If none specified,
	process all active plugins. Plugins will be processed in the same
	order as your normal game load order.

 --verbose
	print items that are undeleted from each cell.

DESCRIPTION:

Sometimes when a plugin deletes an object from a cell, and another plugin in
your load order comes along and tries to modify that object (perhaps by moving
it), then you get a message about the object "is missing in Master file". This
function allows you to safely undelete those objects so that you do not get
those annoying messages.

When this function undeletes an object instance, it removes the DELE
subrecord and adds ZNAM subrecord to mark the object as disabled. It also
adds a DATA subrecord that positions the disabled instance at the origin (since
object instances that have been deleted do not have a DATA subrecord, and
Morrowind expects all object instances to have a position).
},
     },

     '-codec' =>
     { description => qq{Describe TES3 record codec (not implemented)},
       options => [@STDOPT],
       preprocess => \&cmd_codec,
       usage => qq{Usage: tes3cmd -codec\n},
     },

     '-shell' =>
     { description => qq{run a TES3 REPL},
       options => [@STDOPT],
       preprocess => \&cmd_shell,
       usage => qq{Usage: tes3cmd -shell

Example:

# Run a shell, and create a new blank ESP file:
% tes3cmd -shell
> open(\$F,">blank.esp") && print \$F make_header({ author => 'me', description => '' });

==> 1
[type Ctrl-D to quit shell]\n},
     },

     '-testcodec' =>
     { description => qq{Test TES3 codec orthogonality},
       options => [@STDOPT,
		   'continue'             => \$opt_testcodec_continue,
		   'exclude-type|x=s@'    => \@opt_testcodec_exclude_type,
		   'ignore-cruft'         => \$opt_testcodec_ignore_cruft],
       process => \&cmd_testcodec,
       usage => qq{Usage: tes3cmd -testcodec [--exclude-type|-x exclude_type]\n},
     },

     '-wikiout' =>
     { description => qq{Output wiki formatted help},
       options => [@STDOPT],
       preprocess => sub {
	   dbg("cmd_wikiout") if (DBG);
	   my $usage = 
	       join("",
		    $Usage1,
		    (map { (/^(help|-)/ or (not defined $COMMAND{$_}->{description})) ? "" :
			       "  $_\n    $COMMAND{$_}->{description}.\n" } (sort keys %COMMAND)),
		    $Usage2);
	   $usage =~ s/^/    /gm;	# blockquote the body of help
	   print "# $usage\n";
	   foreach my $cmd (sort keys %COMMAND) {
	       next if (($cmd eq 'help') or ($cmd =~ /^-/));
	       my $cmdusage = $COMMAND{$cmd}->{usage};
	       my $desc = $COMMAND{$cmd}->{description};
	       $cmdusage =~ s/^/    /gm;	# blockquote the body of help
	       print "## $cmd - _${desc}\n\n$cmdusage\n";
	   }
	   print "(this page was automatically generated by: tes3cmd -wikiout)\n"
       },
       usage => qq{Usage: tes3cmd -wikiout\n},
     },
    );				# end of COMMAND DISPATCH TABLE

# command aliases
#$COMMAND{'-help'}  = $COMMAND{help};
#$COMMAND{'--help'} = $COMMAND{help};

### DATA DEFINITIONS

# these rectypes are for records to be cleaned from plugins when duped from a master:
my @CLEAN_DUP_TYPES =
    qw(ACTI ALCH APPA ARMO BODY BOOK BSGN CELL CLAS CLOT CONT CREA DOOR ENCH
       FACT GLOB GMST INFO INGR LAND LEVC LEVI LIGH LOCK MGEF MISC NPC_
       PGRD PROB RACE REGN REPA SCPT SKIL SNDG SOUN SPEL SSCR STAT WEAP);

# list of summoned creatures for multipatch
my %SUMMONED_CREATURES = map {$_,1}
    ('centurion_fire_dead',
     'wraith_sul_senipul',
     'ancestor_ghost_summon',
     'atronach_flame_summon',
     'atronach_frost_summon',
     'atronach_storm_summon',
     'bonelord_summon',
     'bonewalker_summon',
     'bonewalker_greater_summ',
     'centurion_sphere_summon',
     'clannfear_summon',
     'daedroth_summon',
     'dremora_summon',
     'golden saint_summon',
     'hunger_summon',
     'scamp_summon',
     'skeleton_summon',
     'ancestor_ghost_variner',
     'fabricant_summon',
     'bm_bear_black_summon',
     'bm_wolf_grey_summon',
     'bm_wolf_bone_summon');

# Evil GMSTs from Tribunal (values are hexencoded) for cleaning
my %EVIL_TB =
    (scompanionshare => '5354525620436f6d70616e696f6e205368617265',
     scompanionwarningbuttonone => '53545256204c657420746865206d657263656e61727920717569742e',
     scompanionwarningbuttontwo => '535452562052657475726e20746f20436f6d70616e696f6e20536861726520646973706c61792e',
     scompanionwarningmessage => '5354525620596f7572206d657263656e61727920697320706f6f726572206e6f77207468616e207768656e20686520636f6e74726163746564207769746820796f752e2020596f7572206d657263656e6172792077696c6c207175697420696620796f7520646f206e6f7420676976652068696d20676f6c64206f7220676f6f647320746f206272696e67206869732050726f6669742056616c756520746f206120706f7369746976652076616c75652e',
     sdeletenote => '535452562044656c657465204e6f74653f',
     seffectsummonfabricant => '53545256207345666665637453756d6d6f6e466162726963616e74',
     slevitatedisabled => '53545256204c657669746174696f6e206d6167696320646f6573206e6f7420776f726b20686572652e',
     smagicfabricantid => '5354525620466162726963616e74',
     smaxsale => '53545256204d61782053616c65',
     sprofitvalue => '535452562050726f6669742056616c7565',
     steleportdisabled => '535452562054656c65706f72746174696f6e206d6167696320646f6573206e6f7420776f726b20686572652e',
     );

# Evil GMSTs from Bloodmoon (values are hexencoded) for cleaning
my %EVIL_BM =
    (fcombatdistancewerewolfmod => '464c5456209a99993e',
     ffleedistance => '464c54562000803b45',
     fwerewolfacrobatics => '464c54562000001643',
     fwerewolfagility => '464c54562000001643',
     fwerewolfalchemy => '464c5456200000803f',
     fwerewolfalteration => '464c5456200000803f',
     fwerewolfarmorer => '464c5456200000803f',
     fwerewolfathletics => '464c54562000001643',
     fwerewolfaxe => '464c5456200000803f',
     fwerewolfblock => '464c5456200000803f',
     fwerewolfbluntweapon => '464c5456200000803f',
     fwerewolfconjuration => '464c5456200000803f',
     fwerewolfdestruction => '464c5456200000803f',
     fwerewolfenchant => '464c5456200000803f',
     fwerewolfendurance => '464c54562000001643',
     fwerewolffatigue => '464c5456200000c843',
     fwerewolfhandtohand => '464c5456200000c842',
     fwerewolfhealth => '464c54562000000040',
     fwerewolfheavyarmor => '464c5456200000803f',
     fwerewolfillusion => '464c5456200000803f',
     fwerewolfintellegence => '464c5456200000803f',
     fwerewolflightarmor => '464c5456200000803f',
     fwerewolflongblade => '464c5456200000803f',
     fwerewolfluck => '464c5456200000803f',
     fwerewolfmagicka => '464c5456200000c842',
     fwerewolfmarksman => '464c5456200000803f',
     fwerewolfmediumarmor => '464c5456200000803f',
     fwerewolfmerchantile => '464c5456200000803f',
     fwerewolfmysticism => '464c5456200000803f',
     fwerewolfpersonality => '464c5456200000803f',
     fwerewolfrestoration => '464c5456200000803f',
     fwerewolfrunmult => '464c5456200000c03f',
     fwerewolfsecurity => '464c5456200000803f',
     fwerewolfshortblade => '464c5456200000803f',
     fwerewolfsilverweapondamagemult => '464c5456200000c03f',
     fwerewolfsneak => '464c5456200000803f',
     fwerewolfspear => '464c5456200000803f',
     fwerewolfspeechcraft => '464c5456200000803f',
     fwerewolfspeed => '464c54562000001643',
     fwerewolfstrength => '464c54562000001643',
     fwerewolfunarmored => '464c5456200000c842',
     fwerewolfwillpower => '464c5456200000803f',
     iwerewolfbounty => '494e54562010270000',
     iwerewolffightmod => '494e54562064000000',
     iwerewolffleemod => '494e54562064000000',
     iwerewolfleveltoattack => '494e54562014000000',
     seditnote => '535452562045646974204e6f7465',
     seffectsummoncreature01 => '53545256207345666665637453756d6d6f6e43726561747572653031',
     seffectsummoncreature02 => '53545256207345666665637453756d6d6f6e43726561747572653032',
     seffectsummoncreature03 => '53545256207345666665637453756d6d6f6e43726561747572653033',
     seffectsummoncreature04 => '53545256207345666665637453756d6d6f6e43726561747572653034',
     seffectsummoncreature05 => '53545256207345666665637453756d6d6f6e43726561747572653035',
     smagiccreature01id => '5354525620734d61676963437265617475726530314944',
     smagiccreature02id => '5354525620734d61676963437265617475726530324944',
     smagiccreature03id => '5354525620734d61676963437265617475726530334944',
     smagiccreature04id => '5354525620734d61676963437265617475726530344944',
     smagiccreature05id => '5354525620734d61676963437265617475726530354944',
     swerewolfalarmmessage => '5354525620596f752068617665206265656e206465746563746564206368616e67696e672066726f6d20612077657265776f6c662073746174652e',
     swerewolfpopup => '535452562057657265776f6c66',
     swerewolfrefusal => '5354525620596f752063616e6e6f7420646f207468697320617320612077657265776f6c662e',
     swerewolfrestmessage => '5354525620596f752063616e6e6f74207265737420696e2077657265776f6c6620666f726d2e',
    );

# cells with only these subtypes are candidates for "junk" cell cleaning.
my %JUNKCELL_SUBTYPE = (NAME => 1, DATA => 1, RGNN => 1);

### MAIN IO AND CACHING

sub read_rec {
    my($fh, $expected_type, $plugin) = @_;
    my $rec_hdr = "";
    my $n_read = read($fh, $rec_hdr, $hdr_size);
    if (not $n_read) {
	if (defined $n_read) {
	    return(undef);	# EOF
	} else {
	    abort(qq{Error on read() ($!)});
	}
    }
    if ($n_read != $hdr_size) {
	my $inp_offset = tell($fh) - $n_read;
	abort(qq{read_rec(): Read Error ($plugin header at byte: $inp_offset): asked for $hdr_size bytes, got $n_read});
    }
    # I suspect $reclen2 is the high word of a 64-bit double long, it is effectively unused.
    my($rectype, $reclen, $reclen2, $hdrflags) = unpack("a4LLL", $rec_hdr);
    if (not $TES3::Record::RECTYPES{$rectype}) {
	my $inp_offset = tell($fh) - $n_read;
	abort(qq{read_rec(): Error ($plugin at byte: $inp_offset): Invalid Record Type: "$rectype"});
    }
    if (defined($expected_type) and $expected_type ne $rectype) {
	my $inp_offset = tell($fh) - $n_read;
	abort(qq{read_rec(): Error ($plugin at byte: $inp_offset): Expected: "$expected_type", got: "$rectype"});
    }
    my $recbuf = "";
    $n_read = read($fh, $recbuf, $reclen);
    if ($n_read != $reclen) {
	my $inp_offset = tell($fh) - $n_read;
	abort(qq{read_rec(): Read Error ($plugin record at byte: $inp_offset, rec_type="$rectype"): asked for $reclen bytes, got $n_read});
    }
    return($rectype, $recbuf, $hdrflags);
}

sub read_quick_parse {
    my($fh, $expected_type, $plugin) = @_;
    # read a record
    my $rec_hdr = "";
    my $n_read = read($fh, $rec_hdr, $hdr_size);
    if (not $n_read) {
	if (defined $n_read) {
	    return(undef);	# EOF
	} else {
	    abort(qq{Error on read() ($!)});
	}
    }
    if ($n_read != $hdr_size) {
	my $inp_offset = tell($fh) - $n_read;
	abort(qq{read_quick_parse(): Read Error ($plugin header at byte: $inp_offset): asked for $hdr_size bytes, got $n_read});
    }
    # I suspect $reclen2 is the high word of a 64-bit double long, it is effectively unused.
    my($rectype, $reclen, $reclen2, $hdrflags) = unpack("a4LLL", $rec_hdr);
    if (not $TES3::Record::RECTYPES{$rectype}) {
	my $inp_offset = tell($fh) - $n_read;
	abort(qq{new_from_input(): Error ($plugin at byte: $inp_offset): Invalid Record Type: "$rectype"});
    }
    if (defined($expected_type) and $expected_type ne $rectype) {
	my $inp_offset = tell($fh) - $n_read;
	abort(qq{read_quick_parse(): Error ($plugin at byte: $inp_offset): Expected: "$expected_type", got: "$rectype"});
    }
    my $recbuf = "";
    $n_read = read($fh, $recbuf, $reclen);
    if ($n_read != $reclen) {
	my $inp_offset = tell($fh) - $n_read;
	abort(qq{read_quick_parse(): Read Error ($plugin record at byte: $inp_offset, rec_type="$rectype"): asked for $reclen bytes, got $n_read});
    }
    # parse record into a subrecs hash
    my %subrecs;	# hash of (subtype => subbuf_list);
    eval {
	my @parts = unpack("(a4L/a*)*", $recbuf);
	while (my($subtype, $subbuf) = splice(@parts, 0, 2)) {
	    push(@{$subrecs{$subtype}}, $subbuf);
	}
    };
    if ($@) {
	# eval'ed unpack choked, so try a safer (slightly slower) decoder
	%subrecs = ();
	my $p = 0;
	my $reclen = length($recbuf);
	while ($p < $reclen) {
	    my($subtype, $sublen) = unpack("a4L", substr($recbuf, $p));
	    $p += 8;
	    if (defined $sublen) { # MultiMark.esp, I'm looking at you
		my $subbuf = substr($recbuf, $p, $sublen);
		if (defined $subbuf) {
		    push(@{$subrecs{$subtype}}, $subbuf);
		} else {
		    err("read_quick_parse(): ${rectype}.${subtype} has malformed subbuf");
		}
		$p += $sublen;
	    } else {
		if ($TES3::Record::RECTYPES{$rectype}->{$subtype}) {
		    err("read_quick_parse(): ${rectype}.${subtype} has malformed recbuf");
		} else {
		    err(qq{read_quick_parse(): $rectype has malformed subtype: "$subtype"});
		}
	    }
	}
    }
    # calculate record id
    my $id;
    if ($NAMED_TYPE{$rectype}) { # This rectype uses the NAME subrec as its ID
	$id = (unpack("Z*", ($subrecs{NAME}[0])));
    } elsif ($rectype eq "INFO") {
	$id = (unpack("Z*", $subrecs{INAM}[0]));
    } elsif ($rectype eq "CELL") {
	my $name = unpack("Z*", ($subrecs{NAME}[0]));
	my $data = $subrecs{DATA}[0];
	my($flags) = unpack("L", $data);
	if ($flags & 1) {	# interior
	    $id = ($name);
	} else {		# exterior
	    unless ($name) {
		$name = (defined $subrecs{RGNN}) ? unpack("Z*", $subrecs{RGNN}[0]) : 'wilderness';
	    }
	    my($x, $y) = unpack("x[L]ll", $subrecs{DATA}[0]);
	    $id = "$name ($x, $y)";
	}
    } elsif ($rectype eq "PGRD") {
	my $name = unpack("Z*", ($subrecs{NAME}[0]));
	my($x, $y) = unpack("ll", $subrecs{DATA}[0]);
	if ($x == 0 and $y == 0) {
	    $id = $name;
	} else {
	    $id = "$name ($x, $y)";
	}
    } elsif ($rectype eq "SCPT") {
	$id = unpack("Z32", $subrecs{SCHD}[0]);
    } elsif (defined $subrecs{INDX}) {
	$id = unpack("L", $subrecs{INDX}[0]);
    } elsif ($rectype eq "LAND") {
	my($x, $y) = unpack("ll", $subrecs{INTV}[0]);
	$id = "($x, $y)";
    } elsif ($NO_ID_TYPE{$rectype}) {
	$id = ('()');
    } elsif ($rectype eq "SSCR") {
	$id = unpack("Z32", $subrecs{DATA}[0]);
    } else {
	abort("Oops! Don't know how to make ID for rectype: $rectype");
    }
    # rec_id
    return($rectype, lc($id), \%subrecs, $recbuf, $hdrflags);
}

#assert()

sub open_for_input {
    my($plugin) = @_;
    defined($plugin) or abort("no plugin(s) specified!");
    (-d $plugin) and abort(qq{Input is a directory});
    my $fh = IO::Handle->new;
    open($fh, "<", $plugin) or abort(qq{opening "$plugin" for input ($!)});
    binmode($fh, ':raw') or abort("setting binmode on $plugin ($!)");
    return($fh);
}

sub close_input {
    my($inp) = @_;
    close($inp);
}

sub open_for_output {
    my($plugin) = @_;
    my $fh = IO::Handle->new;
    open($fh, ">", $plugin) or abort(qq{opening "$plugin" for output ($!)});
    binmode($fh, ':raw') or abort(qq{setting binmode on "$plugin" ($!)});
    return($fh);
}

sub open_for_append {
    my($plugin) = @_;
    my $fh = IO::Handle->new;
    open($fh, ">>", $plugin) or abort(qq{opening "$plugin" for append ($!)});
    binmode($fh, ':raw') or abort(qq{setting binmode on "$plugin" ($!)});
    return($fh);
}

sub open_for_update {
    my($plugin) = @_;
    my $fh = IO::Handle->new;
    open($fh, "+<", $plugin) or abort(qq{opening "$plugin" for read/write ($!)});
    binmode($fh, ':raw') or abort(qq{setting binmode on "$plugin" ($!)});
    return($fh);
}

sub make_temp {
    my($plugin) = @_;
    abort(qq{"$plugin" does not end in .esm/.esp/.ess})
	if ($plugin !~ /\.(es[mps])$/i);
    my $plugtmp = "$plugin.tmp";
    (-f $plugin) or abort(qq{Invalid input file ($!)});
    my $inp = open_for_input($plugin);
    my $out = open_for_output($plugtmp);
    return($inp, $out);
}

sub unique_backup_name {
    my($plugbak) = @_;
    if (defined $opt_hide_backups) {
	unless (-d $opt_backup_dir) {
	    mkpath($opt_backup_dir, 0755) or
		abort(qq{Unable to make directory: "$opt_backup_dir" ($!)});
	}
	my($file, $dir) = fileparse($plugbak);
	$plugbak = "${opt_backup_dir}/${file}";
    }
    my($ext) = ($plugbak =~ /\.(es[mps])$/i);
    while (-f $plugbak) {
	$plugbak =~ s/(?:~(\d+))?\.$ext$/'~' . (($1||0) + 1) . ".$ext"/e;
    }
    return($plugbak);
}

sub fix_output {
    my($inp, $out, $plugin, $modified, $newname) = @_;
    close($inp);
    close($out);
    my $plugtmp = "$plugin.tmp";
    unless ($modified) {
	print "$plugin was not modified\n";
	unlink($plugtmp);
	return;
    }
    if ($opt_output_dir) {
	$newname = $plugin unless ($newname);
	# prepend given output directory
	$newname = "$opt_output_dir/" . (fileparse($newname))[0];
    }
    if (my($ext) = ($plugin =~ /\.(es[mps])$/i)) {
	my($atime, $mtime) = (stat($plugin))[8,9];
	if (File::Spec->rel2abs($newname) eq File::Spec->rel2abs($plugin)) {
	    msg("fix_output(): newname ($newname) same as plugin ($plugin)");
	    undef $newname;
	}
	if (defined($newname)) {
	    unless ($newname =~ /\.(es[mps])$/i) {
		abort(qq{"$newname" name does not end in .esm/.esp/.ess});
	    }
	    unless (rename($plugtmp, $newname)) {
		abort(qq{Renaming "$plugtmp" to "$newname" ($!)});;
	    }
	    $opt_header_update_record_count = 1;
	    update_header($newname, [qw(QUIET NOBACKUP)]);
	    utime($atime, $mtime, $newname);
	    print qq{Output saved in: "$newname"\nOriginal unaltered: "$plugin"\n};
	} else {
	    my $plugbak = unique_backup_name($plugin);
	    unless (rename($plugin, $plugbak)) {
		abort(qq{Renaming "$plugin" to "$plugbak" ($!)});
	    }
	    unless (rename($plugtmp, $plugin)) {
		abort(qq{Renaming "$plugtmp" to "$plugin" ($!)});
	    }
	    $opt_header_update_record_count = 1;
	    update_header($plugin, [qw(QUIET NOBACKUP)]);
	    utime($atime, $mtime, $plugin);
	    my $destination = $plugbak;
	    $destination =~ s!$DATADIR!<DATADIR>!;
	    print qq{Output saved in: "$plugin"\nOriginal backed up to: "$destination"\n};
	}
    } else {
	abort(qq{"$plugin" name does not end in .esm/.esp/.ess});
    }
} # fix_output

sub cleanup_temp {
    my($inp, $plugin) = @_;
    close($inp);
    my $plugtmp = "$plugin.tmp";
    unlink($plugtmp);
}

# make a map of id -> recbuf for each plugin
sub read_records {
    my($plugin, $fun) = @_;
    my $inp = open_for_input($plugin);
    my %plugin_id = ();
    eval {
	while (my $tr = TES3::Record->new_from_input($inp, undef, $plugin)) {
	    next if ($tr->hdrflags & $HDR_FLAGS{ignored});
	    my $id = $tr->decode()->id;
	    if ($fun) {
		$fun->($tr->rectype, $id, $tr);
	    } else {
		$plugin_id{$tr->rectype}->{$id} = 1 if (defined $id);
	    }
	}
    };
    err($@) if ($@);
    close_input($inp);
    return(\%plugin_id);
}

sub read_objects {
    my($plugin) = @_;
    my $inp = open_for_input($plugin);
    my %plugin_id = ();
    eval {
	while (my $tr = TES3::Record->new_from_input($inp, undef, $plugin)) {
	    next if ($tr->hdrflags & $HDR_FLAGS{ignored});
	    my $id = $tr->decode()->id;
	    $plugin_id{$id}->{$tr->rectype} = $tr if (defined $id);
	}
    };
    err($@) if ($@);
    close_input($inp);
    return(\%plugin_id);
}

sub read_dialogs {
    my($plugin, $dialref) = @_;
    my $inp = open_for_input($plugin);
    eval {
	while (my $tr = TES3::Record->new_from_input($inp, undef, $plugin)) {
	    next if ($tr->hdrflags & $HDR_FLAGS{ignored});
	    next if ($tr->rectype ne "DIAL");
	    my $id = $tr->decode()->id;
	    my $type = $tr->get('DATA', 'type');
	    $dialref->{$plugin}->{$id}++ if ($type == 0 and $id);
	}
    };
    err($@) if ($@);
    close_input($inp);
}

sub master_cache_path {
    my($esm) = @_;
    my $cname = "$CACHE_DIR/${esm}.cache";
    dbg("master_cache_path($esm) -> $cname") if (DBG);
    return($cname);
}

sub load_master_cache {
    my($esm) = @_;
    my $mcache = master_cache_path($esm);
    if ($opt_no_cache) {
	unlink($mcache) if (-f $mcache);
	return(0);
    }
    dbg("master cache name = $mcache") if (DBG);
    eval {
	if (my $listref = retrieve($mcache)) {
	    my($prev_size, $master_data) = @{$listref};
	    my $curr_size = (-s $T3->datapath($esm));
	    if ($curr_size == $prev_size) {
		$MASTER_ID->{$esm} = $master_data;
		print "Loaded cached Master: <DATADIR>/$esm\n";
	    } else {
		die("Cache Invalidated for: $esm (curr_size == $curr_size, prev_size == $prev_size)");
	    }
	} else {
	    die("Error retrieving master cache for: $esm");
	}
    };
    if ($@) {
	msg($@) unless ($@ =~ /: No such file or directory/);
	return(0);
    } else {
	return(1);
    }
}

sub save_master_cache {
    my($esm) = @_;
    return(0) if ($opt_no_cache);
    my $size = (-s $T3->datapath($esm));
    dbg("save_master_cache($esm) saving size: $size") if (DBG);
    store([ $size, $MASTER_ID->{$esm}], master_cache_path($esm));
}

# load all the records from a master .esm into a dictionary.
sub load_master {
    my($esm, $types) = @_;
    $esm = lc($esm);
    dbg("load_master($esm, $types)") if (DBG);
    if (defined $MASTER_ID->{$esm}) {
	dbg("re-using master data: $esm") if (DBG);
	return;
    }
    return if (load_master_cache($esm)); # load pre-parsed data
    print "Loading Master: $esm\n";
    my $master_file = $T3->datapath($esm);
    if (not $master_file) {
	err("Master: $esm not found in <DATADIR>");
	return;
    }
    my $inp = open_for_input($master_file);
    eval {
	while (my($rectype, $id, $srh, $recbuf, $hdrflags) = read_quick_parse($inp, undef, $esm)) {
	    last if (not defined $rectype);
	    next if ($hdrflags & $HDR_FLAGS{ignored});
	    next if (defined $types and not $types->{$rectype});
	    #dbg("rec_type = $rectype") if (DBG);
	    abort("undefined recbuf") unless defined $recbuf;
	    $MASTER_ID->{$esm}->{$id}->{$rectype} = [$recbuf, $hdrflags];
	}
    };
    err($@) if ($@);
    close_input($inp);
    save_master_cache($esm);
}

sub load_mergeable_objects {
    my $cachedata = {};
    my $mergeable_object_cache_file = "$CACHE_DIR/mergeable_object_data.cache";
    # load cache
    if ($opt_no_cache) {
	unlink($mergeable_object_cache_file)
	    if (-f $mergeable_object_cache_file);
    } else {
	if (-f $mergeable_object_cache_file) {
	    eval { $cachedata = retrieve($mergeable_object_cache_file); };
	    if ($@) {
		msg("Invalid Mergeable Objects Cache, will rebuild");
		$cachedata = {};
	    }
	} else {
	    msg("Creating Mergeable Objects Cache");
	}
    }
    # Invalidate entire cache when codec changes
    if (defined($cachedata->{_codec_version_}) and $cachedata->{_codec_version_} ne $TES3::Record::CODEC_VERSION) {
	err("Invalidating Mergeable Object Cache due to CODEC update.");
	$cachedata = {_codec_version_ => $TES3::Record::CODEC_VERSION };
    }
    my @load_order = $T3->load_order;
    my %active = map { lc($_), 1 } @load_order;
    foreach my $plugin (@load_order) {
	my $lc_plugin = lc($plugin);
	# skip known merged objects plugins
	next if ($lc_plugin eq "multipatch.esp");
	if ($lc_plugin eq "merged_objects.esp") {
	    msg(qq{WARNING! "Merged_Objects.esp" is not needed when using multipatch})
		if ($opt_multipatch_merge_objects);
	    next;
	}
	my $curr_size = -s $T3->datapath($plugin);
	my $invalid = 0;
	if (defined($cachedata->{$lc_plugin})) {
	    # update plugins that have changed size
	    unless ($curr_size == $cachedata->{$lc_plugin}->{_size_}) {
		msg("Mergeable Objects Cache UPDATING: $plugin");
		delete $cachedata->{$lc_plugin};
		$invalid = 1;
	    }
	} else {
	    # add plugins added to load order
	    prn("Mergeable Objects Cache ADDING: $plugin") if (VERBOSE);
	    $invalid = 1;
	}
	if ($invalid) {
	    my $inp = open_for_input($T3->datapath($plugin));
	    eval {
		while (my $tr = TES3::Record->new_from_input($inp, undef, $plugin)) {
		    next unless ($TYPE_INFO{$tr->rectype}->{canmerge});
		    next if ($tr->hdrflags & $HDR_FLAGS{ignored});
		    $tr->decode;
		    $cachedata->{$lc_plugin}->{$tr->rectype}->{$tr->id} = $tr;
		}
	    };
	    close_input($inp);
	    if ($@) {
		err($@);
		delete $cachedata->{$lc_plugin};
	    } else {
		$cachedata->{$lc_plugin}->{_size_} = $curr_size;
	    }
	}
    }
    # delete plugins no longer in load order
    foreach my $plugin (keys %$cachedata) {
	delete $cachedata->{$plugin} unless ($active{$plugin});
    }
    # save cache
    unless ($opt_no_cache) {
	store($cachedata, $mergeable_object_cache_file);
    }
    return($cachedata);
} # load_mergeable_objects

sub load_leveled_lists {
    my $cachedata = {};
    my $leveled_list_cache_file = "$CACHE_DIR/leveled_lists_data.cache";
    # load cache
    if ($opt_no_cache) {
	unlink($leveled_list_cache_file)
	    if (-f $leveled_list_cache_file);
    } else {
	if (-f $leveled_list_cache_file) {
	    eval { $cachedata = retrieve($leveled_list_cache_file); };
	    if ($@) {
		msg("Invalid Leveled Lists Cache, will rebuild");
		$cachedata = {};
	    }
	} else {
	    msg("Creating Leveled Lists Cache");
	}
    }
    # Invalidate entire cache when codec changes
    if (defined($cachedata->{_codec_version_}) and $cachedata->{_codec_version_} ne $TES3::Record::CODEC_VERSION) {
	err("Invalidating Leveled List Cache due to CODEC update.");
	$cachedata = {_codec_version_ => $TES3::Record::CODEC_VERSION };
    }
    my @load_order = $T3->load_order;
    my %active = map { lc($_), 1 } @load_order;
    foreach my $plugin (@load_order) {
	my $lc_plugin = lc($plugin);
	# skip known merged leveled lists plugins
	next if ($lc_plugin eq "multipatch.esp");
	if ($lc_plugin eq "mashed lists.esp") {
	    msg(qq{WARNING! "Mashed Lists.esp" is not needed when using multipatch})
		if ($opt_multipatch_merge_lists);
	    next;
	}
	if ($lc_plugin eq "merged_leveled_lists.esp") {
	    msg(qq{WARNING! "Merged_Leveled_Lists.esp" is not needed when using multipatch})
		if ($opt_multipatch_merge_lists);
	    next;
	}
	my $curr_size = -s $T3->datapath($plugin);
	my $invalid = 0;
	if (defined($cachedata->{$lc_plugin})) {
	    # update plugins that have changed size
	    unless ($curr_size == $cachedata->{$lc_plugin}->{_size_}) {
		msg("Leveled List Cache UPDATING: $plugin");
		delete $cachedata->{$lc_plugin};
		$invalid = 1;
	    }
	} else {
	    # add plugins added to load order
	    prn("Leveled List Cache ADDING: $plugin") if (VERBOSE);
	    $invalid = 1;
	}
	if ($invalid) {
	    my $inp = open_for_input($T3->datapath($plugin));
	    eval {
		while (my $tr = TES3::Record->new_from_input($inp, undef, $plugin)) {
		    next unless ($tr->rectype =~ /^LEV[CI]$/);
		    next if ($tr->hdrflags & $HDR_FLAGS{ignored});
		    $tr->decode;
		    $cachedata->{$lc_plugin}->{$tr->rectype}->{$tr->id} = $tr;
		}
	    };
	    close_input($inp);
	    if ($@) {
		err($@);
		delete $cachedata->{$lc_plugin};
	    } else {
		$cachedata->{$lc_plugin}->{_size_} = $curr_size;
	    }
	}
    }
    # delete plugins no longer in load order
    foreach my $plugin (keys %$cachedata) {
	delete $cachedata->{$plugin} unless ($active{$plugin});
    }
    # save cache
    unless ($opt_no_cache) {
	store($cachedata, $leveled_list_cache_file);
    }
    return($cachedata);
} # load_leveled_lists

### MAIN UTILITIES

sub compare_records {
    my($oldbuf, $newbuf) = @_;
    return(0) if (length($oldbuf) != length($newbuf));
    # check to see if this is just a mis-match on junk leftover in the end of a z-string field.
    if (length($oldbuf) == length($newbuf)) {
	for (my $i=0; $i<length($newbuf); $i++) {
	    my $old_c = substr($oldbuf, $i, 1);
	    my $new_c = substr($newbuf, $i, 1);
	    if (($old_c ne $new_c) and ($new_c ne "\000")) {
		return(0); # compare NOT ok
	    }
	}
    }
    return(1);	    # compare OK
}

sub diff_output {
    my($diff_file, $diff) = @_;
    if (@{$diff}) {
	my $fh = IO::Handle->new;
	if (open($fh, ">$diff_file")) {
	    print $fh join("\n", @{$diff});
	    close($fh);
	    prn("Created diff file: $diff_file");
	} else {
	    err("Opening $diff_file for output ($!)");
	}
    }
}

sub make_header {
    my($opt) = @_;
    my $hedr = pack("a4L/a*", 'HEDR',
		    pack("fLZ${HDR_AUTH_LENGTH}Z${HDR_DESC_LENGTH}L",
			 ($opt->{version} || 1.3),
			 ($opt->{is_master} || 0),
			 (defined($opt->{author}) ? $opt->{author} : "tes3cmd"),
			 (defined($opt->{description}) ? $opt->{description} : "(generated)"),
			 ($opt->{n_records} || 0)));
    # I suspect $reclen2 is the high word of a 64-bit double long, it is effectively unused.
    my $tes3 = pack("a4LLLa*", 'TES3', length($hedr), (my $reclen2 = 0), (my $flags = 0), $hedr);
    abort("Invalid TES3 header definition has incorrect size.")
	unless (length($tes3) == MIN_TES3_PLUGIN_SIZE);
    return($tes3);
}

sub update_header {
    my($plugin, $options) = @_;
    if (($opt_header_update_record_count or $opt_header_update_masters) and
	($plugin =~ /~\d+\.es[mp]$/i)) {
	prn("tes3cmd header skipping Backup: $plugin");
	return;
    }
    my $quiet = grep(/\bQUIET\b/, @$options);
    my $nobackup = grep(/\bNOBACKUP\b/, @$options);
    my $master;
    my($atime, $mtime) = (stat($plugin))[8,9];
    my $fh = open_for_update($plugin);
    my $tr = TES3::Record->new_from_input($fh, 'TES3', $plugin);
    unless (defined $tr) {
	err("Error reading TES3 header from $plugin");
	return;
    }
    my $tes3len = $tr->decode()->reclen();
    my $update_msg = '';
    my $modified = 0;
    my $hedr_tsr;
    foreach my $tsr ($tr->subrecs()) {
	my $subtype = $tsr->subtype;
	if ($subtype eq 'HEDR') {
	    $hedr_tsr = $tsr;
	    if ($opt_header_author) {
		$modified++;
		$tsr->{author} =~ s!\000+$!!;
		dbg("HEDR modified: author") if (DBG);
		if ($opt_header_author =~ /^\+(.*)/) {
		    $tsr->{author} .= $1;
		} else {
		    $tsr->{author} = $opt_header_author;
		}
	    }
	    if ($opt_header_description) {
		$modified++;
		$tsr->{description} =~ s!\000+$!!;
		dbg("HEDR modified: description: $opt_header_description") if (DBG);
		$opt_header_description =~ s/\\n/\n/g;
		$opt_header_description =~ s/\\r/\r/g;
		if ($opt_header_description =~ /^\+(.*)/) {
		    $tsr->{description} .= $1;
		} else {
		    $tsr->{description} = $opt_header_description;
		}
	    }
	    if ($opt_header_update_record_count) {
		my $count = get_record_count($plugin);
		if ($tsr->{n_records} != $count) {
		    $modified++;
		    dbg("HEDR modified: record count") if (DBG);
		    $update_msg .= qq{  $plugin: Updated Record Count: $tsr->{n_records} --> $count\n};
		    $tsr->{n_records} = $count;
		}
	    }
	}
	if ($opt_header_update_masters) {
	    if ($subtype eq 'MAST') {
		$master = $tsr->{master};
	    } elsif ($subtype eq 'DATA') {
		my $length = $tsr->{length};
		if (defined($master)) {
		    if ((my $newlen = -s ($T3->datapath($master))) != $length) {
			$modified++;
			dbg("HEDR modified: synced masters") if (DBG);
			$update_msg .= qq{  $plugin: Synchronized master "$master" length: $length --> $newlen\n};
			$tsr->{length} = $newlen;
		    }
		} else {
		    err("Found DATA (size of master) but no corresponding MAST (name of master)");
		}
	    }
	}
    }
    unless ($quiet) {
	if (VERBOSE) {
	    print "$plugin:\n" . $tr->tostr() . "\n";
	} else {
	    if (not($opt_header_author or $opt_header_description or $opt_header_update_record_count or
		    $opt_header_update_masters or $opt_header_update_record_count) or
		$opt_header_author or $opt_header_description) {
		if ($opt_header_multiline) {
		    print qq{$plugin:\n}, $hedr_tsr->tostr, "\n";
		} else {
		    my $auth = $hedr_tsr->{author};
		    $auth =~ s!\000.*$!!;
		    my $desc = $hedr_tsr->{description};
		    $desc =~ s!\000.*$!!;
		    my $msg = qq{$plugin: AUTH="$auth"  DESC="$desc"};
		    $msg =~ s/(\r)?\n/\\r\\n/gm;
		    print "$msg\n";
		}
	    }
	}
	if ($update_msg) {
	    print $update_msg;
	} else {
	    print "$plugin not modified\n" if (VERBOSE);
	}
    }
    if ($modified) {
	unless ($nobackup) {
	    # make backup of plugin before making changes only if updating
	    my $backup = unique_backup_name($plugin);
	    copy($plugin, $backup) or abort("Error, copy failed $plugin -> $backup ($!)");
	}
	$tr->encode;
	if ($tr->reclen() == $tes3len) {
	    seek($fh, 0, SEEK_SET);
	    $tr->write_rec($fh);
	} else {
	    abort("update_header(): output header size incorrect (expected:$tes3len, got: @{[$tr->reclen()]})");
	}
    }
    close($fh);
    utime($atime, $mtime, $plugin);
}				# update_header

sub get_wanted {
    # set up global wanted record selectors
    $WANTED_IDS = $WANTED_FLAGS = $WANTED_TYPES = undef;
    my @wanted_ids = @opt_id;
    push(@wanted_ids, map { '^'.quotemeta($_).'$' } @opt_exact_id) if (@opt_exact_id);
    $WANTED_IDS = (@wanted_ids) ? '(' . join('|', @wanted_ids) . ')' : '';
    foreach my $flag (@opt_flag) {
	if ($flag =~ /^(?:0[xob])?\d+$/) {
	    $WANTED_FLAGS |= (eval $flag); # it's a numeric flag
	} else {
	    $WANTED_FLAGS |= $HDR_FLAGS{lc($flag)};
	}
    }
    if ($opt_instance_match or $opt_instance_no_match or $opt_exterior or $opt_interior) {
	# assume type == CELL if user selects object instance matching or interior/exterior
	if (@opt_type and (uc("@opt_type") ne "CELL")) {
	    if ($opt_exterior or $opt_interior) {
		msg("Specifying --interior/--exterior assumes --type CELL");
	    }
	    if ($opt_instance_match or $opt_instance_no_match) {
		msg("Specifying --instance-match/--instance-no-match assumes --type CELL");
	    }
	}
	@opt_type = qw(cell);
    }
    if (@opt_type) {
	foreach my $option (@opt_type) {
	    my($wrectype, $wsubtype) = split(/\./, uc($option));
	    if ($wrectype eq 'NPC') {
		msg('[Using "NPC" as shorthand for "NPC_" record type.]');
		$wrectype = 'NPC_';
	    }
	    if (length($wrectype) != 4) {
		abort(qq{get_wanted_types: Invalid record type: "$wrectype" (must be 4 characters long)});
	    }
	    $WANTED_TYPES->{$wrectype}++;
	    if ($wsubtype) {
		if (length($wsubtype) == 4) {
		    $WANTED_TYPES->{"$wrectype.$wsubtype"}++;
		} else {
		    abort(qq{get_wanted_types: Invalid record subtype: "$wsubtype" (must be 4 characters long)});
		}
	    }
	}
    }
}

# return 1 if record matches selection criteria of command line switches
sub rec_match {
    my($plugin, $rectype, $tr) = @_;
    $tr->decode if ($rectype eq 'DIAL');
    return(0, $rectype, $tr) if ($WANTED_FLAGS and not ($tr->hdrflags & $WANTED_FLAGS));
    return(0, $rectype, $tr) if ($WANTED_TYPES and not $WANTED_TYPES->{$rectype});
    $tr->decode unless ($rectype eq 'DIAL');
    return(0, $rectype, $tr) if ($WANTED_IDS and not ($tr->id =~ /$WANTED_IDS/i));
    if ($rectype eq 'CELL') {
	if ($tr->is_interior()) {
	    return(0, $rectype, $tr) if ($opt_exterior);
	} else {
	    return(0, $rectype, $tr) if ($opt_interior);
	}
    }
    if (@opt_match or @opt_no_match) {
	my $print_rec = $tr->tostr;
	# record must not match ANY pattern in --no-match
	foreach my $no_match (@opt_no_match) {
	    return(0, $rectype, $tr, $print_rec)
		if ($print_rec =~ /$no_match/is);
	}
	# record must not match ALL patterns in --match
	foreach my $match (@opt_match) {
	    return(0, $rectype, $tr, $print_rec)
		if ($print_rec !~ /$match/is);
	}
	return(1, $rectype, $tr, $print_rec);
    } else {
	return(1, $rectype, $tr);
    }
}

sub get_record_count {
    my($plugin) = @_;
    my $count = 0;
    my $inp = open_for_input($plugin);
    eval {
	my($rectype, $recbuf, $hdrflags) = read_rec($inp, 'TES3', $plugin); # we don't count the TES3 record
	while (($rectype, $recbuf, $hdrflags) = read_rec($inp, undef, $plugin)) {
	    last if (not defined $rectype);
	    $count++;
	}
    };
    err($@) if ($@);
    close_input($inp);
    return($count);
}

sub dumpit {
    my($label, $it) = @_;
    $it =~ s/([[:cntrl:]])/"^".chr(ord($1)+64)/ge;
    prn("$label: [$it]" . ((DBG) ? "\n".unpack("H*", $it) : ''));
}

# turn a group (list) of CELL subrecs into [objidx and recbuf]
sub buffalize {
    my(@this_group) = @_;
    my($objidx, $recbuf, $objname);
    my $frmr_tsr = shift(@this_group);
    # TBD (per abot) we check for MVRF here too, but we need to handle MVRFs better
    if (($frmr_tsr->subtype eq 'FRMR') or (($frmr_tsr->subtype eq 'MVRF'))) {
	$objidx = $frmr_tsr->{objidx};
    } else {
	abort("Oops! Expected first subrec of group to be FRMR, instead got: ".$frmr_tsr->subtype);
    }
    foreach my $tsr (@this_group) {
	$objname = $tsr->{name}
	    if (not(defined $objname) and $tsr->subtype eq 'NAME');
	$recbuf .= $tsr->subbuf;
    }
    return($objidx, $recbuf, $objname);
}

sub process_plugin_for_input {
    my($plugin, $fun) = @_;
    my $expected = "TES3";
    # TBD - to support using instance types, will need to load masters
    # process each record in the plugin
    eval {
	my $inp = open_for_input($plugin);
	while (my $tr = TES3::Record->new_from_input($inp, $expected, $plugin)) {
	    $expected = undef;
	    $fun->($tr->{_rectype_}, $tr);
	}
	close_input($inp);
    };
    if ($@) {
	if ($@ =~ /^Can't locate object method/) {
	    warn qq{FATAL ERROR ($plugin): $@};
	} else {
	    warn($@);
	}
	return(0);
    } else {
	return(1);
    }
} # process_plugin_for_input

sub process_plugin_for_update {
    my($plugin, $fun, $prefix) = @_;
    my $expected = "TES3";
    my $modified;
    my($inp, $out);
    # TBD - to support using instance types, will need to load masters
    # process each record in the plugin
    eval {
	($inp, $out) = make_temp($plugin);
	while (my $tr = TES3::Record->new_from_input($inp, $expected, $plugin)) {
	    $expected = undef;
	    # function can delete, modify, or pass rec thru
	    my $trnew = $fun->($tr->rectype, $tr);
	    if (defined $trnew) { # rec was kept
		if ($trnew) {	   # rec was changed
		    $trnew->write_rec($out);
		    dbg("process_plugin_for_update: record modified") if (DBG);
		    if (VERBOSE) {
			my $rectype = $tr->rectype;
			my $id = $tr->id;
			prn("UPDATED PLUGIN: $plugin") if (not $modified);
			prn("RECORD MODIFIED: $rectype $id");
		    }
		    $modified++;
		} else {	# null return record, so pass original rec through unchanged
		    dbg("process_plugin_for_update: record PASSED THROUGH unmodified") if (DBG);
		    $tr->write_rec($out);
		}
	    } else {		# undefined return indicates rec to be deleted
		if (VERBOSE) {
		    my $rectype = $tr->rectype;
		    my $id = $tr->id;
		    prn("UPDATED PLUGIN: $plugin") if (not $modified);
		    prn("RECORD DELETED: $rectype $id");
		}
		$modified++;
	    }
	}
    };
    if ($@) {
	$modified = 0;	    # do not modify original plugin if errors occurred
	if ($@ =~ /^Can't locate object method/) {
	    warn qq{FATAL ERROR ($plugin): $@};
	} else {
	    warn($@);
	}
	return(0);	    # TBD double check if need to cleanup tmp (output)
    }
    if ($prefix) {
	my($file, $dir) = fileparse($plugin);
	my $newname = ($dir eq './') ? "${prefix}${file}" : "${dir}${prefix}${file}";
	fix_output($inp, $out, $plugin, $modified, $newname);
    } else {
	dbg("modified = $modified") if (DBG);
	fix_output($inp, $out, $plugin, $modified);
    }
    return(1);
} # process_plugin_for_update

# get the object instance (reference) name from a FRMR group of subrecords
sub instance_name {
    foreach (@_) {
	return($_->{name}) if ($_->subtype eq 'NAME');
    }
    return(undef);
}

### MAIN COMMANDS

# format a simple report for the given items
sub lint_report {
    my($items, $label) = @_;
    my @itemlist = sort keys %$items;
    if (@itemlist) {
	my $format = "\t%-35s  %s\n";
	print "    $label:\n";
	foreach (@itemlist) {
	    my($name, $val) = split(/\t/, $_, 2);
	    if ($val) {
		printf $format, $name, $val;
	    } else {
		print "\t$name\n";
	    }
	}
    }
}

sub cmd_lint {
    my($plugin) = @_;
    dbg("cmd_lint") if (DBG);
    my %tbfun;
    my %bmfun;
    my %deplst;
    my %getsound;
    my %menumode;
    my %my_master;
    my %evil;
    my $evil_tb = 0;
    my $evil_bm = 0;
    my @fogsync = ();
    my @autospl = ();
    my %fogbug = ();
    my %myinf = ();
    my %myinftxt = ();
    my %myrec = ();
    my %myid = ();
    my %door = ();
    my %myjunk = ();
    my @master_sizes = ();
    my $missauth = 0;
    my $missdesc = 0;
    my $missver = 0;
    my @sscr = ();
    my $mastbm = 0;
    my $masttb = 0;
    my $cell00 = undef;
    my $expected = "TES3";
    my $cur_dial;
    my $read_info; # = ($CHK_CHANGED_INFO_IDS or $CHK_DUPLICATE_INFO or $CHK_MODIFIED_INFO);
    my $read_scpt; # = ($CHK_EXPANSION_FUNCTIONS or $CHK_NO_EXPANSION_FUNS or $CHK_DEPRECATED_LISTFUN or $CHK_GETSOUNDPLAYING or $OPTFLAG{MENUMOD});
    my $read_gmsts = ($opt_lint_evil_gmsts or $opt_lint_duplicate_records or $opt_lint_overrides);
    my $read_cell = ($opt_lint_junk_cells or $opt_lint_fogbug or $opt_lint_fogsync or $opt_lint_duplicate_records);
    my %dial_info = ();
    my %info_dial = ();
    my $fun = sub {
	my($rectype, $tr) = @_;
	if ($read_gmsts and ($rectype eq 'GMST')) {
	    $tr->decode;
	    my $id = $tr->id;
	    my($type, $field) = @{$GMST_TYPE{substr($id, 0, 1)}};
	    my $val_tsr = $tr->get($type);
	    if ($val_tsr) {
		my $val = $val_tsr->subbuf;
		my $hexval = unpack("H*", "$type $val");
		if (defined($EVIL_BM{$id}) and ($EVIL_BM{$id} eq $hexval)) {
		    $evil{"BM $id"}++;
		    $evil_bm++;
		} elsif (defined($EVIL_TB{$id}) and ($EVIL_TB{$id} eq $hexval)) {
		    $evil{"TB $id"}++;
		    $evil_tb++;
		}
	    }
	} elsif ($rectype eq 'SPEL') {
	} elsif ($rectype eq 'TES3') {
	    $tr->decode;
	    foreach my $master ($tr->getall('MAST', 'master')) {
		$my_master{lc($master)}++;
		load_master($master);
	    }
	}
    };
    process_plugin_for_input($plugin, $fun) or return(0);
    my $found = "";
    $found .= " AUTOSPL" if (@autospl);
    $found .= " CELL00"  if ($cell00);
    # $found .= " BM-DEP"  if ((not $mastbm) and %bmfun);
    # $found .= " DEP-LST" if (%deplst);
    # $found .= " DUP-INF" if ($dup_inf);
    # $found .= " DUP-REC" if (%dup_recs);
    # $found .= " EXP-DEP" if (not $masttb and not $mastbm and (@sscr or %tbfun));
    # $found .= " FOGBUG"  if ($OPTFLAG{FOGBUG} and %fogbug);
    # $found .= " FOGSYNC" if ($OPTFLAG{FOGSYNC} and @fogsync);
    # $found .= " GETSND"  if (%getsound);
    $found .= " EVLGMST" if (%evil);
    # $found .= " JUNKCEL" if (%junkcell);
    # $found .= " MASTERS" if ($master_sync);
    # $found .= " MENUMOD" if (%menumode);
    # $found .= " MISSAUT" if ($OPTFLAG{MISSAUT} and $missauth);
    # $found .= " MISSDSC" if ($OPTFLAG{MISSDSC} and $missdesc);
    # $found .= " MISSVER" if ($OPTFLAG{MISSVER} and $missver);
    # $found .= " MOD-INF" if ($mod_inf and $OPTFLAG{'MOD-INF'});
    # $found .= " MOD-IID" if ($mod_iid);
    # $found .= " NUMRECS" if ($OPTFLAG{NUMRECS} and $rec_count != $hdr_nrec);
    # $found .= " OVR-REC" if (%ovr_recs);
    # $found .= " SCRDOOR" if (%door);
    # if ($CHK_NO_EXPANSION_FUNS) {
    # 	$found .= " !BM-FUN" if ($OPTFLAG{'!BM-FUN'} and $mastbm and not(%bmfun or @sscr));
    # 	$found .= " !TB-FUN" if ($OPTFLAG{'!TB-FUN'} and $masttb and not(%tbfun or %bmfun or @sscr));
    # }
    if ($found) {
     	print "$plugin:$found\n";
    } else {
     	print "$plugin: CLEAN\n" if ($opt_lint_clean);
     	return;
    }
    ##################################################
    # now print out verbose detail, if applicable
    ##################################################
    # print $master_sync if ($master_sync);
    # if (@autospl) {
    # 	print "    [AUTOSPL] Auto-calced Spells:\n";
    # 	foreach my $spell (@autospl) {
    # 	    print "\t$spell\n";
    # 	}
    # }
    # if ($OPTFLAG{NUMRECS} and $rec_count != $hdr_nrec) {
    # 	print "    [NUMRECS]: number of records in TES3.HEDR ($hdr_nrec) != Actual count ($rec_count)\n";
    # }
    # if ($cell00) {
    # 	print "    [CELL00]: $cell00\n";
    # }
    # if (@sscr and not $masttb and not $mastbm) {
    # 	my $pl = (scalar(@sscr) > 1) ? "s" : "";
    # 	print "    [EXP-DEP] Expansion Dependency: Startup Script$pl: ", join(", ", @sscr), "\n";
    # }
    # lint_report(\%tbfun, "[EXP-DEP] Expansion Dependency: Tribunal Functions") if (not $masttb and not $mastbm);
    # lint_report(\%bmfun, "[BM-DEP] Bloodmoon Dependency: Bloodmoon Functions") if ($OPTFLAG{'BM-DEP'} and not $mastbm);
    # lint_report(\%deplst, "[DEP-LST] Deprecated use of Leveled List functions on Bethesda Lists");
    lint_report(\%evil, "[EVLGMST]" . (($evil_tb > 0)? " Tribunal($evil_tb)" : "") . (($evil_bm > 0)? " Bloodmoon($evil_bm)" : ""));
    # if (%fogbug) {
    # 	print "    [FOGBUG]: Cells with zero fog density setting:\n";
    # 	print "\t$_\n" foreach (sort keys %fogbug);
    # }
    # if (@fogsync) {
    # 	print "    [FOGSYNC]: Fog density settings unsynced:\n";
    # 	foreach my $cell (@fogsync) {
    # 	    print "\t$cell\n";
    # 	}
    # }
    # report(\%getsound, "[GETSND] GetSoundPlaying possibly used to detect events");
    # report(\%menumode, "[MENUMOD] Scripts not checking menumode");
    # report(\%door, "[SCRDOOR] Bethesda doors that have had scripts attached to them");
    # if (%junkcell) {
    # 	if ($::opt_v) {
    # 	    print "    [JUNKCEL] Junk Cells:                        Flags\n";
    # 	} else {
    # 	    print "    [JUNKCEL] Junk Cells:\n";
    # 	}
    # 	my $format = "\t%-36s     0x%02x\n";
    # 	foreach my $name (sort keys %junkcell) {
    # 	    if ($::opt_v) {
    # 		my $flags = $junkcell{$name};
    # 		printf $format, $name, $flags;
    # 	    } else {
    # 		printf "\t$name\n";
    # 	    }
    # 	}
    # }
    # report_recs(\%dup_dial, "[DUP-DIAL] Duplicate Dialog Records");
    # report_recs(\%dup_recs, "[DUP-REC] Duplicate Records");
    # report_recs(\%ovr_recs, "[OVR-REC] Overridden Records");
    # $| = 1;			# flush STDOUT
    # print $inf_out;
    # if (open(STAT, "/proc/$$/status")) {
    # 	while (<STAT>) {
    # 	    if (/^VmRSS:\s*(\d+)/) {
    # 		my $vmsize = $1 / 1024;
    # 		warn "### tes3lint($plugin) Memory Usage: $vmsize (MB)\n" if ($::opt_v);
    # 	    }
    # 	}
    # 	close(STAT);
    # }
    # $| = 0;
}

sub cmd_testcodec {
    my($plugin) = @_;
    dbg("cmd_testcodec($plugin)") if (DBG);
    return if ($plugin =~ /^test_/);
    my %exclude;
    if (@opt_testcodec_exclude_type) {
	# optional types to exclude
	foreach (@opt_testcodec_exclude_type) { $exclude{uc($_)}++; }
    }
    print "\n", ("=" x 65), "\n";
    print "TESTING codec on: $plugin ...\n";
    my %type_count;
    my %crufty;
    my $fun = sub {
	my($rectype, $tr) = @_;
	my $id = $tr->decode()->id;
	my $trnew = TES3::Record->new_from_recbuf($rectype, '', $tr->hdrflags);
	foreach my $tsr ($tr->subrecs()) {
	    my $oldsubrec = $tsr->subbuf;
	    die "no buf: " . Dumper($tsr). "\n" if (not defined $oldsubrec);
	    my $newsubrec = $tsr->encode()->subbuf;
	    my $fulltype = $tsr->fulltype;
	    unless ($exclude{$fulltype}) {
		if ($newsubrec ne $oldsubrec) {
		    if ($opt_testcodec_ignore_cruft and compare_records($oldsubrec, $newsubrec)) {
			$crufty{$fulltype}++;
		    } else {
			msg("CODEC FAILURE on ($id) SUBTYPE: ${fulltype}:");
			if (length($newsubrec) != length($oldsubrec)) {
			    msg("Encoded length mismatch: subrec: @{[length($oldsubrec)]}  newrec: @{[length($newsubrec)]}");
			}
			dumpit('original', $oldsubrec);
			dumpit('re-coded', $newsubrec);
			#msg(Dumper($tsr));
			msg($tr->tostr);
			abort("Test Halted") unless ($opt_testcodec_continue);
		    }
		}
	    }
	    $trnew->append($tsr);
	}
	my $newrec = $trnew->encode()->recbuf;
	unless ($exclude{$rectype}) {
	    if ((my $oldrec = $tr->recbuf) ne $newrec) {
		if ($opt_testcodec_ignore_cruft and compare_records($oldrec, $newrec)) {
		    $crufty{$rectype}++;
		} else {
		    msg("CODEC FAILURE on ($id) RECTYPE: ${rectype}:");
		    dumpit('original', $oldrec);
		    dumpit('re-coded', $newrec);
		    my $print_rec = $tr->tostr;
		    prn("Full Record:\n$print_rec");
		    #dbg("trnew Dump=".Dumper($trnew)); exit;
		}
	    }
	}
	return($trnew);
    };
    process_plugin_for_update($plugin, $fun, "test_") or return(0);
    my(@crufty_types) = sort keys %crufty;
    if (scalar(@crufty_types) > 0) {
	print "\nThe following types in the original plugins contain cruft:\n";
	foreach my $type (@crufty_types) {
	    print "  $type\n" unless(grep(/$type\./, @crufty_types));
	}
    }
} # cmd_testcodec

sub cmd_fixit {
    dbg("cmd_fixit") if (DBG);
    # reset dates on Bethesda data files
    cmd_resetdates();
    # clean everything and overwrite originals and hide backups
    $opt_hide_backups = $opt_overwrite = $opt_clean_instances = $opt_clean_cell_params =
	$opt_clean_dups = $opt_clean_gmsts = $opt_clean_junk_cells = 1;
    foreach my $plugin ($T3->load_order()) {
	cmd_clean($CURRENT_PLUGIN = $plugin)
    }
    # generate all patches
    $opt_multipatch_cellnames = $opt_multipatch_fogbug = $opt_multipatch_merge_lists =
	$opt_multipatch_merge_objects = $opt_multipatch_summons_persist = 1;
    cmd_multipatch();
    # synchronize plugin headers to masters
    prn("\n\nSynchronizing Plugin Headers...");
    $opt_header_update_masters = $opt_header_update_record_count = 1;
    foreach my $plugin ($T3->load_order()) {
	cmd_header($CURRENT_PLUGIN = $plugin)
    }
}

sub multipatch_check_fogbug {
    my($plugin, $tr, $fogcell) = @_;
    my $name = $tr->id;
    my $tsr_data = $tr->get('DATA');
    my $tsr_ambi = $tr->get('AMBI');
    my $fog_den_data = $tsr_data->{fog_density};
    my $fog_den_ambi = $tsr_ambi->{fog_density};
    return unless (defined($fog_den_ambi) and defined($fog_den_data)); # TBD should we continue if one is defined?
    if ($fog_den_ambi != $fog_den_data) {
	print "$plugin: [CELL $name] Warning, Fog Density in DATA ($fog_den_data) != AMBI ($fog_den_ambi)\n";
    }
    if ((0.0 == $fog_den_ambi) or (0.0 == $fog_den_data)) {
	print "  [FOGBUG] $plugin\t\tCELL: $name\n" if (VERBOSE);
	my $trnew = CELL->new([$tsr_data, $tsr_ambi]);
	$fogcell->{$name} = [$tr, $plugin];
    } else {
	if (defined($fogcell->{$name})) {
	    print qq{  [FOGBUG] CORRECTED $plugin CELL: $name\n} if (VERBOSE);
	    delete $fogcell->{$name};
	}
    }
}

sub multipatch_check_cell_rename_reversions {
    my($plugin, $tr, $rencell) = @_;
    my $name = $tr->get('NAME', 'name');
    my $coord = $tr->get('DATA', 'x') . ", " . $tr->get('DATA', 'y');
    if (exists $rencell->{$coord}->{NAME}) {
	my $prevname = $rencell->{$coord}->{NAME};
	if ($prevname ne $name) {
	    if ($name eq $rencell->{$coord}->{ORIGNAME}) {
		print qq{  [REVNAME] CELL: ($coord) RENAME REVERTED by: [$plugin] from: "$prevname" to: "$name". Reversion will be undone.\n} if (VERBOSE);
		$rencell->{$coord}->{OUTPUTFLAG}++;
	    } elsif ($name) {
		print qq{  [REVNAME] CELL: ($coord) Renamed by: [$plugin] from: "$prevname" to: "$name"\n} if (VERBOSE);
		my $prevname = $rencell->{$coord}->{NAME};
		my $prevplug = $rencell->{$coord}->{PLUG};
		print qq{  [REVNAME] CELL: ($coord) Replacing: [$prevplug]:"$prevname" with: [$plugin]:"$name"\n} if (VERBOSE);
		my $trnew = CELL->new([$tr->get('NAME'), $tr->get('DATA')]);
		$rencell->{$coord}->{NAME} = $name;
		$rencell->{$coord}->{PLUG} = $plugin;
		$rencell->{$coord}->{REC} = $trnew;
	    } else {
		print qq{  [REVNAME] CELL: ($coord) Skipping null name: [$plugin]:"$name"\n} if (VERBOSE);
	    }
	}
    } else {
	$rencell->{$coord}->{ORIGNAME} = $name;
	$rencell->{$coord}->{ORIGPLUG} = $plugin;
	$rencell->{$coord}->{NAME} = $name;
	$rencell->{$coord}->{PLUG} = $plugin;
    }
} # multipatch_check_cell_rename_reversions

#*** Object Merge Gotchas
#**** autocalced vs. non-autocalced NPCs NPDT
#**** deleted body parts from clothes (redefining the set of body parts for a CLOT) (grouped subrecs)
#**** handle patch plugins that are *supposed* to only override the patchee (auto-detect?)
sub multipatch_merge_objects {
    return; #NOTYET
    my @merged_objects = ();
    my $cachedata = load_mergeable_objects();
    my $mo = {};		# merge objects data
    foreach my $plugin ($T3->load_order()) {
	my $lc_plugin = lc($plugin);
	if (defined($cachedata->{$lc_plugin})) {
	    foreach my $rectype (keys %{$cachedata->{$lc_plugin}}) {
		next unless ($TYPE_INFO{$rectype}->{canmerge}); # redundant with load_mergeable_objects but why not
		foreach my $id (keys %{$cachedata->{$lc_plugin}->{$rectype}}) {
		    my $tr = $cachedata->{$lc_plugin}->{$rectype}->{$id};
		    push(@{$mo->{$rectype}->{$id}}, [$plugin, $tr]);
		}
	    }
	}
    }
    foreach my $rectype (sort keys %{$mo}) {
	foreach my $id (sort keys %{$mo->{$rectype}}) {
	    if (scalar(@{$mo->{$rectype}->{$id}}) == 1) {
		print " [MERGE_OBJECTS] skipping $rectype $id - defined only once in: [$mo->{$rectype}->{$id}->[0]->[0]]\n"
		    if (VERBOSE);
		next;
	    }
	    if (scalar(@{$mo->{$rectype}->{$id}}) == 2) {
		print " [MERGE_OBJECTS] skipping $rectype $id - defined only twice, using: [$mo->{$rectype}->{$id}->[1]->[0]]\n"
		    if (VERBOSE);
		next;
	    }
	    my $first_tr = $mo->{$rectype}->{$id}->[0]->[1];
	    my $last_tr = $mo->{$rectype}->{$id}->[-1]->[1];
	    my $new_tr = $first_tr->copy;
	    $new_tr->hdrflags($last_tr->hdrflags);
	    foreach (@{$mo->{$rectype}->{$id}}) {
		my($plugin, $tr) = @{$_};
		my @group;    # a list of subrec groups that need to be merged
		my $currentgroup; # current group type
		foreach my $tsr ($tr->subrecs) {
		    my $subtype = $tsr->subtype;
		    if ($currentgroup and
			(not defined $TYPE_INFO{$rectype}->{group}->{$subtype}->{member}->{$currentgroup})) {
			# TBD also check for a new group start
			# if current subtype is not a member of the current
			# group we have finished collecting a group
			if ($TYPE_INFO{$rectype}->{mergegroup}->{$currentgroup}) {
			    # merge the group/list
			} else {
			    # replace the group/list
			}
			$currentgroup = undef;
		    }
		    if ($TYPE_INFO{$rectype}->{mergefields}->{$subtype}) {
			my @fieldnames = $tsr->fieldnames;
			if (scalar(@fieldnames) == 1) {
			    # merge this subrecord as it only contains one field
			    # and if it differs from the original definition
			    my $fieldname = $fieldnames[0];
			    my $val = $tr->get($subtype, $fieldname);
			    # TBD: initialize a new subtype tsr if doesn't exist in new_tr?
			    if ($first_tr->get($subtype, $fieldname) ne $val) {
				$new_tr->set({ t=>$subtype, f=>$fieldname }, $val);
			    }
			} else {
			}
		    } elsif ($TYPE_INFO{$rectype}->{group}->{$subtype}) {
			push(@group, $tsr);
			$currentgroup = $subtype
			    if ($TYPE_INFO{$rectype}->{group}->{$subtype}->{start});
		    } else {
			# by default merge whole subrec, last guy wins
		    }
		}
		if ($currentgroup) {
		    if ($TYPE_INFO{$rectype}->{mergegroup}->{$currentgroup}) {
			# merge the group/list
		    } else {
			# replace the group/list
		    }
		}
	    }
	}
    }
    return(\@merged_objects);
}				# multipatch_merge_objects

sub multipatch_merge_leveled_lists_new {
    my @merged_lists;
    my $cachedata = load_leveled_lists();
    my $ll = {};
    foreach my $plugin ($T3->load_order()) {
	my $lc_plugin = lc($plugin);
	if (defined($cachedata->{$lc_plugin})) {
	    foreach my $rectype (qw(LEVC LEVI)) {
		foreach my $id (keys %{$cachedata->{$lc_plugin}->{$rectype}}) {
		    my $tr = $cachedata->{$lc_plugin}->{$rectype}->{$id};
		    push(@{$ll->{$rectype}->{$id}}, [$plugin, $tr]);
		}
	    }
	}
    }
    foreach my $rectype (qw(LEVC LEVI)) {
	my %user_deletions;
	if ($rectype eq 'LEVC') {
	    $user_deletions{$_}++ foreach (@opt_multipatch_delete_creature);
	} elsif ($rectype eq 'LEVI') {
	    $user_deletions{$_}++ foreach (@opt_multipatch_delete_item);
	}
	foreach my $id (sort keys %{$ll->{$rectype}}) {
	    dbg(qq{examining $rectype: "$id"}) if (DBG);
	    if (scalar(@{$ll->{$rectype}->{$id}}) == 1) {
		print " [LEVLIST] skipping $rectype $id - defined only once in: [$ll->{$rectype}->{$id}->[0]->[0]]\n"
		    if (VERBOSE);
		next;
	    }
	    if (scalar(@{$ll->{$rectype}->{$id}}) == 2) {
		print " [LEVLIST] skipping $rectype $id - defined only twice, using: [$ll->{$rectype}->{$id}->[1]->[0]]\n"
		    if (VERBOSE);
		next;
	    }
	    my($first_plugin, $first_tr) = shift(@{$ll->{$rectype}->{$id}});
	    my $merged_tr = $first_tr->merge($first_plugin, $ll->{$rectype}->{$id});

	    my $last_tr = $ll->{$rectype}->{$id}->[-1]->[1];
	    # strategy: last guy wins for List Flags
	    my $last_list_flags = $last_tr->get('DATA', 'list_flags');
	    # strategy: last guy wins for "Chance_None"
	    my $last_chance = $last_tr->get('NNAM', 'chance_none');
	    my %levlist;
	    my $firstdef;
	    # For each defined leveled list (LEVC/LEVI) from first to last in load order
	    foreach (@{$ll->{$rectype}->{$id}}) {
		my($plugin, $tr) = @{$_};
		my $element_id;
		my $currdef;
		# For each item in list per plugin
		foreach my $tsr ($tr->subrecs()) {
		    my $subtype = $tsr->subtype;
		    if ($subtype eq 'CNAM') {
			$element_id = $tsr->{creature_id};
		    } elsif ($subtype eq 'INAM') {
			$element_id = $tsr->{item_id};
		    } elsif ($subtype eq 'INTV') {
			my $level = $tsr->{level};
			# increment count of times this id appears at this level
			$currdef->{$element_id}->{$level}++;
		    }
		}
		if ($firstdef) { # merge
		    # Additions/Changes to list
		    foreach my $element_id (keys %{$currdef}) {
			foreach my $level (keys %{$currdef->{$element_id}}) {
			    if ((not defined $firstdef->{$element_id}) or
				(not defined $firstdef->{$element_id}->{$level}) or
				($currdef->{$element_id}->{$level} != $firstdef->{$element_id}->{$level})) {
				$levlist{$element_id}->{$level} = $currdef->{$element_id}->{$level};
			    }
			}
		    }
		    # Deletions from original definition
		    foreach my $element_id (keys %{$firstdef}) {
			if (not defined $currdef->{$element_id}) {
			    delete $levlist{$element_id};
			} else {
			    foreach my $level (keys %{$firstdef->{$element_id}}) {
				if (not defined $currdef->{$element_id}->{$level}) {
				    delete $levlist{$element_id}->{$level};
				}
			    }
			}
		    }
		} else {	# define initial leveled list
		    $firstdef = $currdef;
		    foreach my $element_id (keys %{$currdef}) {
			foreach my $level (keys %{$currdef->{$element_id}}) {
			    $levlist{$element_id}->{$level} = $currdef->{$element_id}->{$level};
			}
		    }
		}
	    }
	    print " [LEVLIST] Defining $rectype $id ->\n" if (VERBOSE);
	    my @unsorted_list;
	    my %deleted_items;
	    foreach my $element_id (keys %levlist) {
		foreach my $level (keys %{$levlist{$element_id}}) {
		    my $count = $levlist{$element_id}->{$level};
		    for (my $i=0; $i < $count; $i++) {
			if ($user_deletions{$element_id}) { # from switches: --delete-creature|--delete-item
			    $deleted_items{$element_id}++;
			} else {
			    push(@unsorted_list, [$level, $element_id]);
			}
		    }
		}
	    }
	    # sort the leveled list by level, then by crea/item id
	    my @sorted_list;
	    foreach (sort {$a->[0] <=> $b->[0] or $a->[1] cmp $b->[1]} @unsorted_list) {
		my($level, $element_id) = @{$_};
		print "\t[lev=$level cre=$element_id]\n" if (VERBOSE);
		push(@sorted_list, [$element_id, $level]);
	    }
	    my @deleted_list = sort keys %deleted_items;
	    if (VERBOSE and @deleted_list) {
		print "\tDeleted IDs:\n";
		print "\t  $_\n" foreach (@deleted_list);
	    }
	    my $indx = scalar(@sorted_list);
	    my $newrec = [[NAME => { id => $id }],
			  [DATA => { list_flags => $last_list_flags }],
			  [NNAM => { chance_none => $last_chance }],
			  [INDX => { item_count => $indx }]];
	    my $tr;
	    if ($rectype eq 'LEVC') {
		$tr = LEVC->new($newrec);
		foreach (@sorted_list) {
		    my($element_id, $level) = @{$_};
		    $tr->append(LEVC::CNAM->new({ creature_id => $element_id }),
				LEVC::INTV->new({ level => $level }));
		}
	    } else {
		$tr = LEVI->new($newrec);
		foreach (@sorted_list) {
		    my($element_id, $level) = @{$_};
		    $tr->append(LEVI::INAM->new({ item_id => $element_id }),
				LEVI::INTV->new({ level => $level }));
		}
	    }
	    push(@merged_lists, $merged_tr);
	}
    }
    return(\@merged_lists);
}				# multipatch_merge_leveled_lists_new

sub multipatch_merge_leveled_lists_old {
    my @merged_lists;
    my $cachedata = load_leveled_lists();
    my $ll = {};
    foreach my $plugin ($T3->load_order()) {
	my $lc_plugin = lc($plugin);
	if (defined($cachedata->{$lc_plugin})) {
	    foreach my $rectype (qw(LEVC LEVI)) {
		foreach my $id (keys %{$cachedata->{$lc_plugin}->{$rectype}}) {
		    my $tr = $cachedata->{$lc_plugin}->{$rectype}->{$id};
		    push(@{$ll->{$rectype}->{$id}}, [$plugin, $tr]);
		}
	    }
	}
    }
    foreach my $rectype (qw(LEVC LEVI)) {
	my %user_deletions;
	if ($rectype eq 'LEVC') {
	    $user_deletions{$_}++ foreach (@opt_multipatch_delete_creature);
	} elsif ($rectype eq 'LEVI') {
	    $user_deletions{$_}++ foreach (@opt_multipatch_delete_item);
	}
	foreach my $id (sort keys %{$ll->{$rectype}}) {
	    dbg(qq{examining $rectype: "$id"}) if (DBG);
	    if (scalar(@{$ll->{$rectype}->{$id}}) == 1) {
		print " [LEVLIST] skipping $rectype $id - defined only once in: [$ll->{$rectype}->{$id}->[0]->[0]]\n"
		    if (VERBOSE);
		next;
	    }
	    if (scalar(@{$ll->{$rectype}->{$id}}) == 2) {
		print " [LEVLIST] skipping $rectype $id - defined only twice, using: [$ll->{$rectype}->{$id}->[1]->[0]]\n"
		    if (VERBOSE);
		next;
	    }
	    my $last_tr = $ll->{$rectype}->{$id}->[-1]->[1];
	    # strategy: last guy wins for List Flags
	    my $last_list_flags = $last_tr->get('DATA', 'list_flags');
	    # strategy: last guy wins for "Chance_None"
	    my $last_chance = $last_tr->get('NNAM', 'chance_none');
	    my %levlist;
	    my $firstdef;
	    # For each defined leveled list (LEVC/LEVI) from first to last in load order
	    foreach (@{$ll->{$rectype}->{$id}}) {
		my($plugin, $tr) = @{$_};
		my $element_id;
		my $currdef;
		# For each item in list per plugin
		foreach my $tsr ($tr->subrecs()) {
		    my $subtype = $tsr->subtype;
		    if ($subtype eq 'CNAM') {
			$element_id = $tsr->{creature_id};
		    } elsif ($subtype eq 'INAM') {
			$element_id = $tsr->{item_id};
		    } elsif ($subtype eq 'INTV') {
			my $level = $tsr->{level};
			# increment count of times this id appears at this level
			$currdef->{$element_id}->{$level}++;
		    }
		}
		if ($firstdef) { # merge
		    # Additions/Changes to list
		    foreach my $element_id (keys %{$currdef}) {
			foreach my $level (keys %{$currdef->{$element_id}}) {
			    if ((not defined $firstdef->{$element_id}) or
				(not defined $firstdef->{$element_id}->{$level}) or
				($currdef->{$element_id}->{$level} != $firstdef->{$element_id}->{$level})) {
				$levlist{$element_id}->{$level} = $currdef->{$element_id}->{$level};
			    }
			}
		    }
		    # Deletions from original definition
		    foreach my $element_id (keys %{$firstdef}) {
			if (not defined $currdef->{$element_id}) {
			    delete $levlist{$element_id};
			} else {
			    foreach my $level (keys %{$firstdef->{$element_id}}) {
				if (not defined $currdef->{$element_id}->{$level}) {
				    delete $levlist{$element_id}->{$level};
				}
			    }
			}
		    }
		} else {	# define initial leveled list
		    $firstdef = $currdef;
		    foreach my $element_id (keys %{$currdef}) {
			foreach my $level (keys %{$currdef->{$element_id}}) {
			    $levlist{$element_id}->{$level} = $currdef->{$element_id}->{$level};
			}
		    }
		}
	    }
	    print " [LEVLIST] Defining $rectype $id ->\n" if (VERBOSE);
	    my @unsorted_list;
	    my %deleted_items;
	    foreach my $element_id (keys %levlist) {
		foreach my $level (keys %{$levlist{$element_id}}) {
		    my $count = $levlist{$element_id}->{$level};
		    for (my $i=0; $i < $count; $i++) {
			if ($user_deletions{$element_id}) { # from switches: --delete-creature|--delete-item
			    $deleted_items{$element_id}++;
			} else {
			    push(@unsorted_list, [$level, $element_id]);
			}
		    }
		}
	    }
	    # sort the leveled list by level, then by crea/item id
	    my @sorted_list;
	    foreach (sort {$a->[0] <=> $b->[0] or $a->[1] cmp $b->[1]} @unsorted_list) {
		my($level, $element_id) = @{$_};
		print "\t[lev=$level cre=$element_id]\n" if (VERBOSE);
		push(@sorted_list, [$element_id, $level]);
	    }
	    my @deleted_list = sort keys %deleted_items;
	    if (VERBOSE and @deleted_list) {
		print "\tDeleted IDs:\n";
		print "\t  $_\n" foreach (@deleted_list);
	    }
	    my $indx = scalar(@sorted_list);
	    my $newrec = [[NAME => { id => $id }],
			  [DATA => { list_flags => $last_list_flags }],
			  [NNAM => { chance_none => $last_chance }],
			  [INDX => { item_count => $indx }]];
	    my $tr;
	    if ($rectype eq 'LEVC') {
		$tr = LEVC->new($newrec);
		foreach (@sorted_list) {
		    my($element_id, $level) = @{$_};
		    $tr->append(LEVC::CNAM->new({ creature_id => $element_id }),
				LEVC::INTV->new({ level => $level }));
		}
	    } else {
		$tr = LEVI->new($newrec);
		foreach (@sorted_list) {
		    my($element_id, $level) = @{$_};
		    $tr->append(LEVI::INAM->new({ item_id => $element_id }),
				LEVI::INTV->new({ level => $level }));
		}
	    }
	    push(@merged_lists, $tr);
	}
    }
    return(\@merged_lists);
}				# multipatch_merge_leveled_lists_old

sub cmd_multipatch {
    dbg("cmd_multipatch") if (DBG);
    print "\nMultipatch: Scanning Active Plugins...\n";
    my $patch_file = "multipatch.esp";
    my $patch_path = "$DATADIR/$patch_file";
    my %fogcell;		# fogbugged cells
    my %rencell;		# cells with reverted renamings
    my %sumcrea;		# critters needing persistent flag
    my $merged_objects = multipatch_merge_objects() if ($opt_multipatch_merge_objects);
    my $merged_lists = multipatch_merge_leveled_lists_old() if ($opt_multipatch_merge_lists);
    foreach my $plugin ($T3->load_order()) {
	$CURRENT_PLUGIN = $plugin;
	if (my $reason = $NOPATCH_PLUGIN{lc($plugin)}) {
	    prn("tes3cmd multipatch skipping $plugin: ${reason}.");
	    next;
	}
	print "Scanning plugin: $plugin\n";
	my $inp = open_for_input($T3->datapath($plugin));
	my $expected = "TES3";
	eval {
	    while (my $tr = TES3::Record->new_from_input($inp, $expected, $plugin)) {
		$expected = undef;
		my $rectype = $tr->rectype;
		next if ($tr->hdrflags & $HDR_FLAGS{ignored});
		if ($opt_multipatch_fogbug or $opt_multipatch_cellnames) {
		    if ($rectype eq 'CELL') {
			if ($tr->decode()->is_interior()) {
			    # only check interior cells for fogbug
			    if ($opt_multipatch_fogbug) {
				unless ($tr->get('DATA', 'flags') & 128) { # behave like exterior
				    multipatch_check_fogbug($plugin, $tr, \%fogcell);
				}
			    }
			} else {
			    # only check exterior cells for rename reversion problem
			    if ($opt_multipatch_cellnames) {
				multipatch_check_cell_rename_reversions($plugin, $tr, \%rencell);
			    }
			}
		    }
		}
		if ($opt_multipatch_summons_persist) {
		    if ($rectype eq 'CREA') {
			my $id = $tr->decode()->id;
			if ($SUMMONED_CREATURES{$id}) {
			    if ($tr->hdrflags & $HDR_FLAGS{persistent}) {
				# plugin has preserved persistent flag
				print "  [SUMMCREA] $plugin PRESERVES persistence for: $id\n" if (VERBOSE);
				delete $sumcrea{$id};
			    } else {
				# plugin has voided persistent flag, so reset it
				print "  [SUMMCREA] $plugin REVERTS persistence for: $id\n" if (VERBOSE);
				$tr->{_hdrflags_} |= $HDR_FLAGS{persistent};
				$sumcrea{$id} = $tr;
			    }
			}
		    }
		}
	    }
	};
	print $@ if ($@);
	close_input($inp);
    }
    my $nfogbugs = scalar keys %fogcell;
    my $nrenrevs = scalar(grep {defined} map {$_->{OUTPUTFLAG}} values(%rencell));
    my $nsumcrea = scalar keys %sumcrea;
    if ($nfogbugs or $nrenrevs or $nsumcrea or $merged_lists or $merged_objects) {
	print "\n".("="x75)."\n";
	print "A multipatch has been conjured for you to address the following issues:\n";
	my $out = open_for_output($patch_path);
	print $out make_header();
	if ($nrenrevs) {
	    print "\nPreserving the following $nrenrevs CELL renamings:\n";
	    foreach my $coord (keys %rencell) {
		if ($rencell{$coord}->{OUTPUTFLAG}) {
		    if (my $tr = $rencell{$coord}->{REC}) {
			print qq{  CELL: ($coord) -> NAME: "$rencell{$coord}->{NAME}"\n};
			$tr->write_rec($out);
		    }
		}
	    }
	}
	if ($nfogbugs) {
	    print qq{\nPatching $nfogbugs fogbugged cells:\n};
	    foreach my $name (sort keys %fogcell) {
		my($tr, $plugin) = @{$fogcell{$name}};
		print "  CELL: $name\t\t[$plugin]\n";
		# put in a non-zero fog density
		my $name_tsr = $tr->get('NAME');
		my $data_tsr = $tr->get('DATA');
		my $ambi_tsr = $tr->get('AMBI');
		$ambi_tsr->{fog_density} = 0.01;
		$data_tsr->{fog_density} = 0.01;
		my $newcell = CELL->new([$name_tsr, $data_tsr->encode, $ambi_tsr->encode]);
		$newcell->write_rec($out);
	    }
	}
	if ($nsumcrea) {
	    print "\nResetting the following $nsumcrea Summoned Creatures persistence:\n";
	    foreach my $id (sort keys %sumcrea) {
		print "  CREA: $id\n";
		my $tr = $sumcrea{$id};
		$tr->write_rec($out);
	    }
	}
	if ($merged_objects) {
	    my %count;
	    my $total = 0;
	    foreach my $tr (@$merged_lists) {
		$count{$tr->rectype()}++;
		$total++;
		$tr->write_rec($out);
	    }
	    print "\nMerged Objects ($total)\n";
	}
	if ($merged_lists) {
	    my %count;
	    $count{LEVC} = $count{LEVI} = 0;
	    foreach my $tr (@$merged_lists) {
		$count{$tr->rectype()}++;
		$tr->write_rec($out);
	    }
	    print "\nMerged Leveled Lists ($count{LEVC} LEVC, $count{LEVI} LEVI)\n";
	}
	close($out);
	my @options;
	push(@options, 'cellnames') if $opt_multipatch_cellnames;
	push(@options, 'fogbug') if $opt_multipatch_fogbug;
	push(@options, 'merge_lists') if $opt_multipatch_merge_lists;
	push(@options, 'summons_persist') if $opt_multipatch_summons_persist;
	$opt_header_update_record_count = 1;
	$opt_header_author = "tes3cmd multipatch";
	$opt_header_description = "options: ".join(",", @options);
	update_header($patch_path, [qw(QUIET NOBACKUP)]);
	undef $opt_header_description;
	unless ($opt_multipatch_no_activate) {
	    print "\n";
	    # we need to reload our datafiles_map, because patch_file was just created
	    $T3->datafiles_map(RELOAD);
	    $opt_active_on = 1;
	    cmd_active($patch_file);
	}
    } else {
	print qq{\nNo patching necessary. "multipatch.esp" not generated.\n};
    }
} # cmd_multipatch

sub cmd_overdial {
    my(@plugins) = @_;
    dbg("cmd_overdial(@plugins)") if (DBG);
    my %dialog;
    foreach my $plugin (@plugins) {
	read_dialogs($plugin, \%dialog);
    }
    my @testplugins = ($opt_overdial_single) ? ($plugins[0]) : sort keys %dialog;
    foreach my $plugin1 (sort keys %dialog) {
	foreach my $plugin2 (@testplugins) {
	    if ($plugin1 ne $plugin2) {
		foreach my $id1 (keys %{$dialog{$plugin1}}) {
		    foreach my $id2 (keys %{$dialog{$plugin2}}) {
			if (length($id1) > length($id2) and $id1 =~ /\b$id2\b/i) {
			    printf qq{%-40s "$id1"\n%-40s "$id2"\n\n}, "$plugin1:", "$plugin2:";
			}
		    }
		}
	    }
	}
    }
}

# find objects in common between 2 plugins
sub cmd_common {
    my($plugin1, $plugin2) = @_;
    dbg("cmd_common($plugin1, $plugin2)") if (DBG);
    # swap plugins if plugin1 is larger than plugin2
    ($plugin1, $plugin2) = ($plugin2, $plugin1)
	if (-s $plugin1 > -s $plugin2);
    # read objects from smaller plugin
    my $objects1 = read_records($plugin1);
    # compare to objects second plugin
    my $compare_fun = sub {
	my($rectype, $id) = @_;
	if ($objects1->{$rectype}->{$id} and ($rectype ne 'TES3')) {
	    print "  $rectype: $id\n";
	}
    };
    read_records($plugin2, $compare_fun);
}

sub cmd_diff {
    my($plugin1, $plugin2) = @_;
    dbg("cmd_diff($plugin1, $plugin2)") if (DBG);
    my %ignore_rectype;
    my %ignore_subtypes;
    foreach my $typ (@opt_diff_ignore_types) {
	my($rectype, $subtype) = split(/\./, $typ);
	$ignore_rectype{$rectype}++;
	$ignore_subtypes{$rectype}->{$subtype}++ if (defined $subtype);
    }
    foreach my $rectype (keys %ignore_subtypes) {
	if (my @subtypes = keys %{$ignore_subtypes{$rectype}}) {
	    $ignore_subtypes{$rectype} = '^(\s*\*?(?:' . join('|', grep {/\w/} @subtypes) . '):)';
	} else {
	    delete $ignore_subtypes{$rectype};
	}
    }
    my $obj1 = read_objects($plugin1);
    my $obj2 = read_objects($plugin2);
    if (VERBOSE) {
	print "Plugin1: $plugin1\n";
	print "Plugin2: $plugin2\n";
    }
    my @p1_not_p2;	     # records in plugin1 that do not exist in plugin2
    my @p2_not_p1;	     # records in plugin2 that do not exist in plugin1
    my @p1_equal_p2;	     # records in plugin1 that are equal in plugin2
    my @p1_diff_p2;	     # records in plugin1 that are different in plugin2
    my @diffs;		     # detailed diffs
    my @typediffs;	     # records with same id that differ in rectype
    my(@diff1, @diff2);
    foreach my $id (keys %{$obj1}) {
	if ($opt_diff_types) {
	    my @rectypes1 = grep { !/CELL/ } (keys %{$obj1->{$id}}); # cells not in same namespace (I think)
	    my @rectypes2 = grep { !/CELL/ } (keys %{$obj2->{$id}}); # cells not in same namespace (I think)
	    if (@rectypes1 and @rectypes2) {
		my($rt1, $rt2);
		if (scalar(@rectypes1) > 1) {
		    dbg(qq{$plugin1: Object "$id" has multiple types: @rectypes1}) if (DBG);
		} else {
		    $rt1 = shift(@rectypes1);
		}
		if (scalar(@rectypes2) > 1) {
		    dbg(qq{$plugin2: Object "$id" has multiple types: @rectypes2}) if (DBG);
		} else {
		    $rt2 = shift(@rectypes2);
		}
		if (defined $rt1 and defined $rt2 and $rt2 ne $rt2) {
		    push(@typediffs, [$id, $rt1, $rt2]);
		}
	    }
	}
	foreach my $rectype (keys %{$obj1->{$id}}) {
	    if (defined $ignore_rectype{$rectype}) {
		dbg("Ignoring rectype: $rectype".Dumper(\%ignore_rectype)) if (DBG);
		next;
	    }
	    my $ignore_subtypes_re = $ignore_subtypes{$rectype};
	    if (defined(my $rec2 = $obj2->{$id}->{$rectype})) {
		my $tr1 = $obj1->{$id}->{$rectype};
		my $print_rec1 = $tr1->tostr;
		$print_rec1 =~ s/$ignore_subtypes_re}.*/$1 [IGNORED]/mg if (defined $ignore_subtypes_re);
		$print_rec1 =~ s/^(\s*?\*?FRMR:.*?MastIdx:)\d+/$1 [IGNORED]/mi if ($rectype eq 'CELL');
		my $tr2 = $obj2->{$id}->{$rectype};
		my $print_rec2 = $tr2->tostr;
		$print_rec2 =~ s/$ignore_subtypes_re}.*/$1 [IGNORED]/mg if (defined $ignore_subtypes_re);
		$print_rec2 =~ s/^(\s*?\*?FRMR:.*?MastIdx:)\d+/$1 [IGNORED]/mi if ($rectype eq 'CELL');
		my $cmprec1 = lc($print_rec1);
		my $cmprec2 = lc($print_rec2);
		if ($opt_diff_sortsubrecs) {
		    $cmprec1 = join("\n", sort split(/\n/, $print_rec1));
		    $cmprec2 = join("\n", sort split(/\n/, $print_rec2));
		}
		if ($cmprec1 eq $cmprec2) {
		    push(@p1_equal_p2, "$rectype: $id") if ($opt_diff_equal);
		} elsif ($opt_diff_not_equal) {
		    push(@p1_diff_p2, "$rectype: $id");
		    push(@diff1, "\n$rectype: $id\n$print_rec1\n");
		    push(@diff2, "\n$rectype: $id\n$print_rec2\n");
		}
	    } else {
		push(@p1_not_p2, "$rectype: $id") if ($opt_diff_1_not_2);
	    }
	}
    }
    foreach my $id (keys %{$obj2}) {
	foreach my $rectype (keys %{$obj2->{$id}}) {
	    unless (defined $obj1->{$id}->{$rectype}) {
		push(@p2_not_p1, "$rectype: $id") if ($opt_diff_2_not_1);
	    }
	}
    }
    # now print the diff report
    if ($opt_diff_1_not_2 and my $n = @p1_not_p2) {
	print qq{\nRecords in "$plugin1" not in "$plugin2" ($n):\n};
	foreach (sort @p1_not_p2) { print "$_\n"; }
    }
    if ($opt_diff_2_not_1 and my $n = @p2_not_p1) {
	print qq{\nRecords in "$plugin2" not in "$plugin1" ($n):\n};
	foreach (sort @p2_not_p1) { print "$_\n"; }
    }
    if ($opt_diff_equal and my $n  = @p1_equal_p2) {
	print qq{\nRecords that are equal in "$plugin1" and "$plugin2" ($n):\n};
	foreach (sort @p1_equal_p2) { print "$_\n"; }
    }
    if ($opt_diff_not_equal) {
	my $diff1_file = $plugin1 . "-diff.txt";
	my $diff2_file = $plugin2 . "-diff.txt";
	if (my $n = @p1_diff_p2) {
	    print qq{\nRecords that are different between "$plugin1" and "$plugin2" ($n):\n(Compare $diff1_file to $diff2_file)\n};
	    foreach (sort @p1_diff_p2) {
		print "$_\n";
	    }
	}
	@diff1 = sort @diff1;
	@diff2 = sort @diff2;
	print "\n";
	diff_output($diff1_file, \@diff1);
	diff_output($diff2_file, \@diff2);
    }
} # cmd_diff

sub cmd_delete {
    my($plugin) = @_;
    dbg("cmd_delete($plugin)") if (DBG);
    my $delete_subrecords = ($opt_sub_match or $opt_sub_no_match);
    my $delete_instances = ($opt_instance_match or $opt_instance_no_match);
    my $fun = sub {
	my($rectype0, $tr0) = @_;
	my($rec_match, $rectype, $tr, $print_rec) =
	    rec_match($plugin, $rectype0, $tr0); # calls tr->decode()
	# we pass through all records that did not match the standard record selection switches of rec_match
	return('') unless ($rec_match);
	my $id = $tr->id;
	if ($delete_subrecords) {
	    # we are processing subrecords
	    my @newtr;
	    foreach my $tsr ($tr->subrecs()) {
		my $subrec_str = $tsr->tostr;
		my @deletion_msgs;
		#((not $WANTED_TYPES) or ($WANTED_TYPES->{$tsr->subtype})) and  ## maybe something like this
		if (((not $opt_sub_match) or ($subrec_str =~ /$opt_sub_match/i)) and
		    ((not $opt_sub_no_match) or ($subrec_str !~ /$opt_sub_no_match/i))) {
		    print "[$rectype $id] DELETED SUBRECORD: $subrec_str\n";
		} else {
		    push(@newtr, $tsr);
		}
	    }
	    if (scalar(@newtr) == 0) {
		print "DELETED: $rectype $id (all subrecords were deleted)\n";
		return(undef);
	    } else {
		return(${rectype}->new([@newtr]));
	    }
	} elsif ($delete_instances) {
	    if ($rectype eq 'CELL') {
		my @groups = @{$tr->split_groups()};
		my @newcell = @{shift(@groups)}; # take header
		my $deletions = 0;
		my $nam0_tsr;
		my $n = 0;
		foreach my $gref (@groups) {
		    my @this_group = @$gref; # all the subrecs in a FRMR (object instance) group
		    if ($this_group[0]->subtype eq 'NAM0') {
			push(@newcell, $nam0_tsr = $this_group[0]);
		    } else {
			my($gstring, $name, $objidx);
			foreach my $tsr (@this_group) {
			    $gstring .= $tsr->tostr;
			    $name = $tsr->{name}
				if (not(defined($name)) and $tsr->subtype eq 'NAME');
			    $objidx = $tsr->{objidx}
				if (not(defined($objidx)) and $tsr->subtype eq 'FRMR');
			}
			if (((not $opt_instance_match) or ($gstring =~ /$opt_instance_match/i)) and
			    ((not $opt_instance_no_match) or ($gstring !~ /$opt_instance_no_match/i))) {
			    print "[CELL: $id] DELETED OBJECT INSTANCE: $name ObjIdx:$objidx\n";
			    $deletions++;
			} else {
			    push(@newcell, @this_group);
			    $n++ if (defined $nam0_tsr); # count objects after NAM0 marker
			}
		    }
		}
		if ($deletions) {
		    $nam0_tsr->{reference_count} = $n;	# update NAM0
		    dbg("newcell:".Dumper(\@newcell)) if (DBG);
		    return(CELL->new([@newcell]));
		} else {
		    return(''); # passthrough
		}
	    } else {
		return(''); # passthrough
	    }
	} else {
	    # we are deleting whole records
	    if (VERBOSE) {
		$print_rec ||= $tr->tostr;
		print "\nDELETED RECORD:\n$print_rec\n";
	    } else {
		print "DELETED: $rectype $id\n";
	    }
	    return(undef);
	}
    };
    process_plugin_for_update($plugin, $fun) or return(0);
} # cmd_delete

sub cmd_modify {
    my($plugin) = @_;
    dbg("cmd_modify($plugin)") if (DBG);
    my $modify_subrecords = ($opt_sub_match or $opt_sub_no_match);
    if (my $replacer = ($opt_modify_replace || $opt_modify_replacefirst)) {
	# make the replacer case-insensitive
	$replacer = qq{(?i)$replacer};
	if (not $opt_modify_replacefirst) {
	    # make the replacer global
	    $replacer .= 'g';
	}
	# check that the replacer expression is valid
	eval qq{(my \$foo = "HALCALI") =~ s$replacer;};
	if ($@) {
	    abort("Invalid replacer expression: $replacer");
	}
    }
    my $fun = sub {
	my($rec_match, $rectype, $tr, $print_rec) = rec_match($plugin, @_); # calls tr->decode()
	# we pass through all records that did not match the standard record selection switches of rec_match
	return('') unless ($rec_match);
	my $id = $tr->id;
	my $oldrec = $tr->recbuf;
	my $modified = 0;
	if ($opt_modify_replace) {
	    foreach my $tsr ($tr->subrecs()) {
		if ($modify_subrecords) {
		    my $subrec_str = $tsr->tostr;
		    next unless (((not $opt_sub_match) or ($subrec_str =~ /$opt_sub_match/i)) and
				 ((not $opt_sub_no_match) or ($subrec_str !~ /$opt_sub_no_match/i)));
		}
		eval { my @keys = keys %$tsr } ; abort("BAD TR: ".Dumper($tr)) if ($@);
		foreach my $key (keys %$tsr) {
		    next if ($key =~ /^_/); # skip keys that are not fieldnames
		    $modified = 1 if (eval qq{\$tsr->{$key} =~ s$opt_modify_replace;});
		}
	    }
	} elsif ($opt_modify_run) {
	    if ($modify_subrecords) {
		# run modifying code only on matching subrecs
		foreach my $tsr ($tr->subrecs()) {
		    if ($modify_subrecords) {
			my $subrec_str = $tsr->tostr;
			next unless (((not $opt_sub_match) or ($subrec_str =~ /$opt_sub_match/i)) and
				     ((not $opt_sub_no_match) or ($subrec_str !~ /$opt_sub_no_match/i)));
		    }
		    $R = $tr;
		    eval($opt_modify_run);
		    $modified = 1 if ($R->{_modified_});
		    if ($@) {
			msg(qq{Error running "$opt_modify_run" on: $rectype ($@)});
			$modified = 0;
		    }
		}
	    } else {
		# run modifying code on entire subrec
		$R = $tr;
		eval($opt_modify_run);
		$modified = 1 if ($R->{_modified_});
		if ($@) {
		    msg(qq{Error running "$opt_modify_run" on: $rectype ($@)});
		    $modified = 0;
		}
	    }
	}
	if ($modified) {
	    if ($tr->encode()->recbuf ne $oldrec) {
		prn("MODIFIED RECORD:\n" . $tr->tostr);
		return($tr);
	    }
	}
	return('');		# passthrough unchanged
    };
    process_plugin_for_update($plugin, $fun) or return(0);
} # cmd_modify

sub cmd_run {
    my($plugin, $userfun) = @_;
    dbg("cmd_run($plugin)") if (DBG);
    $userfun = \&main unless($userfun); # function that processes each record
    my $subrecords = ($opt_sub_match or $opt_sub_no_match);
    my $fun = sub {
	my($rec_match, $rectype, $tr, $print_rec) = rec_match($plugin, @_); # calls tr->decode()
	# we pass through all records that did not match the standard record selection switches of rec_match
	return unless ($rec_match);
	my $id = $tr->id;
	if ($subrecords) {
	    # run code only on matching subrecs
	    foreach my $tsr ($tr->subrecs()) {
		if ($subrecords) {
		    my $subrec_str = $tsr->tostr;
		    next unless (((not $opt_sub_match) or ($subrec_str =~ /$opt_sub_match/i)) and
				 ((not $opt_sub_no_match) or ($subrec_str !~ /$opt_sub_no_match/i)));
		}
		$userfun->($tr);	# user supplied the "main" subroutine
		if ($@) {
		    msg(qq{Error running "main()" on: $rectype ($@)});
		}
	    }
	} else {
	    # run modifying code on entire subrec
	    $userfun->($tr);	# user supplied the "main" subroutine
	    if ($@) {
		msg(qq{Error running "main()" on: $rectype ($@)});
	    }
	}
	return;
    };
    process_plugin_for_input($plugin, $fun) or return(0);
} # cmd_run

sub cmd_header {
    my($plugin) = @_;
    dbg("cmd_header($plugin)") if (DBG);
    update_header($plugin);
}

sub esp_esm_convert {
    my($input) = @_;
    my $output;
    my $byte_expected;
    my $byte_new;
    if ($input =~ /\.esp$/i) {
	# convert plugin to master
	$byte_expected = "\000";
	$byte_new = "\001";
	($output = $input) =~ s/\.esp$/.esm/i;
    } else {
	# convert master to plugin
	$byte_expected = "\001";
	$byte_new = "\000";
	($output = $input) =~ s/\.esm$/.esp/i;
    }
    abort(qq{Error, $output already exists! (Use --overwrite to overwrite)})
	if (-f $output and not $opt_overwrite);
    copy($input, $output) or abort("Error, copy failed $input -> $output ($!)");
    eval {
	open(OUT, "+<$output") or abort(qq{Error opening "$output" for read/write ($!)});
	binmode(OUT) or abort("Error setting binmode on $output ($!)");
	my $magic;
	(read(OUT, $magic, 4) == 4) or abort("$output: Error reading magic ($!)");
	if ($magic eq "TES3") {
	    seek(OUT, 28, SEEK_SET) or abort("seek");
	    my $byte;
	    (read(OUT, $byte, 1) == 1) or abort("$output: Error reading master byte ($!)");
	    my $val = unpack("C", $byte);
	    #msg("masterbyte = $val");
	    ($byte eq $byte_expected) or
		abort(qq{Error, expected master byte value of @{[unpack("C",$byte_expected)]}, got $val instead});
	    seek(OUT, 28, SEEK_SET) or abort("seek");
	    print OUT $byte_new or abort("$output: Error writing byte ($!)");
	} elsif ($magic eq "TES4") {
	    abort("This function is not yet implemented for TES4 files");
	} else {
	    abort("$output: Error, this does not appear to be Morrowind plugin");
	}
	close(OUT);
    };
    if ($@) {
	err($@);
	close(OUT);
	unlink($output);
	return;
    }
    my($atime, $mtime) = (stat($input))[8,9];
    utime($atime, $mtime, $output);
    prn(qq{"$input" copied to "$output"});
} # esp_esm_convert

# convert a master to a plugin
sub cmd_esp {
    my($master) = @_;
    dbg("cmd_esp($master)") if (DBG);
    abort("Error, input must be a master (.esm)")
	unless ($master =~ /\.esm$/i);
    esp_esm_convert($master);
}

# convert a plugin to a master
sub cmd_esm {
    my($plugin) = @_;
    dbg("cmd_esp($plugin)") if (DBG);
    abort("Error, input must be a plugin (.esp)")
	unless ($plugin =~ /\.esp$/i);
    esp_esm_convert($plugin);
}

sub cmd_clean {
    my($plugin) = @_;
    dbg("cmd_clean($plugin)") if (DBG);
    if ($plugin =~ /\.ess$/) {
	prn("tes3cmd clean skipping $plugin: don't know how to clean savegames ... yet.");
	return;
    }
    if ($plugin =~ /~\d+\.es[mps]$/i) {
	prn("tes3cmd clean skipping $plugin: because it's a backup.");
	return;
    }
    if (my $reason = $CLEAN_PLUGIN{lc($plugin)}) {
	prn("tes3cmd clean skipping $plugin: ${reason}.");
	return;
    }
    print qq{\nCLEANING: "$plugin" ...\n};
    my %duptype = map {$_,1} @CLEAN_DUP_TYPES;
    my %my_master;
    my %stats;
    my %persistent;
    my $fun = sub {
	my($rectype, $plug_tr) = @_;
	my $record_modified = 0;
	if ($opt_clean_instances) {
	    if ($plug_tr->hdrflags & $HDR_FLAGS{persistent}) {
		my $id = $plug_tr->decode()->id;
		$persistent{$id}++;
	    }
	}
	if ($rectype eq 'GMST') {
	    if ($opt_clean_gmsts) {
		# CLEAN EVIL GMSTS
		my $id = $plug_tr->decode()->id;
		my($type, $field) = @{$GMST_TYPE{substr($id, 0, 1)}};
		dbg("examining GMST  ID=$id  TYPE=$type  FIELD=$field") if (DBG);
		my $val_tsr = $plug_tr->get($type);
		if ($val_tsr) {
		    # we only process GMSTs that have associated value subrecords
		    my $val = $val_tsr->subbuf;
		    unless (defined $val) {
			my $what = "GMST with no value";
			$stats{$what}++;
			print " Cleaned $what: $id\n";
			return;	# return undef to delete
		    }
		    my $hexval = unpack("H*", "$type $val");
		    if (defined($EVIL_BM{$id}) and ($EVIL_BM{$id} eq $hexval)) {
			my $what = "Evil-GMST Bloodmoon";
			$stats{$what}++;
			print " Cleaned $what: $id\n";
			return;	# return undef to delete
		    } elsif (defined($EVIL_TB{$id}) and ($EVIL_TB{$id} eq $hexval)) {
			my $what = "Evil-GMST Tribunal";
			$stats{$what}++;
			print " Cleaned $what: $id\n";
			return;	# return undef to delete
		    }
		}
	    }
	} elsif ($rectype eq 'CELL') {
	    my $cleaned_ambi;
	    my $cleaned_whgt;
	    if ($opt_clean_instances) {
		# CLEAN OBJECT INSTANCES FROM CELLS
		# clean a FRMR group in plugin cell if its following subrecs exactly match
		# a FRMR group with the same ObjIdx from one of the masters
		my $id = $plug_tr->decode()->id;
		my @plug_groups = @{$plug_tr->split_groups()};
		my @newcell = @{shift(@plug_groups)}; # take header to start new cell def
		# find cells plugin has in common with masters.
		my $nam0_tsr;
		my $n = 0;
		my $cell_modified = 0;
		my $skip_moved_object = 0;
		foreach my $pgref (@plug_groups) {
		    my $cleaned = 0;
		    my @this_group = @$pgref; # all the subrecs in a subrecord (like FRMR, object instance) group
		    if ($this_group[0]->subtype eq 'NAM0') {
			push(@newcell, $nam0_tsr = $this_group[0]);
		    } elsif ($skip_moved_object) {
			# don't clean moved objects (FRMR group after MVRF)
			push(@newcell, @this_group);
			$skip_moved_object = 0;
			dbg("Not cleaning Moved Object: ".instance_name(@this_group)) if (DBG);
		    } elsif ($this_group[0]->subtype eq 'MVRF') {
			# don't clean moved objects (MVRF group)
			push(@newcell, @this_group);
			$skip_moved_object = 1;
		    } elsif ($persistent{instance_name(@this_group)}) {
			# don't clean persistent instances
			dbg("Not cleaning Persistent Object: ".instance_name(@this_group)) if (DBG);
			push(@newcell, @this_group);
		    } else {
			my($plug_objidx, $plug_buf, $plug_objname) = buffalize(@this_group);
		      CHECK_MASTER_INSTANCES:
			foreach my $master (keys %{my_master}) {
			    next unless (defined $MASTER_ID->{$master}->{$id}->{$rectype});
			    dbg("master=$master  CELL.ID=$id  DUMP=".Dumper($MASTER_ID->{$master}->{$id})) if (DBG);
			    my($recbuf, $hdrflags) = @{$MASTER_ID->{$master}->{$id}->{CELL}};
			    dbg("hdrflags=$hdrflags  recbuf=$recbuf") if (DBG);
			    if (my $mast_tr = TES3::Record->new_from_recbuf('CELL', $recbuf, $hdrflags)->decode()) {
				dbg("master=$master mast_tr==".Dumper($mast_tr)) if (DBG);
				my @master_groups = @{$mast_tr->split_groups()};
				shift(@master_groups);  # skip header group
				foreach my $mgref (@master_groups) {
				    next if ($mgref->[0]->subtype eq 'NAM0');
				    dbg("mgref=$mgref  DUMP=".Dumper($mgref)) if (DBG);
				    my($mast_objidx, $mast_buf) = buffalize(@$mgref);
				    if (defined($mast_objidx) and ($plug_objidx == $mast_objidx)) {
					if ($plug_buf eq $mast_buf) {
					    $cleaned++;
					    $cell_modified++;
					    last CHECK_MASTER_INSTANCES; # done with all masters
					}
					last; # done with this master
				    }
				}
			    }
			}
			if ($cleaned) {
			    my $what = "duplicate object instance";
			    $stats{$what}++;
			    print " Cleaned $what ($plug_objname FRMR: $plug_objidx) from CELL: $id\n";
			} else {
			    push(@newcell, @this_group); # no clean
			    $n++ if (defined $nam0_tsr); # count objects after NAM0 marker
			}
		    }
		}
		if ($cell_modified) {
		    $nam0_tsr->{reference_count} = $n;	# update NAM0
		    #msg("newcell DUMP=".Dumper(\@newcell));
		    $plug_tr = CELL->new([@newcell]);
		    $record_modified++;
		}
	    }
	    if ($opt_clean_cell_params or $opt_clean_junk_cells) {
		# CLEAN superfluous AMBI/WHGT
		# we check plugin against all masters, as we can't know with which masters the author created it
		# and ideally, we don't want the result of cleaning to be dependent on load order.
		my $id = $plug_tr->decode()->id;
		foreach my $master (keys %{my_master}) {
		    next unless (defined $MASTER_ID->{$master}->{$id}->{$rectype});
		    if (my $mast_tr = TES3::Record->new_from_recbuf('CELL', @{$MASTER_ID->{$master}->{$id}->{CELL}})->decode()) {
			if ($plug_tr->is_interior) {
			    if ($opt_clean_cell_params) { # check for redundant AMBI/WHGT
				# CLEAN AMBI
				unless ($cleaned_ambi) {
				    my $plug_ambi = $plug_tr->get('AMBI');
				    my $mast_ambi = $mast_tr->get('AMBI');
				    if (defined($plug_ambi) and defined($mast_ambi) and ($plug_ambi->subbuf eq $mast_ambi->subbuf)) {
					$plug_tr->delete_subtype('AMBI');
					$cleaned_ambi++;
				    }
				}
				# CLEAN WHGT (water height)
				# Some plugins (Morrowind.esm) use an INTV subrecord in CELL header instead of WHGT
				# But we do not clean INTV water heights as INTV has multiple uses in a CELL record
				unless ($cleaned_whgt) {
				    my $plugin_whgt = $plug_tr->get('WHGT', 'water_height');
				    my $master_whgt = $mast_tr->get('WHGT', 'water_height');
				    unless (defined $master_whgt) {
					# Do check Masters for INTV water heights.
					$master_whgt = $mast_tr->get('INTV', 'water_height'); # want first INTV before any FRMR
				    }
				    if (defined($plugin_whgt) and defined($master_whgt) and ($plugin_whgt == $master_whgt)) {
					$plug_tr->delete_subtype('WHGT');
					$cleaned_whgt++;
				    }
				}
			    }
			}
			# clean junk cells (interior and exterior)
			if ($opt_clean_junk_cells) {
			    if (scalar($plug_tr->subrecs()) < 4) {
				# junk cells always contain less than 4 subrecords
				my $contains_new_data = 0;
				foreach my $subtype (map { $_->subtype() } $plug_tr->subrecs()) {
				    my $plug_tsr = $plug_tr->get($subtype);
				    my $mast_tsr = $mast_tr->get($subtype) or abort("no mast subtype: $subtype (id=$id) DUMP=".Dumper($mast_tr));
				    if (not $JUNKCELL_SUBTYPE{$subtype} or
					((defined $mast_tsr) and
					 ($plug_tsr->subbuf() ne $mast_tsr->subbuf()))) {
					# record contains subrecords or some new data, so it isn't junk
					$contains_new_data++;
					last;
				    }
				}
				unless ($contains_new_data) {
				    my $what = "junk-CELL";
				    $stats{$what}++;
				    print " Cleaned $what: $id\n";
				    return; # return undef to delete this record
				}
			    }
			}
		    } # master has same cell (by id)
		}
		my @what;
		if ($cleaned_ambi) {
		    push(@what, 'AMBI');
		    $stats{"redundant CELL.AMBI"}++;
		}
		if ($cleaned_whgt) {
		    push(@what, 'WHGT');
		    $stats{"redundant CELL.WHGT"}++;
		}
		if (@what) {
		    print " Cleaned redundant " . join(',', @what) . " from CELL: $id\n";
		    $record_modified++;
		}
	    }
	} elsif ($rectype eq 'TES3') {
	    $plug_tr->decode;
	    foreach my $master ($plug_tr->getall('MAST', 'master')) {
		$my_master{lc($master)}++;
		load_master($master);
	    }
	}
	if ($opt_clean_dups) {
	    my $id = $plug_tr->decode()->id;
	    foreach my $master (keys %{my_master}) {
		next unless (defined $MASTER_ID->{$master}->{$id}->{$rectype});
		my $mastref = $MASTER_ID->{$master}->{$id}->{$rectype};
		if (defined($mastref) and my($mast_recbuf, $mast_hdrflags) = @{$mastref}) {
		    if ($duptype{$rectype} and defined($plug_tr->recbuf()) and
			($plug_tr->recbuf() eq $mast_recbuf) and
			($plug_tr->hdrflags eq $mast_hdrflags)) {
			my $what = "duplicate record";
			$stats{$what}++;
			print " Cleaned $what ($rectype): $id\n";
			return;
		    }
		}
	    }
	}
	if ($record_modified) {
	    return($plug_tr->encode());
	} else {
	    return('');		# passthrough
	}
    };
    if ($opt_overwrite) {
	process_plugin_for_update($plugin, $fun) or return(0);
    } else {
	process_plugin_for_update($plugin, $fun, "Clean_") or return(0);
    }
    if (scalar keys %stats > 0) {
	print qq{\nCleaning Stats for "$plugin":\n};
	foreach my $stat (sort keys %stats) {
	    printf "  %30s:  %4d\n", $stat, $stats{$stat};
	}
    }
} # cmd_clean

sub cmd_dump {
    my($plugin) = @_;
    dbg("cmd_dump($plugin)") if (DBG);
    my $dump_banner = ($opt_no_banner) ? "" : "\nPlugin: $plugin\n";
    my $match_instances = ($opt_instance_match or $opt_instance_no_match);
    my @format_lines;
    foreach (@opt_dump_format) {
	my @format_fields;
	my $line = $_;
	$line =~ s/\%([^%]+)\%/\%s/g;
	while (/\%([^%]+)\%/g) {
	    push(@format_fields, $1);
	}
	push(@format_lines, [$line, @format_fields]);
    }
    my $fun = sub {
	my($rec_match, $rectype, $tr, $print_rec) = rec_match($plugin, @_); # calls tr->decode
	return unless ($rec_match);
	my $id = $tr->decode()->id;
	dbg("cmd_dump: object id = $id") if (DBG);
	if ($dump_banner) {
	    print $dump_banner;
	    $dump_banner = "";
	}
	my $list_record = sub {
	    my($prefix) = @_;
	    $prefix ||= '';
	    if ($rectype eq 'CELL') {
		my $objcnt = (defined $tr->{SH}->{FRMR}) ? scalar(@{$tr->{SH}->{FRMR}}) : 0;
		printf "$prefix $rectype: %-45s\t%5d objects\n", $id, $objcnt;
	    } else {
		my $fnam = $tr->get('FNAM');
		my $fnamstr = defined($fnam->{name}) ? " (" . ($fnam->{name}) . ")" : "";
		print "$prefix $rectype: $id$fnamstr\n";
	    }
	};
	if (@opt_dump_format) {
	    my $output;
	    foreach my $format (@format_lines) {
		my @fmt = @$format;
		my $line = shift(@fmt);
		#print "DBG: line=$line formats=@fmt\n";
		if ($opt_dump_no_quote) {
		    printf "$line\n", map { $tr->getfield($_); } @fmt;
		} else {
		    my @vals;
		    foreach my $field (@fmt) {
			my $val = $tr->getfield($field);
			if ($val =~ /\s/) {
			    $val =~ s/\"/\\"/g; # quote embedded doublequotes
			    $val = qq{"$val"};
			}
			push(@vals, $val);
		    }
		    printf "$line\n", @vals;
		}
	    }
	} elsif ($opt_list) {
	    $list_record->();
	} elsif ($match_instances) {
	    my @groups = @{$tr->split_groups()};
	    my @newcell = @{shift(@groups)}; # take header
	    my $selected = 0;
	    my $nam0_tsr;
	    my $n = 0;
	    foreach my $gref (@groups) {
		my @this_group = @$gref; # all the subrecs in a FRMR (object instance) group
		if ($this_group[0]->subtype eq 'NAM0') {
		    push(@newcell, $nam0_tsr = $this_group[0]);
		} else {
		    my $gstring = join("\n", map { $_->tostr } @this_group);
		    if (((not $opt_instance_match) or ($gstring =~ /$opt_instance_match/i)) and
			((not $opt_instance_no_match) or ($gstring !~ /$opt_instance_no_match/i))) {
			push(@newcell, @this_group);
			$selected++;
			$n++ if (defined $nam0_tsr); # count objects after NAM0 marker
		    }
		}
	    }
	    if ($selected) {
		$nam0_tsr->{reference_count} = $n;	# update NAM0
		my $newtr = CELL->new([@newcell]);
		if ($opt_dump_binary) {
		    $list_record->("Raw Output:");
		    $newtr->write_rec($DUMP_RAWOUT);
		} else {
		    print $newtr->tostr."\n";
		}
	    }
	} else {
	    if ($opt_dump_binary) {
		$list_record->("Raw Output:");
		$tr->write_rec($DUMP_RAWOUT);
	    } else {
		$print_rec ||= $tr->tostr;
		print "\n$print_rec\n" if ($print_rec);
	    }
	}
    };
    process_plugin_for_input($plugin, $fun) or return(0);
} # cmd_dump

sub cmd_recover {
    my($plugin) = @_;
    dbg("cmd_recover($plugin)") if (DBG);
    my($inp, $out) = make_temp($plugin);
    my $typlen = $RECTYPE_LEN - 1;
    my $buff;
    my $buff_size = 4096;
    my $expected = "TES3";
    my $inp_len = -s $plugin;
    my $inp_offset = 0;
    my $rectypes = join('|', keys %TES3::Record::RECTYPES);
    print qq{$plugin: length = $inp_len\n};
    my @removed;
    my $recovered = 0;
    no warnings;
  READREC:
    while ($inp_offset < $inp_len) {
	my($rectype, $tr);
	eval {
	    $tr = TES3::Record->new_from_input($inp, $expected, $plugin);
	    last READREC unless (defined $tr);
	    my $rectype = $tr->rectype;
	    $expected = undef;
	    abort("Error, Invalid record type: $rectype") unless ($TES3::Record::RECTYPES{$rectype});
	    my $id = $tr->decode()->id;
	    foreach my $subtype (map {$_->subtype} $tr->subrecs()) {
		die qq{Error, Invalid record subtype: "$rectype.$subtype"\n} unless ($TES3::Record::RECTYPES{$rectype}->{$subtype});
	    }
	    printf("Offset: %8d  Found: %s %s\n", $inp_offset, $rectype, $id) if (DBG);
	    $recovered++;
	};
	if ($@) {
	    dbg($@) if (DBG);
	    # start a scan from last input offset for something that looks like a record header
	    my $start_offset = $inp_offset;
	    print qq{READ ERROR on record starting at: $start_offset\n};
	    seek($inp, $inp_offset + 1, SEEK_SET) and
		$inp_offset = tell($inp);;
	    print qq{Scanning for records from: $inp_offset\n};
	    my $lost_data;
	    while (1) {
		my $n_read = read($inp, $buff, $buff_size + $typlen);
		last READREC if ($n_read == 0); # EOF
		if (my($stuff, $rectype) = split(/($rectypes)/, $buff)) {
		    my $new_offset = $inp_offset + length($stuff);
		    $lost_data += $stuff;
		    print qq{Scan found $rectype at: $new_offset\n};
		    seek($inp, $new_offset, SEEK_SET) and
			$inp_offset = tell($inp);
		    push(@removed, [$start_offset, $new_offset]);
		    last;
		} else {
		    # Just in case record header started at end boundary, back up by len of rec ID
		    if ($n_read == ($buff_size + $typlen)) {
			seek($inp,  0 - $typlen, SEEK_SET) and
			    $inp_offset = tell($inp);
		    }
		}
	    }
	} else {
	    # everything was AOK
	    $tr->write_rec($out);
	    $inp_offset = tell($inp); # set inp_offset to current position
	}
    }
    if ($recovered and @removed) { # some good data preserved, some bad data discarded
	my $n = scalar(@removed);
	print "Removed $n section@{[($n > 1) ? 's' : '']} of bad data:\n";
	my $total = 0;
	foreach my $chunk (@removed) {
	    my $lost = $chunk->[1] - $chunk->[0];
	    printf "  From: %8d To: %8d  (lost %d bytes)\n",
		$chunk->[0], $chunk->[1], $lost;
	    $total += $lost;
	}
	if (scalar(@removed) > 1) {
	    print "Total bytes lost: $total\n";
	}
	fix_output($inp, $out, $plugin, 1);
    } else {
	print "Unable to recover data from $plugin\n";
	cleanup_temp($inp, $plugin);
    }
} # cmd_recover

sub cmd_shell {
    dbg("cmd_shell") if (DBG);
    no strict;
    $| = 1;
    print "> ";
    my $perlstuff = '';
    my $done = 0;
    while (my $line = <>) {
	$perlstuff = join('', $perlstuff, $line);
	if ($line =~ /^$/ or ($perlstuff =~ /^[^\n]*;$/)) {
	    my $result = eval($perlstuff);
	    if ($@) {
		print "psh ERROR: $@\n> ";
	    } else {
		print "\n==> $result\n" if ($result);
		print "> ";
	    }
	    # clear out buffer
	    $perlstuff = '';
	} else {
	    print "- ";
	}
    }
}

sub cmd_codec {
    dbg("cmd_codec") if (DBG);
    no strict;
    $| = 1;
    print "> ";
    foreach (@RECDEFS) {
	foreach my $defref (@{$_}) {
	    #gen_subrec_methods($rectype, @{$defref});
	    # NOTYET
	}
    }
}

sub cmd_undelete {
    my($plugin) = @_;
    dbg("undelete") if (DBG);
    my $fun = sub {
	my($rectype, $tr) = @_;
	return('') unless ($rectype eq 'CELL');	# passthrough unchanged
	$tr->decode;
	my $id = $tr->id;
	my @newsl;
	my @objects;
	my $name;
	foreach my $tsr ($tr->subrecs()) {
	    if ($tsr->subtype eq 'DELE') {
		$tr->{_modified_} = 1;
		push(@objects, $name) if (VERBOSE and defined $name);
		push(@newsl, CELL::ZNAM->new({disabled => 0}));
		push(@newsl, CELL::DATA->new({x => 0, y =>0, z=>0, x_angle=>0, y_angle=>0, z_angle=>0}));
	    } else {
		$name = $tsr->{name} if ($tsr->subtype eq 'NAME');
		push(@newsl, $tsr);
	    }
	}
	if ($tr->{_modified_}) {
	    print "Undeleted objects in CELL: $id\n";
	    foreach my $obj (@objects) {
		print "\t$obj\n";
	    }
	    return(CELL->new([@newsl]));
	} else {
	    return('');			# passthrough unchanged
	}
    };
    process_plugin_for_update($plugin, $fun) or return(0);
}

sub cmd_active {
    my(@plugins) = @_;
    my %active;
    my $n = 0;
    if ($opt_active_on or $opt_active_off) {
	my $gamefiles = $T3->read_gamefiles();
	my %gfiles = ();
	$gfiles{lc $_} = $_ foreach (@$gamefiles);
	if ($opt_active_on) {	# Activating given plugins
	    foreach my $plug (@plugins) {
		unless ($gfiles{lc $plug}) {
		    prn("ACTIVATED: $plug");
		    $gfiles{lc $plug} = $plug;
		}
	    }
	} elsif ($opt_active_off) {	# De-Activating given plugins
	    foreach my $plug (@plugins) {
		if ($gfiles{lc $plug}) {
		    prn("DEACTIVATED: $plug");
		    delete $gfiles{lc $plug};
		}
	    }
	}
	my @newgamefiles = sort values %gfiles;
	$T3->write_gamefiles(\@newgamefiles);
    } else {
	print "[LOAD ORDER]\n";
	my $n = 0;
	foreach ($T3->load_order) { print "$_\n"; $n++; }
	print "[$n Active Plugins]\n";
    }
} # cmd_active

sub cmd_resetdates {
    foreach my $file_name (sort keys %ORIGINAL_DATE) {
	my $file_path = $T3->datapath($file_name);
	my($atime, $mtime) = (stat($file_path))[8,9];
	my $origtime = $ORIGINAL_DATE{$file_name};
	if ($mtime != $origtime) {
	    prn("Reset Date of: $file_name to: ".scalar(localtime($origtime)));
	    utime($origtime, $origtime, $file_path);
	}
    }
}

sub minihelp {
    die <<"EOF";
Usage: tes3cmd COMMAND OPTIONS plugin...

VERSION: $::VERSION

tes3cmd is a utility for the Elder Scrolls game MORROWIND
that can examine and modify plugin files in many ways.

FOR MORE HELP, TYPE:

tes3cmd help
EOF
}

use feature 'say';
use Config;
use Config::IniFiles;
use File::Copy;
use File::Basename;
use File::HomeDir;
use File::Spec::Functions 'catfile';
use Convert::Color::RGB8;
use Convert::Color::HSV;
use Tk;
use File::Find::Rule;
use List::Util qw[min max];

sub tes3cmd_main {

### BEGIN CONFIG 

my $DISABLE_FLICKERING => 1; 

## HSV and light radius multipliers 

# for colored lights 
my $C_HUE=1.0;
my $C_SAT=0.9;
my $C_VAL=0.7;
my $C_RAD=1.1;

# for lights with an orange hue, commonly used on torches and wall sconces (main sources of light)
my $HUE=0.62;
my $SAT=0.8;
my $VAL=0.57;
my $RAD=2.0;

### END CONFIG

my $ended_in_warning = 0;

# override any settings in the config file (in same directory as executable)
my $ini_path = "waza_lightfixes.cfg";

if (-e $ini_path) {
	my $cfg = Config::IniFiles->new( -file => $ini_path);
	$C_HUE = $cfg->val("Colored", "hue", $C_HUE);
	$C_SAT = $cfg->val("Colored", "saturation", $C_SAT);
	$C_VAL = $cfg->val("Colored", "value", $C_VAL);
	$C_RAD = $cfg->val("Colored", "radius", $C_RAD);
	$HUE = $cfg->val("General", "hue", $HUE);
	$SAT = $cfg->val("General", "saturation", $SAT);
	$VAL = $cfg->val("General", "value", $VAL);
	$RAD = $cfg->val("General", "radius", $RAD);
	$DISABLE_FLICKERING = $cfg->val("General", "disableflickering", $DISABLE_FLICKERING);
}

if ($DISABLE_FLICKERING) { say "Disable Flickering \t= True"; }
# find config file
my $config_path = "";
my $os = $Config{osname};

if ($os eq "MSWin32") {
	$config_path = catfile(File::HomeDir->my_documents, "My Games", "OpenMW", "openmw.cfg");
} elsif ($os eq "linux") {
	$config_path = catfile(File::HomeDir->my_home, ".config", "openmw", "openmw.cfg"); 
} elsif ($os eq "darwin") {
	$config_path = catfile(File::HomeDir->my_home, "Library", "Preferences", "openmw", "openmw.cfg");
} else {
	say "ERROR: could not detect correct operating system, aborting :(";
	exit;
}

if ( -e $config_path) {
	say "found config file '$config_path'";
	say "making a backup of config...just in case";
	copy($config_path, "openmw.cfg.bck") or say "failed creating backup :(";
	} else {
	say "no config file found, aborting!";
	exit;
}

# data paths as seen by openmw, first index has highest precedence
my @data_paths;
# plugins as seen by openmw with absolute paths, first index has highest precedence
my @plugin_paths;

my $res=open (my $fh, "<", $config_path);
if (!$res) {
	say "uh oh, failed opening the file, `$!`"; 
	exit;
}
while (my $line = <$fh>) { #
    if ($line =~ /(?<=^content=)(.*$)/) {
		my $str = $1;
		$str =~ s/\s+$//; # right trim, couldn't figure out how to make this into one regex cause lazy 
        push @plugin_paths, $str;
		say "TESTING $str";
    } elsif ($line =~ /(?<=^data=)(")(.*)(?(1)\1|)\s*$/) { # 
		push @data_paths, $2;
	} 
}

@data_paths = reverse(@data_paths);
@plugin_paths = reverse(@plugin_paths);

# retrieve plugin absolute paths 
foreach my $plugin (@plugin_paths) {
	$plugin =~ s/[()\.]/\\$&/g;
	my @found_files = File::Find::Rule->file
								      ->name(qr/$plugin$/i)
									  ->maxdepth(1)
									  ->readable
									  ->in(@data_paths);
	if (!@found_files) {
		$ended_in_warning = 1;
		say "ERROR: could not find absolute path to plugin `$plugin`: If you are using global data paths, adding this data path to your config will correct this.";
	} else {
		say "Found $found_files[0]";
		$plugin = $found_files[0];
	}
}

my $output = open_for_output("LightFixes.esp");
print $output make_header({
	author => "...",
	description => "...",
});

my %seen;
for my $plugin (@plugin_paths) {

	next if basename($plugin) eq "LightFixes.esp";
	next if (basename($plugin) =~ m/.omwscripts/);

	if (! -e $plugin) {
		$ended_in_warning = 1;
		say "ERROR: could not find path to plugin $plugin, any records that this plugin modifies will not be seen by this!";
		next;
	}

	if ($plugin =~ /^nosun|^reversed_black_lights/i) {
		die qq(\n"$plugin" is deprecated, remove it and re-run the script\n);
	}
	say "USING $plugin";
	my $input = open_for_input($plugin);
	while (my $record = TES3::Record->new_from_input($input)) {

		# skip invalid type
		my $type = $record->rectype;
		next if $type !~ /CELL|LIGH/;

		# skip already seen
		my $id = $record->decode->id;
		next if exists $seen{$id}; $seen{$id}++;

		if ($type eq 'LIGH') {
			my $data = $record->get('LHDT');

			if ($DISABLE_FLICKERING) {	
				if ($$data{flags} & $LHDT_FLAGS{flicker}) {
					$$data{flags} ^= $LHDT_FLAGS{flicker};
				}
				if ($$data{flags} & $LHDT_FLAGS{flicker_slow}) {
					$$data{flags} ^= $LHDT_FLAGS{flicker_slow};
				}
			}

			if ($$data{flags} & $LHDT_FLAGS{negative}) {
				$$data{flags} ^= $LHDT_FLAGS{negative};
				$$data{color} = $$data{radius} = 0;
			} else {
				# retrieve each color channel
				my ($r,$g,$b) = ($$data{color} & 0xFF, ($$data{color} & 0xFF00) >> 8, ($$data{color} & 0xFF0000) >> 16);
				my $color = Convert::Color::RGB8->new($r,$g,$b);
				my $hsv = $color->as_hsv;
   				my ( $h, $s, $v ) = $hsv->hsv;
				if (($hsv->hue > 64) || ($hsv->hue < 14)) {  # red, purple, blue, green, yellow lights 
					$hsv = Convert::Color::HSV->new($h*$C_HUE,$s*$C_SAT,$v*$C_VAL);
					$$data{radius} *= $C_RAD;
				} else { # all other lamps 
					$hsv = Convert::Color::HSV->new($h*$HUE,$s*$SAT,$v*$VAL);
					$$data{radius} *= $RAD;
				}
				$color = $hsv->convert_to('rgb8');
				# convert back to 4-byte RGBA where R is right-most byte and set light color 
				my $newcolor = oct("0b".sprintf("%08b%08b%08b%08b", "0",$color->blue,$color->green,$color->red));
				$$data{color} = $newcolor;
			}
		}
		elsif ($type eq 'CELL') {
			next if not $record->is_interior;

			# clear light value
			$record->set({f=>'sunlight'}, 0);

			# discard other values
			my @keep = grep {defined $_} (
				$record->get('NAME'),
				$record->get('DATA'),
				$record->get('AMBI'),
			);
			$record->DESTROY;
			$record->append($_) for @keep;
		}

		say "MODIFIED $type: $id ($plugin)";

		# save to output plugin
		$record->encode->write_rec($output);
	}
}

my $msg = new MainWindow;
if ($ended_in_warning) {	
	$msg -> messageBox(-message=>"ESP generated but with warnings FeelsBadMan");
} else {
	$msg -> messageBox(-message=>"ESP generated with no warnings, FeelsAmazingMan");
}

} # tes3cmd_main

tes3cmd_main();

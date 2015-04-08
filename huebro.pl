#!/usr/bin/env perl

#
# huebro.pl - Monitors, logs and restores Philips Hue light bulb states after a power failure.
#
# Copyright 2015 - Jan Fredrik Leversund <kluzz@radical.org>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#



##########################     USER CONFIGURABLE SECTION      ########################

# How many lights must be in the default state before we assume a power failure happened?
# Keep in mind this only works with lights of the type "Extended color light". You can check
# this using this script's 'current' command.
use constant MAGIC_NUMBER => 1;

# URL for the local bridge. If the script runs slowly, use the IP address instead of hostname.
use constant BRIDGE => 'http://192.168.2.16';

# The default is suitable for unix; you might want to change it on other platforms.  
use constant HOMEDIR => "$ENV{HOME}/.huebro"; 

##########################  END OF USER CONFIGURABLE SECTION  ########################



# You probably don't need to change these
use constant KEY => 'huebrohuebro';
use constant DBFILE => "huebro.db";
use constant LOGFILE => "huebro.log";

# This is the default state for a newly powered bulb
use constant DEF_TYPE => 'Extended color light';
use constant DEF_COLORMODE => 'ct';
use constant DEF_CT => 369;
use constant DEF_BRI => 254;

# Current version
use constant VERSION => "1.0";

# Just grab a time stamp
use constant TIME => time;

use constant HELP => q{
Usage: huebro.pl [-d] <command>

	-v        - Be verbose about what happens (writes log to STDOUT).
	-d        - Switch on debugging output. Usually very annoying.

Commands:

    reg       - Push the link button on the bridge, then run this command to
                register the application.
    unreg     - Un-register this application from the bridge.
    check     - Check and log the light states, determining if a power failure
                has occurred, reverting the lights to a previous state if
                necessary. Run this at suitable intervals using cron or some
                other form of scheduler.
    current   - Show the current state of all lights, according to the bridge.
    previous  - Show the previous state of all lights, according to the
                database.
    lookup    - Prints a lookup table containing light id and name, suitable
                for use with Splunk, etc.
    version   - Show the program version.

};

use Data::Dumper;
use DBI;
use LWP::UserAgent;
use JSON;
use Getopt::Std;
use Time::HiRes qw(usleep nanosleep);
use POSIX;
use common::sense;

# Read command line switches
my %opts = ();
getopts('dv', \%opts);
my $DEBUG = $opts{d};
my $VERBOSE = $opts{v};

# Make sure our storage directory exists.
mkdir HOMEDIR unless -d HOMEDIR;
die "Unable to create directory " . HOMEDIR . ": $!\n" unless -d HOMEDIR;

# Open the log file
my $lf = HOMEDIR . '/' . LOGFILE;
open(LOG, '>>:utf8', $lf) or die "Unable to open log file " . $lf . ": $!\n";

# Unicode output
 binmode(STDOUT, ":utf8");

# Set up the user agent
my $ua = LWP::UserAgent->new;
$ua->timeout(5);
$ua->env_proxy;

# Open/create the database file
my $dbh = DBI->connect("dbi:SQLite:dbname=" . HOMEDIR . "/" . DBFILE, "", "")
	or die "Unable to open or create the database file " . HOMEDIR . "/" . DBFILE . ": $!\n";
$dbh->{sqlite_unicode} = 1;

# Make sure the database is set up properly
check_database($dbh);

# Prepare all database statements.
my $sth = prepare_statements();

# Command selector
if ($ARGV[0] eq 'check')
{
	command_check();
}
elsif ($ARGV[0] eq 'reg')
{
	reg();
}
elsif ($ARGV[0] eq 'unreg')
{
	command_unreg();
}
elsif ($ARGV[0] eq 'current')
{
	command_current();
}
elsif ($ARGV[0] eq 'previous')
{
	command_previous();
}
elsif ($ARGV[0] eq 'lookup')
{
	command_lookup();
}
elsif ($ARGV[0] eq 'version')
{
	command_version();
}
else
{
	die HELP;
}




sub command_check
{
	my ($code, $json) = get(sprintf("%s/api/%s/lights", BRIDGE, KEY));

	if (ref($json) eq 'ARRAY' and defined $json->[0]{error})
	{
		print Dumper($json) if $DEBUG;
		logthis("Fetching light info from bridge %s failed: %s", BRIDGE, $json->[0]{error}{description});

		return;
	}

	my $curr_lights = parse_lights($json);
	print Dumper($curr_lights) if $DEBUG;

	# Do we need to restore a previous state?
	my $needs_restore = check_lights($curr_lights);
	logthis("Magic number of lights in default state has been reached; state restoration required.") if $needs_restore;

	# Grab a snapshot of the previous lights and states
	my $prev_lights = previous_lights();

	# Start a new transaction
	$dbh->begin_work;

	# Any new lights?
	my $new_lights = 0;
	foreach my $uid (keys %{$curr_lights})
	{
		unless (exists $prev_lights->{$uid})
		{
			# Add a new light.
			my $rowid = insert_light($curr_lights->{$uid});
			insert_meta($curr_lights->{$uid}, $rowid);
			insert_state($curr_lights->{$uid}, $rowid);
			$new_lights++;
		}
	}

	# If any new lights were inserted, refresh the previous snapshot.
	$prev_lights = previous_lights() if $new_lights;

	if ($needs_restore)
	{
		restore_lights($curr_lights, $prev_lights);
	}
	else
	{
		new_snapshot($curr_lights, $prev_lights);
	}

	# Commit the work
	$dbh->commit or die $dbh->errstr;
}

sub command_reg
{
	my ($code, $json) = post(BRIDGE . '/api', {devicetype => "Hue#Bro", username => KEY});

	if (defined $json->[0]{error})
	{
		logthis("Registration attempt on bridge %s failed: %s", BRIDGE, $json->[0]{error}{description});
	}
	else
	{
		logthis("Successfully registered with bridge %s.", BRIDGE);
	}

	print Dumper($json) if $DEBUG;
}


sub command_unreg
{
	my ($code, $json) = post(sprintf('%s/api/%s/config/whitelist/%s', BRIDGE, KEY, KEY), {}, 'DELETE');

	if (defined $json->[0]{error})
	{
		logthis("Unregistration attempt from bridge %s failed: %s", BRIDGE, $json->[0]{error}{description});
	}
	else
	{
		logthis("Unregistered with bridge %s.\n", BRIDGE);
	}

	print Dumper($json) if $DEBUG;
}


sub command_current
{
	my ($code, $json) = get(sprintf("%s/api/%s/lights", BRIDGE, KEY));

	if (ref($json) eq 'ARRAY' and defined $json->[0]{error})
	{
		print Dumper($json) if $DEBUG;
		printf("Fetching light info from bridge %s failed: %s", BRIDGE, $json->[0]{error}{description});

		return;
	}

	my $lights = parse_lights($json);

	foreach my $uid (sort { $lights->{$a} <=> $lights->{$b} } keys %{$lights})
	{
		my $l = $lights->{$uid};

		print_light(
			$l->{id},
			$l->{name},
			$uid,
			$l->{modelid},
			$l->{type},
			$l->{swversion},
			$l->{state}{reachable} ? "yes" : "no",
			$l->{state}{on} ? "yes" : "no",
			$l->{state}{colormode},
			$l->{state}{ct},
			$l->{state}{xy}[0],
			$l->{state}{xy}[1],
			$l->{state}{hue},
			$l->{state}{sat},
			$l->{state}{bri},
			$l->{state}{effect},
			$l->{state}{alert}
		);
	}
}


sub command_previous
{
	my $lights = previous_lights();

	foreach my $uid (sort { $lights->{$a}{meta}{id} <=> $lights->{$b}{meta}{id} } keys %{$lights})
	{
		my $l = $lights->{$uid};

		print_light(
			$l->{meta}{id},
			$l->{meta}{name},
			$uid,
			$l->{modelid},
			$l->{type},
			$l->{meta}{swversion},
			$l->{state}{reachable} ? "yes" : "no",
			$l->{state}{on} ? "yes" : "no",
			$l->{state}{colormode},
			$l->{state}{ct},
			$l->{state}{x},
			$l->{state}{y},
			$l->{state}{hue},
			$l->{state}{sat},
			$l->{state}{bri},
			$l->{state}{effect},
			$l->{state}{alert}
		);
	}
}

sub command_lookup
{
	my ($code, $json) = get(sprintf("%s/api/%s/lights", BRIDGE, KEY));

	if (ref($json) eq 'ARRAY' and defined $json->[0]{error})
	{
		print Dumper($json) if $DEBUG;
		printf("Fetching light info from bridge %s failed: %s", BRIDGE, $json->[0]{error}{description});

		return;
	}

	my $lights = parse_lights($json);

	print "id,name\n";

	foreach my $uid (sort { $lights->{$a} <=> $lights->{$b} } keys %{$lights})
	{
		my $l = $lights->{$uid};

		print $l->{id} . "," . $l->{name} . "\n";
	}
}

sub print_light
{
printf(q{
-[%2d]----------------------------------------
 Name:       %s
 Unique Id:  %s
 Model Id:   %s
 Type:       %s
 SW Version: %s
 Reachable:  %s
 On:         %s
 Colormode:  %s
 Colortemp:  %s
 X, Y:       %s, %s
 Hue:        %s
 Saturation: %s
 Brightness: %s
 Effect:     %s
 Alert:      %s
}, @_);
}


sub command_version
{
		print "Version: " . VERSION . "\n";
}


sub restore_lights
{
	my $curr = shift;
	my $prev = shift;

	foreach my $uid (sort keys %{$curr})
	{
		my $c = $curr->{$uid};
		my $p = $prev->{$uid};
		my $cs = $c->{state};
		my $ps = $p->{state};

		my $cmd = {};

		# The idea here is to reach the desired state using a minimum amount of state changes.

		# Only switch light on or off if needed
		if ($cs->{on} and not $ps->{on})
		{
			$cmd->{on} = JSON::false;
		}
		elsif (not $cs->{on} and $ps->{on})
		{
			$cmd->{on} = JSON::true;
		}

		# Only attempt a color change if the light is supposed to be on
		if ($ps->{on})
		{
			# Is the color mode "XY"?
			if ($ps->{colormode} eq 'xy')
			{
				# Do we need to change the xy?
				if ($cs->{xy}[0] ne $ps->{x} or $cs->{xy}[1] ne $ps->{y})
				{
					$cmd->{xy} = [$ps->{x} * 1, $ps->{y} * 1];
				}
			}
			# Is the color mode "Color Temperature"
			elsif ($ps->{colormode} eq 'ct')
			{
				# Do we need to change the ct?
				if ($cs->{ct} ne $ps->{ct})
				{
					$cmd->{ct} = $ps->{ct} * 1;
				}
			}
			# Is the color mode "Hue/Saturation"
			else
			{
				# Do we need to change the hue?
				if ($cs->{hue} ne $ps->{hue})
				{
					$cmd->{hue} = $ps->{hue} * 1;
				}

				# Do we need to change the saturation?
				if ($cs->{sat} ne $ps->{sat})
				{
					$cmd->{sat} = $ps->{sat} * 1;
				}
			}

			# Do we need to change the brightness?
			if ($cs->{bri} ne $ps->{bri})
			{
				$cmd->{bri} = $ps->{bri} * 1;
			}

			# Do we need to change the effect?
			if ($cs->{effect} ne $ps->{effect})
			{
				$cmd->{effect} = $ps->{effect};
			}

			# Do we need to change the alert?
			if ($cs->{alert} ne $ps->{alert})
			{
				$cmd->{alert} = $ps->{alert};
			}
		}

		# Only make a state change if there's actually anything that needs changing
		if (scalar keys %{$cmd})
		{
			my ($code, $json) = post(sprintf("%s/api/%s/lights/%d/state", BRIDGE, KEY, $c->{id}), $cmd, "PUT");

			if (defined $json->[0]{error})
			{
				printf("Error: %s\n", $json->[0]{error}{description});
			}
			else
			{
				printf("Success!\n") if $DEBUG;
			}

			logthis(
				'Restoring state: uniqueid="%s" id=%d on="%s" colormode="%s" ct="%s" xy=[%.4f,%.4f] hue=%d sat=%d bri=%d effect="%s" alert="%s"',
				$c->{uniqueid},
				$c->{id},
				$ps->{on} ? "true" : "false",
				$ps->{colormode},
				$ps->{ct},
				$ps->{x},
				$ps->{y},
				$ps->{hue},
				$ps->{sat},
				$ps->{bri},
				$ps->{effect},
				$ps->{alert}
			);

			# The recommended max amount of state changes per second is 10.
			usleep(100*1000); 
		}
	}
}


sub new_snapshot
{
	my $curr = shift;
	my $prev = shift;

	foreach my $uid (sort keys %{$curr})
	{
		my $c = $curr->{$uid};
		my $p = $prev->{$uid};
		my $cs = $c->{state};
		my $ps = $p->{state};

		# First, check meta info
		if (
			$c->{name} ne $p->{meta}{name} or
			$c->{swversion} ne $p->{meta}{swversion}
		)
		{
			insert_meta($c, $p->{rowid});
			printf("New meta:\n%s\n", Dumper($c)) if $DEBUG;
		}

		# Second, check light state
		if (
			$cs->{on} ne $ps->{on} or
			$cs->{reachable} ne $ps->{reachable} or
			$cs->{colormode} ne $ps->{colormode} or
			$cs->{ct} ne $ps->{ct} or
			$cs->{xy}[0] ne $ps->{x} or
			$cs->{xy}[1] ne $ps->{y} or
			$cs->{hue} ne $ps->{hue} or
			$cs->{sat} ne $ps->{sat} or
			$cs->{bri} ne $ps->{bri} or
			$cs->{effect} ne $ps->{effect} or
			$cs->{alert} ne $ps->{alert}
		)
		{
			insert_state($c, $p->{rowid});
			printf("Old state:\n%s\n", Dumper($ps)) if $DEBUG;
			printf("New state:\n%s\n", Dumper($cs)) if $DEBUG;
		}
	}
}



sub parse_lights
{
	my $json = shift;
	my $parsed = {};

	while (my ($id, $light) = each %{$json})
	{
		$light->{state}{on} = $light->{state}{on} ? 1 : 0;
		$light->{state}{reachable} = $light->{state}{reachable} ? 1 : 0;
		$light->{id} = $id;

		$parsed->{$light->{uniqueid}} = $light;
	}

	$parsed;
}


sub check_lights
{
	my $lights = shift;

	# How many light are set to default?
	my $default_count = 0;

	while (my ($uniqueid, $light) = each %{$lights})
	{
		if (
			$light->{type} eq DEF_TYPE and
			$light->{state}{colormode} eq DEF_COLORMODE and
			$light->{state}{ct} eq DEF_CT and
			$light->{state}{bri} eq DEF_BRI and
			$light->{state}{on} and # We don't count bulbs that are off.
			$light->{state}{reachable} # We don't count unreachable bulbs.
		)
		{
			# This is a newly powered bulb, in it's default setting.
			print "Default: " . $light->{name} . "\n" if $DEBUG;
			$default_count++;
		}

	}

	print "Defaulting bulbs: $default_count\nMagic number: " . MAGIC_NUMBER . "\n" if $DEBUG;

	# Return true if we need to restore state. 
	$default_count >= MAGIC_NUMBER;
}



# The log writer
sub logthis
{
	my $t = strftime "%FT%TZ", gmtime;
	my $l = sprintf("[%s] " . shift . "\n", $t, @_);
	print LOG $l;
	print $l if $VERBOSE;
}


sub get
{
	my $url = shift;

	my $req = HTTP::Request->new('GET', $url);
	$req->content_type('application/json');

	my $res = $ua->request($req);

	die $res->status_line unless $res->is_success;

	($res->code, decode_json($res->content));
}


sub post
{
	my $url = shift;
	my $content = shift;
	my $method = shift;
	$method = "POST" unless $method;

	my $req = HTTP::Request->new($method, $url);
	$req->content_type('application/json');
	$req->content(encode_json($content));

	my $res = $ua->request($req);

	die $res->status_line unless $res->is_success;

	($res->code, decode_json($res->content));
}


sub check_database
{
	my $sth = $dbh->table_info(undef, 'main', undef, 'TABLE');
	my $info = $sth->fetchall_arrayref();

	unless (scalar @{$info})
	{
		create_tables($dbh);
	}
}


sub create_tables
{
	$dbh->begin_work;

	$dbh->do(q{
		create table
			light
		(
			light_id integer primary key,
			uniqueid text not null unique,
			modelid text not null,
			type text not null,
			time integer not null
		)
	}) or die $dbh->errstr;

	$dbh->do(q{
		create table
			meta
		(
			meta_id integer primary key,
			light_id integer not null,
			id integer not null,
			name text not null,
			swversion integer not null,
			time integer not null,
			foreign key (light_id) references light(light_id)
		)
	}) or die $dbh->errstr;

	$dbh->do(q{
		create table
			state
		(
			state_id integer primary key,
			light_id integer not null,
			reachable integer not null,
			"on" integer not null,
			colormode text not null,
			ct text,
			x real not null,
			y real not null,
			hue integer not null,
			sat integer not null,
			bri integer not null,
			effect text not null,
			alert text not null,
			time integer not null,
			foreign key (light_id) references light(light_id)
		)
	}) or die $dbh->errstr;

	$dbh->do(q{
		create view
			latest_state as
		select
			light.uniqueid,
			state.*
		from
			light,
			state
		where
			light.light_id = state.light_id
		group by
			state.light_id
		having
			max(state.time)
	}) or die $dbh->errstr;

	$dbh->do(q{
		create view
			latest_meta as
		select
			light.uniqueid,
			meta.*
		from
			light,
			meta
		where
			light.light_id = meta.light_id
		group by
			meta.light_id
		having
			max(meta.time)
	}) or die $dbh->errstr;

	$dbh->commit or die $dbh->errstr;
}


sub prepare_statements
{
	my %sth = ();

	$sth{insert_light} = $dbh->prepare(q{
		insert into
			light
		(
			uniqueid,
			modelid,
			type,
			time
		)
		values
		(
			?,
			?,
			?,
			?
		)
	}) or die $dbh->errstr;

	$sth{insert_meta} = $dbh->prepare(q{
		insert into
			meta
		(
			light_id,
			id,
			name,
			swversion,
			time
		)
		values
		(
			?,
			?,
			?,
			?,
			?
		)
	}) or die $dbh->errstr;

	$sth{insert_state} = $dbh->prepare(q{
		insert into
			state
		(
			light_id,
			reachable,
			"on",
			colormode,
			ct,
			x,
			y,
			hue,
			sat,
			bri,
			effect,
			alert,
			time
		)
		values
		(
			?,
			?,
			?,
			?,
			?,
			?,
			?,
			?,
			?,
			?,
			?,
			?,
			?
		)
	}) or die $dbh->errstr;

	$sth{select_lights} = $dbh->prepare(q{
		select
			light_id,
			uniqueid,
			modelid,
			type
		from
			light
	}) or die $dbh->errstr;

	$sth{select_meta} = $dbh->prepare(q{
		select
			*
		from
			latest_meta
	}) or die $dbh->errstr;

	$sth{select_states} = $dbh->prepare(q{
		select
			*
		from
			latest_state
	}) or die $dbh->errstr;

	\%sth;
}


sub insert_light
{
	my $light = shift;

	$sth->{insert_light}->execute(
		$light->{uniqueid},
		$light->{modelid},
		$light->{type},
		TIME	
	) or die $dbh->errstr;

	logthis('New light: uniqueid="%s" modelid="%s" type="%s"', $light->{uniqueid}, $light->{modelid}, $light->{type});

	my $id = $dbh->last_insert_id("","","","") or die $dbh->errstr;

	$id;
}


sub insert_meta
{
	my $light = shift;
	my $rowid = shift;

	$sth->{insert_meta}->execute(
		$rowid,
		$light->{id},
		$light->{name},
		$light->{swversion},
		TIME	
	) or die $dbh->errstr;

	logthis('New meta: uniqueid="%s" id=%d name="%s" swversion="%s"', $light->{uniqueid}, $light->{id}, $light->{name}, $light->{swversion});
}


sub insert_state
{
	my $light = shift;
	my $rowid = shift;

	$sth->{insert_state}->execute(
		$rowid,
		$light->{state}{reachable},
		$light->{state}{on},
		$light->{state}{colormode},
		$light->{state}{ct},
		$light->{state}{xy}[0],
		$light->{state}{xy}[1],
		$light->{state}{hue},
		$light->{state}{sat},
		$light->{state}{bri},
		$light->{state}{effect},
		$light->{state}{alert},
		TIME	
	) or die $dbh->errstr;

	logthis(
		'New state: uniqueid="%s" id=%d on="%s" colormode="%s" ct=%s xy=[%.4f,%.4f] hue=%d sat=%d bri=%d effect="%s" alert="%s"',
		$light->{uniqueid},
		$light->{id},
		$light->{state}{on} ? "true" : "false",
		$light->{state}{colormode},
		$light->{state}{ct},
		$light->{state}{xy}[0],
		$light->{state}{xy}[1],
		$light->{state}{hue},
		$light->{state}{sat},
		$light->{state}{bri},
		$light->{state}{effect},
		$light->{state}{alert}
	);
}


sub previous_lights
{
	my %l = ();

	$sth->{select_lights}->execute or die $sth->errstr;

	while (my @row = $sth->{select_lights}->fetchrow_array)
	{
		$l{$row[1]} = {
			rowid => $row[0],
			modelid => $row[2],
			type => $row[3]
		};
	}

	$sth->{select_meta}->execute or die $sth->errstr;

	while (my $row = $sth->{select_meta}->fetchrow_hashref)
	{
		$l{$row->{uniqueid}}{meta} = $row;
	}

	$sth->{select_states}->execute or die $sth->errstr;

	while (my $row = $sth->{select_states}->fetchrow_hashref)
	{
		$l{$row->{uniqueid}}{state} = $row;
	}

	print Dumper(\%l) if $DEBUG;

	\%l;
}


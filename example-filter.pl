#!/usr/bin/perl

# This is an example filter using Email::Intestine.  It's based on my
# actual filter.

use strict;
use warnings;

# I keep my Unix environment in Git and clone it to new machines as
# necessary.  That includes my mail filter so I also keep a copy of
# Intestine.pm there.  For that to work, I just set @INC here and
# don't bother installing this somewhere in my PERLLIB on each new
# machine.
BEGIN {unshift @INC, '/home/me/env/'};

use Email::Intestine;

# I generally leave this on for a day or two after making a change to
# the filter.
$KEEP_CRASH = 1;

# Make sure there's at least one logline for each incoming message.
logm ("Message from $HDRS{From}, subject '$HDRS{Subject}'");


# I manage a bunch of small, exclusive mailing lists.  Messages to
# them get forwarded to this address where the filter hands it off to
# another program called pyramid.  You don't want to know what it
# does.  Trust me.
for my $list (qw{illuminati cthulhucult jonasfans}) {
  pipeMessage ("pyramid $list dispatch")
    if ($HDRS{'To'} =~ /$list\@mydomain.com/i);
}


# Various forms of bulk mail get forwarded to another account.
# Periodically, I'll pull it down with Thunderbird and fish around for
# anything useful.
for my $rule (
              [From     => 'Google+'],
              [From     => 'Facebook'],
              [From     => 'MySpace'],
              [From     => 'Friendster'],
              [From     => 'Orkut'],
             ) {
  my ($hdr, $pat) = @{$rule};

  if ($HDRS{$hdr} =~ /$pat/) {
    logm("'$hdr: $HDRS{$hdr}' matched /$pat/");
    forwardMessage('bulkmail@localhost');
  }
}

# Anything else goes through bogofilter to see if it's spam or not.
outputMessage ("$HOME/Mail/spambox")
  if (filterThrough ("/usr/bin/bogofilter") == 0);

# Otherwise, it goes into the inbox
outputMessage("$HOME/Mail/inbox");


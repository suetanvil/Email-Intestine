package Email::Intestine;

# Export expressions:
use Exporter 'import';
our @EXPORT = qw{$SENDMAIL %HDRS $HEADERS $BODY $KEEP_CRASH $HOME $USER
                 outputMessage forwardMessage pipeMessage filterThrough
                 finish logm panic};

use strict;
use warnings;

use English;
use Fcntl qw{:flock :seek};
use Getopt::Long;


# Exported globals
our $HOME;                  # Home directory.  Copy of $Home.
our $USER;                  # Username.  Copy of $User.
our $SENDMAIL;              # Path to the SENDMAIL program. Settable.
our %HDRS;                  # Global hash of headers
our $HEADERS;               # String containing text of header
our $BODY;                  # String containing body text

our $KEEP_CRASH = 0;        # If set to true, do not delete the
                            # crashbox on shutdown.  Settable.

# Arguments:
my $Verbose = 0;            # If set, display more messages
my $NoLogFile = 0;          # Print log messages to stderr instead of file
my $NoForward = 0;          # Disable email forwarding
my $NoPipe = 0;             # Disable email piping

# Internal globals
my $User;                   # username
my $Home;                   # Home directory
my $WorkDir;                # Directory for work files.
my $EmailFrom = 'UNKNOWN';  # Sender ID for the 'From ' line.
my $CrashBoxName;           # Name of the emergency backup
my $MailText = '';          # Contents of message

# Initialize the state of the filter. Called on module load.
sub init {
  initVars();
  parseArgs();
  finishInit();

  logm ("Unable to set \$SENDMAIL") if ($Verbose && !defined($SENDMAIL));

  getMessage();
  digestMessage();
}


# Initialize the global state.
sub initVars {

  my ($name, $x2,$x3,$x4,$x5,$x6,$x7, $dir) = getpwuid($EFFECTIVE_USER_ID);

  # Set $User, letting the environment override the PW entry
  $User = $ENV{USER};
  $User = $name
    unless defined($User);
  panic("Unable to get username") unless defined($User);

  # Set $Home in the same way
  $Home = $ENV{HOME};
  $Home = $dir
    unless defined($Home);
  panic("Unable to get home directory") unless defined($Home);

  # Attempt to find a valid location of the sendmail program.  If it
  # is missing, the client can still override it.
  for my $path (qw{/usr/lib/sendmail /usr/sbin/sendmail /usr/bin/sendmail}) {
    if (-x $path) {
      $SENDMAIL = $path;
      last;
    }
  }
}


# Do all the initialization that needs to be done after the
# command-line has been parsed.  Specifically, set the public path
# variables and ensure $WorkDir exists.
sub finishInit {
  $WorkDir = "$Home/.email-intestine"
    unless (defined($WorkDir) && $WorkDir);

  if (!-d $WorkDir) {
    mkdir ($WorkDir, 0700)
      or panic ("Unable to create '$WorkDir'");
  }

  $HOME = $Home;
  $USER = $User;
}



# Parse the command-line arguments.  These are all debug options.
sub parseArgs {
  my $help;
  GetOptions ('home=s'          => \$Home,
              'user=s'          => \$User,
              'workdir=s'       => \$WorkDir,
              'sendmail=s'      => \$SENDMAIL,
              'keep-crashbox'   => \$KEEP_CRASH,

              'verbose'         => \$Verbose,
              'no-log'          => \$NoLogFile,
              'no-forward'      => \$NoForward,
              'no-pipe'         => \$NoPipe,

              'help'            => \$help,
             ) or panic ("Invalid command-line argument.");
  if ($help) {
    print <<EOF;
$0 [--home=<path>] [--user=<user-name>] [--workdir=<path>]
    [--sendmail=<bin-path>] [--keep-crashbox] [--verbose]
    [--no-log] [--no-forward] [--help]
EOF
;
    exit(0);
  }
}


# Read the incoming message into $MailText and store a copy in the
# crashbox.
sub getMessage {

  $CrashBoxName = "$WorkDir/crashbox-$PID-@{[scalar time()]}";
  open my $crashbox, ">$CrashBoxName"
    or do {
      $CrashBoxName = undef;
      panic ("Unable to open crashbox.");
    };

  # Slurp the message into $MailText
  do {local $/; $MailText = <STDIN>};

  print {$crashbox} $MailText
    or logm ("WARNING: unable to save to crashbox. Message may be lost!");

  close ($crashbox);
}



# Parses $MailText into the global state
sub digestMessage {
  local $_;

  my $headers = "";
  my $bodytext = "";

  my $head = 1;
  for (split (/\n/, $MailText)) {
    $_ .= "\n";

    $head = 0 if /^$/;
    if($head == 1) {
      $headers .= $_ unless /^From /;
    } else { # body
      $bodytext .= $_;
    }
  }

  $headers =~ s/\n\s+/ /g; #fix continuation lines

  # Extract and normalize the case of all headers.
  %HDRS = ();
  for my $line (split(/\n/, $headers)) {
    chomp $line;

    $line =~ m{\A ([^:]+): \s* (.*) \z}gmx
      or do {
        logm ("Ignoring malformed header line: '$line'");
        next;
      };

    my ($key, $value) = ($1, $2);
    $key =~ s/(\w)(\w+)/\u$1\L$2\E/g;   # Normalize case

    $HDRS{$key} = $value;
  }

  # parse out From: header for use in the 'From ' separator
  $HDRS{From} =~ m/([^ ]+@[^ ]+) \(.*\)|[^<][<](.*@.*)[>]|([^ ]+@[^ ]+)/
    and $EmailFrom = $+;

  # Create global versions
  $HEADERS = $headers;
  $BODY = $bodytext;
}


# Locks the filehandle $mbox or panics if it can't.
sub mlock {
  my ($mbox) = @_;

  flock($mbox, LOCK_EX)
    or panic("Couldn't lock file: $!");

  seek ($mbox, 0, SEEK_END)
    or panic ("Unable to seek to the end of mailbox file: $!");
}

# Unlocks the filehandle $mbox or panics on failure.
sub munlock {
  my ($mbox) = @_;

  flock ($mbox, LOCK_UN)
    or panic ("Unable to unlock mailbox file: $!");
}




# Append the current message to $mailbox.  Panics on failure; exits
# normally on success unless $keepGoing is true.
sub outputMessage {
  my ($mailbox, $keepGoing) = @_;

  # Check to see if the body's been edited any
  logm("Saving to mailbox $mailbox.");

  open my $mbox,">>$mailbox" or
    panic("Couldn't open mailbox $mailbox: $!");

  mlock($mbox);
  print {$mbox} "From $EmailFrom ". scalar localtime(time),"\n",
    $MailText, "\n"
      or panic ("Error writing mailfile: $!");
  munlock($mbox);

  close $mbox;

  return if $keepGoing;
  finish();
}




#   forwardMessage sends the message to the email address given in the
#   first parameter, by piping it through sendmail.  On success, it
#   exits successfully unless $keepGoing is true.  If sendmail fails
#   to run for whatever reason, it panics.
#
#   forwardMessage assumes a mail-transport agent with
#   approximately the same interface as sendmail, i.e. is run as
#   "MTA <address>", and the content of the message is fed in on
#   standard input.  This *seems* to be reasonable, but probably
#   turns out actually not to be.  All MTAs are different,
#   though--the best you can hope for is something with some sort
#   of sendmail emulator (zmailer, for instance, has a binary
#   called "sendmail" which act the same way that real sendmail
#   does when you invoke it as a user).
sub forwardMessage {
    my ($forwardTo, $keepGoing) = @_;

    # Do nothing if forwarding is disabled.
    if ($NoForward) {
      logm ("Forwarding is disabled by command-line option.");
      finish() unless $keepGoing;
      return;
    }

    logm("Attempting to forward message to '$forwardTo'");
    open my $sendmailfh,"|$SENDMAIL $forwardTo"
      or panic("Couldn't run '$SENDMAIL': $!");

    print {$sendmailfh} $MailText
      or panic ("Error passing message to $SENDMAIL: $!");

    close $sendmailfh;
    logm("Forwarding succeeded.") if $Verbose;;

    return if $keepGoing;
    finish();
}


# Filter message through command $pipeCmd.  Panics on failure; exits
# gracefully on success unless $keepGoing is true.
sub pipeMessage {
    my ($pipeCmd, $keepGoing) = @_;

    # Do nothing if forwarding is disabled.
    if ($NoPipe) {
      logm ("Piping is disabled by command-line option.");
      finish() unless $keepGoing;
      return;
    }

    # Otherwise, pass the message to sendmail
    logm("Piping message through $pipeCmd");
    open my $pipe, "|$pipeCmd"
      or panic("Couldn't run $pipeCmd: $!");

    print {$pipe} $MailText
      or panic ("Error sending text through $pipeCmd: $!");

    close $pipe;
    logm("'$pipeCmd' completed.") if $Verbose;

    return if $keepGoing;
    finish();
}


# Run the message through a filter program and return the status value
sub filterThrough {
  my ($prog) = @_;

  logm("Filtering through '$prog'");

  open my $filter, "|$prog"
    or do {
      logm ("Unable to execute $prog.");
      return -1;
    };

  print {$filter} $MailText
    or panic ("Error filtering message through '$prog': $!");

  close $filter;

  my $stat = $? >> 8;
  logm ("Exit status is $stat");
  return $stat;
}


# Exit normally.  Deletes the crash box (unless that was disabled) and
# creates a log entry before quitting with exit status 0.
sub finish {
  if (!$KEEP_CRASH) {
    unlink($CrashBoxName)
      if defined($CrashBoxName) && -f $CrashBoxName;
  } else {
    logm ("Keeping crash box.");
  }
  logm("Done.") if $Verbose;

  exit(0);
}

# Log $message to the logfile and exit with an error code of 75.
# (This is apparently what sendmail expects when a delivery agent
# fails).
sub panic {
    my ($message) = @_;

    # Sendmail expects things to exit with 75 on failure.
    logm($message);
    exit 75;
}


# Appends $msg to the logfile (named 'logfile' in $WorkDir.  Creates
# the file if it does not exist and sets its permissions to 0600.
# Note: It currently does not lock the logfile on the thory that a)
# the chances of it getting mangled are minimal, b) locking is more
# likely to shoot me in the foot than solve anything and c) if there
# *is* a concurrency problem, the resulting file is probably still
# deciperable.  If $NoLogFile is true, the message goes to stderr
# instead.
sub logm {
  my ($msg) = @_;
  chomp $msg;

  if ($NoLogFile || !defined($WorkDir) || ! -d $WorkDir) {
    print STDERR "$msg\n";
    return;
  }

  my $logpath = "$WorkDir/logfile";
  my $create = ! -f $logpath;

  open my $mbox, ">>$logpath"
    or do {
      print STDERR "Couldn't open logfile $logpath: $!";
      print STDERR "LOG MESSAGE: $msg\n";
      return;
    };

  # For now, we tolerate concurrency clashes on the logfile.

  print {$mbox} scalar(localtime()), ": $msg\n";

  close ($mbox);

  # Make $logpath inaccessible to all other users. (There is a very
  # minor race condition here.)
  chmod 0600, $logpath
    if $create;

  return;
}



# And do the setup...
INIT{ init(); }
1;


__END__


=head1 NAME

Email::Intestine - A module for creating email filters.

=head1 SYNOPSIS

  use Email::Intestine;

  logm ("Message from $HDRS{From}, subject '$HDRS{Subject}'");

  forwardMessage('me@myphone.net', 1)
    if $HDRS{From} =~ /myworkplace.com/;

  outputMessage("$HOME/Mail/spam")
    if !filterThrough("/usr/bin/bogofilter");

  outputMessage("$HOME/Mail/inbox");

=head1 DESCRIPTION

B<Email::Intestine> performs most of the heavy lifting when creating a
simple email filter.  It is similar to B<Email::Filter> on CPAN but
does not require any extra Perl modules to work.  You can just drop it
somewhere in your home directory and as long as scripts that use it
can find it, it will just work.

This is really handy in environments where it's difficult to install
new Perl modules.

=head2 Overview

When a script first imports C<Email::Intestine>, the module
immediately:

=over

=item 1) Parses the script's argument list.

=item 2) Reads STDIN and parses the contents as an email message.

=item 3) Writes the message to an emergency backup file.

=back

In addition to this, Email::Intestine exports a number of variables
and functions.  The variables (mostly) contain various parsed parts of
the message while the functions are used to control what happens to it
next.

The calling script can save the message to a folder, forward it to
another email address or run it through an external program.  Most of
these operations also cause the script to exit gracefully if
successful, although this can be overridden by giving it a Perl true
value as the second argument.

A graceful deletes the emergency backup.  The script can also
explicitly exit gracefully by calling C<finish()>.


=head2 The Work Directory

Email::Intestine creates a directory in the user's home directory
named C<.email-intestine>.  The emergency backup file is created
here.  The file's name begins with C<crashbox-> followed by text to
keep the name unique.

In addition, there is a log file here, unsurprisingly named
C<logfile>.  Items are appended to it either explicitly via the
C<logm> function or by the module's internals.

The user's home directory is taken from the C<HOME> environment
variable.  This may be overridden with the C<--home> command-line
option.  If this fails because C<HOME> is unset and there is no
command-line option, it falls back to the password file entry.  If
that fails too, it gives up and exits with a message.

(The same thing happens when determining the username for the C<$USER>
variable.)

The C<--workspace> command-line argument can also be used to choose an
entirely different work directory.

=head2 The Command Line

Email::Intestine uses Getopt::Long to parse the command line.  The
following options are allowed:

=over

=item --home I<dir>

Sets the home directory, overriding the environment and password
entry.

=item --user I<uname>

Sets the username exported in the $USER variable.

=item --workdir I<dir>

Sets the work directory.

=item --sendmail I<path>

Sets the path to a sendmail-compatible MTA.  See '$SENDMAIL' below for
more details.

=item --keep-crashbox

If set, does not delete the emergency backup on exit.  Note that the
script can override this by setting the $KEEP_CRASH variable.

=item --verbose

Enables more log messages.

=item --no-log

Disables logging.  In this case, the log messages go to STDERR
instead.

=item --no-forward

Disables forwarding.  C<forwardMessage()> reports that forwarding is
disabled and exits or resumes as requested.  This is used for testing
and debugging.

=item --no-pipe

Disables piping to another program.  Only C<pipeMessage()> is
affected.  If set, C<pipeMessage> reports that piping is disabled and
exits if requested.  This is used for testing and debugging.

=item --help

Prints a short, informative message and exits.

=back

=head2 Exported Variables

The following variables are exported by C<Email::Intestine>.  Note
that unless otherwise stated, changing the value of one of these
variables has no effect on the module.  For example, this

    $HDRS{Subject} = "[SPAM]$HDRS{Subject}";  # DOESN'T WORK!

B<will not> change the subject line of the message when it's finally
forward or appended to a mailbox file.

=over

=item $HOME

The home directory of the recipient of this message.  See above for
how it is set.

=item $USER

The username of the recipient of this message.  It is determined in
the same way C<$HOME> is.

=item %HDRS

A hash associating header names with their values in the incoming
message.  Header names' capitalization is normalized to a capital
letter followed by all lower-case letters (e.g. "From", "To",
"Subject").

Note that since this is a hash, only one copy of each header is given
here.  If a header is repeated, only the last instance is kept here.

=item $HEADERS

A string containing the text of the incoming messages' entire header block.

=item $BODY

A string containing the entire body of the incoming message.

=item $SENDMAIL (settable)

The path to the C<sendmail> program used by C<forwardMessage()>.
Setting this B<will> select the program run by C<forwardMessage()>.

Note that the string is interpolated by the shell, so it may contain
arguments.

The program does not have to be the real C<sendmail> MTA but it needs
to behave like it.  Specifically, it must be run as "$SENDMAIL
I<address>" and accept the message on STDIN.  Fortunately, many MTAs
provide a compatible 'sendmail' program.

=item $KEEP_CRASH (settable)

If true, the emergency backup will not be deleted by C<finish()>.
Setting this B<will> change whether the emergency backup is deleted.

=back

=head2 Exported Functions

Email::Intestine exports the following functions:

=over

=item outputMessage($mailbox, $dontQuit)

Appends the message to the file at $mailbox, creating it if it doesn't
exist.  If it can't open the file for writing, panics and exits with
an error message, leaving the emergency backup alone.

If C<$dontQuit> is not given or is false, C<outputMessage()> quits
gracefully afterward.

=item forwardMessage($address, $dontQuit)

Forwards the message to the email address in C<$address> using the MTA
set in C<$SENDMAIL>.  On error, outputs an error message and exits.

If C<$dontQuit> is not given or is false, it then exits gracefully.

Note that writing all of the message to the STDIN of the C<$SENDMAIL>
program without an error is considered a success and will (possibly)
be followed by a graceful shutdown and deletion of the emergency
backup, even if C<$SENDMAIL> immediately crashes afterward.

=item pipeMessage($command, $dontQuit)

Hands the message off to the program given by C<$command>.
C<$command> must be a command-line (i.e. may contain arguments) and
the program it invokes must read the message in its STDIN.  If there
is an error, the filter exits immediately with an error message and
does not delete the emergency backup.

Note that the exit status of the command is ignored.  This could be
considered a bug.

If C<$dontQuit> is absent or false, C<pipeMessage> then exits
gracefully.

=item filterThrough($command)

Runs C<$command> and writes the message body to its STDIN, waits for
it to exit and returns its exit status.  C<$command> has the same
requirements as in C<pipeMessage()>.

=item finish()

Deletes the emergency backup, then exits the filter gracefully with
exit status 0.

=item logm($message)

Appends C<$message> to the logfile with a prepended timestamp.

Note that unlike mailboxes, the logfile is not locked when text is
appended.  This was done so that a filter would never hang during a
call to C<panic()>.

It is thus possible in theory to corrupt the logfile but in practice, it rarely
happens and the results are usually decypherable when it does.

=item panic($message)

Appends C<$message> to the log, then exits immediately with a status of
75 (which Sendmail apparently expects on error).

=back

=head1 AUTHOR

Chris Reuter, E<lt>chris@blit.ca<gt>

This is distantly derived from an early version of Gurgitate Mail
written by Dave Brown back in the nineties.

=head1 COPYRIGHT AND LICENSE

Copyright (C) 1996-2012 by Chris Reuter

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.14.2 or,
at your option, any later version of Perl 5 you may have available.

=cut


# Copyright © 2008-2009 Raphaël Hertzog <hertzog@debian.org>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

package Dpkg::Source::Package::V1;

use strict;
use warnings;

use base 'Dpkg::Source::Package';

use Dpkg;
use Dpkg::Gettext;
use Dpkg::ErrorHandling;
use Dpkg::Compression;
use Dpkg::Source::Archive;
use Dpkg::Source::Patch;
use Dpkg::Exit;
use Dpkg::Source::Functions qw(erasedir);
use Dpkg::Source::Package::V3::native;

use POSIX;
use File::Basename;
use File::Temp qw(tempfile);
use File::Spec;

our $CURRENT_MINOR_VERSION = "0";

sub init_options {
    my ($self) = @_;
    # Don't call $self->SUPER::init_options() on purpose, V1.0 has no
    # ignore by default
    $self->{'options'}{'sourcestyle'} ||= 'X';
    $self->{'options'}{'skip_debianization'} ||= 0;
}

sub parse_cmdline_option {
    my ($self, $opt) = @_;
    my $o = $self->{'options'};
    if ($opt =~ m/^-s([akpursnAKPUR])$/) {
        warning(_g("-s%s option overrides earlier -s%s option"), $1,
                $o->{'sourcestyle'}) if $o->{'sourcestyle'} ne 'X';
        $o->{'sourcestyle'} = $1;
        $o->{'copy_orig_tarballs'} = 0 if $1 eq 'n'; # Extract option -sn
        return 1;
    } elsif ($opt =~ m/^--skip-debianization$/) {
        $o->{'skip_debianization'} = 1;
        return 1;
    }
    return 0;
}

sub do_extract {
    my ($self, $newdirectory) = @_;
    my $sourcestyle = $self->{'options'}{'sourcestyle'};
    my $fields = $self->{'fields'};

    $sourcestyle =~ y/X/p/;
    $sourcestyle =~ m/[pun]/ ||
	usageerr(_g("source handling style -s%s not allowed with -x"),
	         $sourcestyle);

    my $dscdir = $self->{'basedir'};

    my $basename = $self->get_basename();
    my $basenamerev = $self->get_basename(1);

    # V1.0 only supports gzip compression
    my ($tarfile, $difffile);
    foreach my $file ($self->get_files()) {
	if ($file =~ /^(?:\Q$basename\E\.orig|\Q$basenamerev\E)\.tar\.gz$/) {
            error(_g("multiple tarfiles in v1.0 source package")) if $tarfile;
            $tarfile = $file;
	} elsif ($file =~ /^\Q$basenamerev\E\.diff\.gz$/) {
	    $difffile = $file;
	} else {
	    error(_g("unrecognized file for a %s source package: %s"),
                  "v1.0", $file);
	}
    }

    error(_g("no tarfile in Files field")) unless $tarfile;
    my $native = $difffile ? 0 : 1;
    if ($native and ($tarfile =~ /\.orig\.tar\.gz$/)) {
        warning(_g("native package with .orig.tar"));
        $native = 0; # V3::native doesn't handle orig.tar
    }

    if ($native) {
        Dpkg::Source::Package::V3::native::do_extract($self, $newdirectory);
    } else {
        my $expectprefix = $newdirectory;
        $expectprefix .= '.orig';

        erasedir($newdirectory);
        if (-e $expectprefix) {
            rename($expectprefix, "$newdirectory.tmp-keep") ||
                    syserr(_g("unable to rename `%s' to `%s'"), $expectprefix,
                           "$newdirectory.tmp-keep");
        }

        info(_g("unpacking %s"), $tarfile);
        my $tar = Dpkg::Source::Archive->new(filename => "$dscdir$tarfile");
        $tar->extract($expectprefix);

        if ($sourcestyle =~ /u/) {
            # -su: keep .orig directory unpacked
            if (-e "$newdirectory.tmp-keep") {
                error(_g("unable to keep orig directory (already exists)"));
            }
            system('cp', '-ar', '--', $expectprefix, "$newdirectory.tmp-keep");
            subprocerr("cp $expectprefix to $newdirectory.tmp-keep") if $?;
        }

	rename($expectprefix, $newdirectory) ||
	    syserr(_g("failed to rename newly-extracted %s to %s"),
	           $expectprefix, $newdirectory);

	# rename the copied .orig directory
	if (-e "$newdirectory.tmp-keep") {
	    rename("$newdirectory.tmp-keep", $expectprefix) ||
                    syserr(_g("failed to rename saved %s to %s"),
	                   "$newdirectory.tmp-keep", $expectprefix);
        }
    }

    if ($difffile and not $self->{'options'}{'skip_debianization'}) {
        my $patch = "$dscdir$difffile";
	info(_g("applying %s"), $difffile);
	my $patch_obj = Dpkg::Source::Patch->new(filename => $patch);
	my $analysis = $patch_obj->apply($newdirectory, force_timestamp => 1,
                                         timestamp => time());
	my @files = grep { ! m{^[^/]+/debian/} }
		    sort keys %{$analysis->{'filepatched'}};
	info(_g("upstream files that have been modified: %s"),
	     "\n " . join("\n ", @files)) if scalar @files;
    }
}

sub can_build {
    my ($self, $dir) = @_;
    # As long as we can use gzip, we can do it as we have
    # native packages as fallback
    return ($self->{'options'}{'compression'} eq "gzip",
            _g("only supports gzip compression"));
}

sub do_build {
    my ($self, $dir) = @_;
    my $sourcestyle = $self->{'options'}{'sourcestyle'};
    my @argv = @{$self->{'options'}{'ARGV'}};
    my @tar_ignore = map { "--exclude=$_" } @{$self->{'options'}{'tar_ignore'}};
    my $diff_ignore_regexp = $self->{'options'}{'diff_ignore_regexp'};

    if (scalar(@argv) > 1) {
        usageerr(_g("-b takes at most a directory and an orig source ".
                    "argument (with v1.0 source package)"));
    }

    $sourcestyle =~ y/X/A/;
    unless ($sourcestyle =~ m/[akpursnAKPUR]/) {
        usageerr(_g("source handling style -s%s not allowed with -b"),
                 $sourcestyle);
    }

    my $sourcepackage = $self->{'fields'}{'Source'};
    my $basenamerev = $self->get_basename(1);
    my $basename = $self->get_basename();
    my $basedirname = $basename;
    $basedirname =~ s/_/-/;

    # Try to find a .orig tarball for the package
    my $origdir = "$dir.orig";
    my $origtargz = $self->get_basename() . ".orig.tar.gz";
    if (-e $origtargz) {
        unless (-f $origtargz) {
            error(_g("packed orig `%s' exists but is not a plain file"), $origtargz);
        }
    } else {
        $origtargz = undef;
    }

    if (@argv) {
	# We have a second-argument <orig-dir> or <orig-targz>, check what it
	# is to decide the mode to use
        my $origarg = shift(@argv);
        if (length($origarg)) {
            stat($origarg) ||
                syserr(_g("cannot stat orig argument %s"), $origarg);
            if (-d _) {
                $origdir = File::Spec->catdir($origarg);

                $sourcestyle =~ y/aA/rR/;
                unless ($sourcestyle =~ m/[ursURS]/) {
                    error(_g("orig argument is unpacked but source handling " .
                             "style -s%s calls for packed (.orig.tar.<ext>)"),
                          $sourcestyle);
                }
            } elsif (-f _) {
                $origtargz = $origarg;
                $sourcestyle =~ y/aA/pP/;
                unless ($sourcestyle =~ m/[kpsKPS]/) {
                    error(_g("orig argument is packed but source handling " .
                             "style -s%s calls for unpacked (.orig/)"),
                          $sourcestyle);
                }
            } else {
                error(_g("orig argument %s is not a plain file or directory"),
                      $origarg);
            }
        } else {
            $sourcestyle =~ y/aA/nn/;
            $sourcestyle =~ m/n/ ||
                error(_g("orig argument is empty (means no orig, no diff) " .
                         "but source handling style -s%s wants something"),
                      $sourcestyle);
        }
    } elsif ($sourcestyle =~ m/[aA]/) {
	# We have no explicit <orig-dir> or <orig-targz>, try to use
	# a .orig tarball first, then a .orig directory and fall back to
	# creating a native .tar.gz
	if ($origtargz) {
	    $sourcestyle =~ y/aA/pP/; # .orig.tar.<ext>
	} else {
	    if (stat($origdir)) {
		unless (-d _) {
                    error(_g("unpacked orig `%s' exists but is not a directory"),
		          $origdir);
                }
		$sourcestyle =~ y/aA/rR/; # .orig directory
	    } elsif ($! != ENOENT) {
		syserr(_g("unable to stat putative unpacked orig `%s'"), $origdir);
	    } else {
		$sourcestyle =~ y/aA/nn/; # Native tar.gz
	    }
	}
    }

    my ($dirname, $dirbase) = fileparse($dir);
    if ($dirname ne $basedirname) {
	warning(_g("source directory '%s' is not <sourcepackage>" .
	           "-<upstreamversion> '%s'"), $dir, $basedirname);
    }

    my ($tarname, $tardirname, $tardirbase, $origdirname);
    if ($sourcestyle ne 'n') {
	my ($origdirname, $origdirbase) = fileparse($origdir);

        if ($origdirname ne "$basedirname.orig") {
            warning(_g(".orig directory name %s is not <package>" .
	               "-<upstreamversion> (wanted %s)"),
	            $origdirname, "$basedirname.orig");
        }
        $tardirbase = $origdirbase;
        $tardirname = $origdirname;

	$tarname = $origtargz || "$basename.orig.tar.gz";
	unless ($tarname =~ /\Q$basename\E\.orig\.tar\.gz/) {
	    warning(_g(".orig.tar name %s is not <package>_<upstreamversion>" .
	               ".orig.tar (wanted %s)"),
	            $tarname, "$basename.orig.tar.gz");
	}
    }

    if ($sourcestyle eq "n") {
        $self->{'options'}{'ARGV'} = []; # ensure we have no error
        Dpkg::Source::Package::V3::native::do_build($self, $dir);
    } elsif ($sourcestyle =~ m/[nurUR]/) {
        if (stat($tarname)) {
            unless ($sourcestyle =~ m/[nUR]/) {
		error(_g("tarfile `%s' already exists, not overwriting, " .
		         "giving up; use -sU or -sR to override"), $tarname);
            }
        } elsif ($! != ENOENT) {
	    syserr(_g("unable to check for existence of `%s'"), $tarname);
        }

	info(_g("building %s in %s"),
	     $sourcepackage, $tarname);

	my ($ntfh, $newtar) = tempfile("$tarname.new.XXXXXX",
				       DIR => getcwd(), UNLINK => 0);
	my $tar = Dpkg::Source::Archive->new(filename => $newtar,
		    compression => get_compression_from_filename($tarname),
		    compression_level => $self->{'options'}{'comp_level'});
	$tar->create(options => \@tar_ignore, 'chdir' => $tardirbase);
	$tar->add_directory($tardirname);
	$tar->finish();
        rename($newtar, $tarname) ||
            syserr(_g("unable to rename `%s' (newly created) to `%s'"),
                   $newtar, $tarname);
	chmod(0666 &~ umask(), $tarname) ||
	    syserr(_g("unable to change permission of `%s'"), $tarname);
    } else {
	info(_g("building %s using existing %s"),
	     $sourcepackage, $tarname);
    }

    $self->add_file($tarname) if $tarname;

    if ($sourcestyle =~ m/[kpKP]/) {
        if (stat($origdir)) {
            unless ($sourcestyle =~ m/[KP]/) {
                error(_g("orig dir `%s' already exists, not overwriting, ".
                         "giving up; use -sA, -sK or -sP to override"),
                      $origdir);
            }
	    push @Dpkg::Exit::handlers, sub { erasedir($origdir) };
            erasedir($origdir);
	    pop @Dpkg::Exit::handlers;
        } elsif ($! != ENOENT) {
            syserr(_g("unable to check for existence of orig dir `%s'"),
                    $origdir);
        }

	my $tar = Dpkg::Source::Archive->new(filename => $origtargz);
	$tar->extract($origdir);
    }

    my $ur; # Unrepresentable changes
    if ($sourcestyle =~ m/[kpursKPUR]/) {
	my $diffname = "$basenamerev.diff.gz";
	info(_g("building %s in %s"),
	     $sourcepackage, $diffname);
	my ($ndfh, $newdiffgz) = tempfile("$diffname.new.XXXXXX",
					DIR => getcwd(), UNLINK => 0);
        push @Dpkg::Exit::handlers, sub { unlink($newdiffgz) };
        my $diff = Dpkg::Source::Patch->new(filename => $newdiffgz,
                                            compression => "gzip");
        $diff->create();
        $diff->add_diff_directory($origdir, $dir,
                basedirname => $basedirname,
                diff_ignore_regexp => $diff_ignore_regexp,
                options => []); # Force empty set of options to drop the
                                # default -p option
        $diff->finish() || $ur++;
        pop @Dpkg::Exit::handlers;

	my $analysis = $diff->analyze($origdir);
	my @files = grep { ! m{^debian/} } map { s{^[^/]+/+}{}; $_ }
		    sort keys %{$analysis->{'filepatched'}};
	if (scalar @files) {
	    warning(_g("the diff modifies the following upstream files: %s"),
	            "\n " . join("\n ", @files));
	    info(_g("use the '3.0 (quilt)' format to have separate and " .
	            "documented changes to upstream files, see dpkg-source(1)"));
	}

	rename($newdiffgz, $diffname) ||
	    syserr(_g("unable to rename `%s' (newly created) to `%s'"),
	           $newdiffgz, $diffname);
	chmod(0666 &~ umask(), $diffname) ||
	    syserr(_g("unable to change permission of `%s'"), $diffname);

	$self->add_file($diffname);
    }

    if ($sourcestyle =~ m/[prPR]/) {
        erasedir($origdir);
    }

    if ($ur) {
        printf(STDERR _g("%s: unrepresentable changes to source")."\n",
               $progname);
        exit(1);
    }
}

# vim: set et sw=4 ts=8
1;
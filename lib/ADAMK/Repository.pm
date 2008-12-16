package ADAMK::Repository;

=pod

=head1 NAME

ADAMK::Repository - Repository object model for ADAMK's svn repository

=cut

use 5.008;
use strict;
use warnings;
use Carp                  'croak';
use File::Spec            ();
use File::pushd           ();
use File::Find::Rule      ();
use File::Find::Rule::VCS ();
use IPC::Run3             ();
use IPC::System::Simple   ();
use Params::Util          qw{ _STRING _CODE };
use CPAN::Version         ();
use ADAMK::Release        ();
use ADAMK::Distribution   ();

use vars qw{$VERSION};
BEGIN {
	$VERSION = '0.03';
}

use Object::Tiny qw{
	root
};





#####################################################################
# Constructor

sub new {
	my $class = shift;
	my $self  = $class->SUPER::new(@_);

	# Check params
	unless ( -d $self->svn_root($self->root) ) {
		croak("Missing or invalid SVN root directory");
	}
	if ( $self->{trace} and not _CODE($self->{trace}) ) {
		$self->{trace} = sub { print @_ };
	}
	$self->{preload} = !! $self->{preload};

	# Preload if we are into that sort of thing
	$self->trace("Preloading distributions...");
	$self->{distributions} = [ $self->distributions ];
	$self->trace("Preloading releases...");
	$self->{releases} = [ $self->releases ];

	return $self;
}

sub dir {
	File::Spec->catdir( shift->root, @_ );
}

sub file {
	File::Spec->catfile( shift->root, @_ );
}

sub trace {
	$_[0]->{trace}->( @_[1..$#_] ) if $_[0]->{trace};
}





#####################################################################
# Distributions

sub distribution_dir {
	$_[0]->dir('trunk');
}

sub distribution_directories {
	my $self   = shift;
	local *DIR;
	opendir( DIR, $self->distribution_dir ) or die("opendir: $!");
	my @files = readdir(DIR);
	closedir(DIR) or die("closedir: $!");
	return grep { /^[A-Z-]+$/i } @files;
}

sub distributions {
	my $self = shift;

	# Use cache if preloaded
	if ( $self->{distributions} ) {
		return @{$self->{distributions}};
	}

	my @directories   = $self->distribution_directories;
	my @distributions = ();
	foreach my $directory ( @directories ) {
		my $object = ADAMK::Distribution->new(
			name         => $directory,
			directory    => 'trunk',
			path         => File::Spec->catfile(
				$self->distribution_dir, $directory,
			),
			repository   => $self,
			distribution => $directory,
		);
		push @distributions, $object;
	}
	return @distributions;
}

sub distribution {
	my @distribution = grep {
		$_->name eq $_[1]
	} $_[0]->distributions;
	return $distribution[0];
}





#####################################################################
# Releases

sub release_dir {
	$_[0]->dir('releases');
}

sub release_files {
	my $self   = shift;
	local *DIR;
	opendir( DIR, $self->release_dir ) or die("opendir: $!");
	my @files = readdir(DIR);
	closedir(DIR) or die("closedir: $!");
	return grep { /^([\w-]+?)-(\d[\d_\.]*[a-z]?)\.(?:tar\.gz|zip)$/ } @files;
}

sub releases {
	my $self = shift;

	# Use cache if preloaded
	if ( $self->{releases} ) {
		return @{$self->{releases}};
	}

	my @files    = $self->release_files;
	my @releases = ();
	foreach my $file ( @files ) {
		unless ( $file =~ /^([\w-]+?)-(\d[\d_\.]*[a-z]?)\.(?:tar\.gz|zip)$/ ) {
			croak("Unexpected file name '$file'");
		}
		my $distribution = "$1";
		my $version      = "$2";
		my $object = ADAMK::Release->new(
			file         => $file,
			directory    => 'releases',
			path         => File::Spec->catfile(
				$self->release_dir, $file,
			),
			repository   => $self,
			distribution => $distribution,
			version      => $version,
		);
		push @releases, $object;
	}

	return @releases;
}

sub distribution_releases {
	my $self         = shift;
	my $distribution = shift;

	# Filter by distribution and sort by version
	my @releases = sort {
		CPAN::Version->vcmp( $b, $a )
	} grep {
		$_->distribution eq $distribution
	} $self->releases;

	return @releases;
}

sub latest_release {
	my $self     = shift;
	my @releases = sort {
		CPAN::Version->vcmp( $b->version, $a->version )
	} $self->distribution_releases(shift);
	return $releases[0];
}





#####################################################################
# Comparison

sub araxis_compare_bin {
	return 'C:\\Program Files\\Araxis\\Araxis Merge\\Compare.exe';
}

sub araxis_compare {
	my $self  = shift;
	my $left  = shift;
	my $right = shift;
	unless ( -d $left ) {
		croak("Left directory does not exist");
	}
	unless ( -d $right ) {
		croak("Right directory does not exist");
	}
	IPC::Run3::run3( [
		$self->araxis_compare_bin,
		$left,
		$right,
	] );
}

sub compare_latest {
	my $self         = shift;
	my $name         = shift;
	my $distribution = $self->distribution($name);
	my $release      = $self->latest_release($name);
	unless ( $distribution ) {
		croak("Failed to find distribution $name");
	}
	unless ( $release ) {
		croak("Failed to find latest release for $name");
	}

	# Launch the comparison
	$self->araxis_compare(
		$release->extract,
		$distribution->path,
	);	
}





#####################################################################
# Simple SVN Interfaces

sub svn_command {
	my $self = shift;
	my $root = File::pushd::pushd( $self->root );
	my $cmd  = join( ' ', 'svn', @_ );
	$self->trace("> $cmd\n");
	my @rv   = `$cmd`;
	chomp(@rv);
	return @rv;
}

sub svn_version {
	my $self = shift;
	die "CODE INCOMPLETE";
}

sub svn_info {
	my $self = shift;
	my @info = $self->svn_command( 'info', @_ );
	my %hash = map {
		/^([^:]+)\s*:\s*(.*)$/;
		my $key   = "$1";
		my $value = "$2";
		$key =~ s/\s+//g;
		( $key, $value );
	} grep { length $_ } @info;
	return \%hash;
}

sub svn_root {
	my $self = shift;
	my $root  = shift;
	unless ( defined _STRING($root) ) {
		return undef;
	}
	unless ( -d $root ) {
		return undef;
	}
	unless ( -d File::Spec->catdir($root, '.svn') ) {
		return undef;
	}
	return $root;
}

sub svn_dir {
	my $self = shift;
	my $dir  = shift;
	unless ( defined _STRING($dir) ) {
		return undef;
	}
	my $path = File::Spec->catfile( $self->root, $dir );
	unless ( -d $path ) {
		return undef;
	}
	unless ( -d File::Spec->catdir($path, '.svn') ) {
		return undef;
	}
	return $dir;
}

sub svn_file {
	my $self = shift;
	my $file = shift;
	unless ( defined _STRING($file) ) {
		return undef;
	}
	my $path = File::Spec->catfile( $self->root, $file );
	unless ( -f $path ) {
		return undef;
	}
	my ($v, $d, $f) = File::Spec->splitpath($path);
	my $svn = File::Spec->catpath(
		$v,
		File::Spec->catdir($d, '.svn', 'text-base'),
		"$f.svn-base",
	);
	unless ( -f $svn ) {
		return undef;
	}
	return $file;
}

sub svn_dir_info {
	my $self = shift;
	my $dir  = $self->svn_dir(shift);
	unless ( defined $dir ) {
		return undef;
	}
	my $hash = $self->svn_info($dir);
	$hash->{Directory} = $dir;
	return $hash;
}

sub svn_file_info {
	my $self = shift;
	my $file = $self->svn_file(shift);
	unless ( defined $file ) {
		return undef;
	}
	my $hash = $self->svn_info($file);
	return $hash;
}

1;

=pod

=head1 SUPPORT

No support is available for this module

=head1 AUTHOR

Adam Kennedy E<lt>adamk@cpan.orgE<gt>

=head1 COPYRIGHT

Copyright 2008 Adam Kennedy.

This program is free software; you can redistribute
it and/or modify it under the same terms as Perl itself.

The full text of the license can be found in the
LICENSE file included with this module.

=cut

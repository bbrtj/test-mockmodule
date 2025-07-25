package Test::MockModule;
use warnings;
use strict qw/subs vars/;
use vars qw/$VERSION/;
use Scalar::Util qw/reftype weaken/;
use Carp;
use SUPER;
# This is now auto-updated at release time by the github action
$VERSION = 'DEVELOP';

sub import {
    my ( $class, @args ) = @_;

    # default if no args
    $^H{'Test::MockModule/STRICT_MODE'} = 0;

    foreach my $arg (@args) {
        if ( $arg eq 'strict' ) {
            $^H{'Test::MockModule/STRICT_MODE'} = 1;
        } elsif ( $arg eq 'nostrict' ) {
            $^H{'Test::MockModule/STRICT_MODE'} = 0;
        } else {
            carp "Test::MockModule unknown import option '$arg'";
        }
    }
    return;
}

sub _strict_mode {
    my $depth = 0;
    while(my @fields = caller($depth++)) {
        my $hints = $fields[10];
        if($hints && grep { /^Test::MockModule\// } keys %{$hints}) {
            return $hints->{'Test::MockModule/STRICT_MODE'};
        }
    }
    return 0;
}

my %mocked;
sub new {
	my ($class, $package, %args) = @_;
	if ($package && (my $existing = $mocked{$package})) {
		return $existing;
	}

	croak "Cannot mock $package" if $package && $class && $package eq $class;
	unless (_valid_package($package)) {
		$package = 'undef' unless defined $package;
		croak "Invalid package name $package";
	}

	unless ($package eq "CORE::GLOBAL" || $package eq 'main' || $args{no_auto} || ${"$package\::VERSION"}) {
		(my $load_package = "$package.pm") =~ s{::}{/}g;
		TRACE("$package is empty, loading $load_package");
		require $load_package;
	}

	TRACE("Creating MockModule object for $package");
	my $self = bless {
		_package => $package,
		_mocked  => {},
	}, $class;
	$mocked{$package} = $self;
	weaken $mocked{$package};
	return $self;
}

sub DESTROY {
	my $self = shift;
	$self->unmock_all;
}

sub get_package {
	my $self = shift;
	return $self->{_package};
}

sub redefine {
	my ($self, @mocks) = (@_);

	my @mocks_copy = @mocks;
	while ( my ($name, $value) = splice @mocks_copy, 0, 2 ) {
		my $sub_name = $self->_full_name($name);
		my $coderef = *{$sub_name}{'CODE'};
		next if 'CODE' eq ref $coderef;

		if ( $sub_name =~ qr{^(.+)::([^:]+)$} ) {
			my ( $pkg, $sub ) = ( $1, $2 );
			next if $pkg->can( $sub );
		}

		if ('CODE' ne ref $coderef) {
			croak "$sub_name does not exist!";
		}
	}

	return $self->_mock(@mocks);
}

sub define {
	my ($self, @mocks) = @_;

	my @mocks_copy = @mocks;
	while ( my ($name, $value) = splice @mocks_copy, 0, 2 ) {
		my $sub_name = $self->_full_name($name);
		my $coderef = *{$sub_name}{'CODE'};

		if ('CODE' eq ref $coderef) {
			croak "$sub_name exists!";
		}
	}

	return $self->_mock(@mocks);
}

sub mock {
	my ($self, @mocks) = @_;

	croak "mock is not allowed in strict mode. Please use define or redefine" if $self->_strict_mode();

	return $self->_mock(@mocks);
}

sub _mock {
	my $self = shift;

	while (my ($name, $value) = splice @_, 0, 2) {
		my $code = sub { };
		if (ref $value && reftype $value eq 'CODE') {
			$code = $value;
		} elsif (defined $value) {
			$code = sub {$value};
		}

		TRACE("$name: $code");
		croak "Invalid subroutine name: $name" unless _valid_subname($name);
		my $sub_name = _full_name($self, $name);
		if (!$self->{_mocked}{$name}) {
			TRACE("Storing existing $sub_name");
			$self->{_mocked}{$name} = 1;
			if (defined &{$sub_name}) {
				$self->{_orig}{$name} = \&$sub_name;
			} else {
				$self->{_orig}{$name} = undef;
			}
		}
		TRACE("Installing mocked $sub_name");
		_replace_sub($sub_name, $code);
	}

	return $self;
}

sub noop {
    my $self = shift;

    croak "noop is not allowed in strict mode. Please use define or redefine" if $self->_strict_mode();

    $self->_mock($_,1) for @_;

    return;
}

sub original {
	my ($self, $name) = @_;

	carp 'Please provide a valid function name' unless _valid_subname($name);

	return carp _full_name($self, $name) . " is not mocked"
		unless $self->{_mocked}{$name};
	return defined $self->{_orig}{$name} ? $self->{_orig}{$name} : $self->{_package}->super($name);
}
sub unmock {
	my ( $self, @names ) = @_;

	carp 'Nothing to unmock' unless @names;
	for my $name (@names) {
		croak "Invalid subroutine name: $name" unless _valid_subname($name);

		my $sub_name = _full_name($self, $name);
		unless ($self->{_mocked}{$name}) {
			carp $sub_name . " was not mocked";
			next;
		}

		TRACE("Restoring original $sub_name");
		_replace_sub($sub_name, $self->{_orig}{$name});
		delete $self->{_mocked}{$name};
		delete $self->{_orig}{$name};
	}
	return $self;
}

sub unmock_all {
	my $self = shift;
	foreach my $name (keys %{$self->{_mocked}}) {
		$self->unmock($name);
	}

	return;
}

sub is_mocked {
	my ($self, $name) = @_;

	return unless _valid_subname($name);

	return $self->{_mocked}{$name};
}

sub _full_name {
	my ($self, $sub_name) = @_;
	return sprintf( "%s::%s", $self->{_package}, $sub_name );
}

sub _valid_package {
	my $name = shift;
	return unless defined $name && length $name;
	return $name =~ /^[a-z_]\w*(?:::\w+)*$/i;
}

sub _valid_subname {
	my $name = shift;
	return unless defined $name && length $name;
	return $name =~ /^[a-z_]\w*$/i;
}

sub _replace_sub {
	my ($sub_name, $coderef) = @_;

    no warnings qw< redefine prototype >;

	if (defined $coderef) {
		*{$sub_name} = $coderef;
	} else {
		TRACE("removing subroutine: $sub_name");
		my ($package, $sub) = $sub_name =~ /(.*::)(.*)/;
		my %symbols = %{$package};

		# save a copy of all non-code slots
		my %slot;
		foreach my $slot_name (qw(ARRAY FORMAT HASH IO SCALAR)) {
			next unless defined $symbols{$sub};
			next unless defined(my $elem = *{$symbols{$sub}}{$slot_name});
			$slot{$slot_name} = $elem;
		}

		# clear the symbol table entry for the subroutine
		undef *$sub_name;

		# restore everything except the code slot
		return unless scalar keys %slot;
		foreach (keys %slot) {
			*$sub_name = $slot{$_};
		}
	}
}

# Log::Trace stubs
sub TRACE {}
sub DUMP  {}

1;

=pod

=head1 NAME

Test::MockModule - Override subroutines in a module for unit testing

=head1 SYNOPSIS

	use Module::Name;
	use Test::MockModule;

	{
		my $module = Test::MockModule->new('Module::Name');
		$module->mock('subroutine', sub { ... });
		Module::Name::subroutine(@args); # mocked

		# Same effect, but this will die() if other_subroutine()
		# doesn't already exist, which is often desirable.
		$module->redefine('other_subroutine', sub { ... });

		# This will die() if another_subroutine() is defined.
		$module->define('another_subroutine', sub { ... });
	}

	{
		# you can also chain new/mock/redefine/define

		Test::MockModule->new('Module::Name')
		->mock( one_subroutine => sub { ... })
		->redefine( other_subroutine => sub { ... } )
		->define( a_new_sub => 1234 );
	}

	Module::Name::subroutine(@args); # original subroutine

	# Working with objects
	use Foo;
	use Test::MockModule;
	{
		my $mock = Test::MockModule->new('Foo');
		$mock->mock(foo => sub { print "Foo!\n"; });

		my $foo = Foo->new();
		$foo->foo(); # prints "Foo!\n"
	}

    # If you want to prevent noop and mock from working, you can
    # load Test::MockModule in strict mode.

    use Test::MockModule qw/strict/;
    my $module = Test::MockModule->new('Module::Name');

    # Redefined the other_subroutine or dies if it's not there.
    $module->redefine('other_subroutine', sub { ... });

    # Dies since you specified you wanted strict mode.
    $module->mock('subroutine', sub { ... });

    # Turn strictness off in this lexical scope
    {
        use Test::MockModule 'nostrict';
        # ->mock() works now
        $module->mock('subroutine', sub { ... });
    }

    # Back in the strict scope, so mock() dies here
    $module->mock('subroutine', sub { ... });

=head1 DESCRIPTION

C<Test::MockModule> lets you temporarily redefine subroutines in other packages
for the purposes of unit testing.

A C<Test::MockModule> object is set up to mock subroutines for a given
module. The object remembers the original subroutine so it can be easily
restored. This happens automatically when all MockModule objects for the given
module go out of scope, or when you C<unmock()> the subroutine.

=head1 STRICT MODE

One of the weaknesses of testing using mocks is that the implementation of the
interface that you are mocking might change, while your mocks get left alone.
You are not now mocking what you thought you were, and your mocks might now be
hiding bugs that will only be spotted in production. To help prevent this you
can load Test::MockModule in 'strict' mode:

    use Test::MockModule qw(strict);

This will disable use of the C<mock()> method, making it a fatal runtime error.
You should instead define mocks using C<redefine()>, which will only mock
things that already exist and die if you try to redefine something that doesn't
exist.

Strictness is lexically scoped, so you can do this in one file:

    use Test::MockModule qw(strict);
    
    ...->redefine(...);

and this in another:

    use Test::MockModule; # the default is nostrict

    ...->mock(...);

You can even mix n match at different places in a single file thus:

    use Test::MockModule qw(strict);
    # here mock() dies

    {
        use Test::MockModule qw(nostrict);
        # here mock() works
    }

    # here mock() goes back to dieing

    use Test::MockModule qw(nostrict);
    # and from here on mock() works again

NB that strictness must be defined at compile-time, and set using C<use>. If
you think you're going to try and be clever by calling Test::MockModule's
C<import()> method at runtime then what happens in undefined, with results
differing from one version of perl to another. What larks!

=head1 METHODS

=over 4

=item new($package[, %options])

Returns an object that will mock subroutines in the specified C<$package>.

If there is no C<$VERSION> defined in C<$package>, the module will be
automatically loaded. You can override this behaviour by setting the C<no_auto>
option:

	my $mock = Test::MockModule->new('Module::Name', no_auto => 1);

=item get_package()

Returns the target package name for the mocked subroutines

=item is_mocked($subroutine)

Returns a boolean value indicating whether or not the subroutine is currently
mocked

=item mock($subroutine =E<gt> \E<amp>coderef)

Temporarily replaces one or more subroutines in the mocked module. A subroutine
can be mocked with a code reference or a scalar. A scalar will be recast as a
subroutine that returns the scalar.

Returns the current C<Test::MockModule> object, so you can chain L<new> with L<mock>.

	my $mock = Test::MockModule->new->(...)->mock(...);

The following statements are equivalent:

	$module->mock(purge => 'purged');
	$module->mock(purge => sub { return 'purged'});

When dealing with references, things behave slightly differently. The following
statements are B<NOT> equivalent:

	# Returns the same arrayref each time, with the localtime() at time of mocking
	$module->mock(updated => [localtime()]);
	# Returns a new arrayref each time, with up-to-date localtime() value
	$module->mock(updated => sub { return [localtime()]});

The following statements are in fact equivalent:

	my $array_ref = [localtime()]
	$module->mock(updated => $array_ref)
	$module->mock(updated => sub { return $array_ref });


However, C<undef> is a special case. If you mock a subroutine with C<undef> it
will install an empty subroutine

	$module->mock(purge => undef);
	$module->mock(purge => sub { });

rather than a subroutine that returns C<undef>:

	$module->mock(purge => sub { undef });

You can call C<mock()> for the same subroutine many times, but when you call
C<unmock()>, the original subroutine is restored (not the last mocked
instance).

B<MOCKING + EXPORT>

If you are trying to mock a subroutine exported from another module, this may
not behave as you initially would expect, since Test::MockModule is only mocking
at the target module, not anything importing that module. If you mock the local
package, or use a fully qualified function name, you will get the behavior you
desire:

	use Test::MockModule;
	use Test::More;
	use POSIX qw/strftime/;

	my $posix = Test::MockModule->new("POSIX");

	$posix->mock("strftime", "Yesterday");
	is strftime("%D", localtime(time)), "Yesterday", "`strftime` was mocked successfully"; # Fails
	is POSIX::strftime("%D", localtime(time)), "Yesterday", "`strftime` was mocked successfully"; # Succeeds

	my $main = Test::MockModule->new("main", no_auto => 1);
	$main->mock("strftime", "today");
	is strftime("%D", localtime(time)), "today", "`strftime` was mocked successfully"; # Succeeds

If you are trying to mock a subroutine that was exported into a module that you're
trying to test, rather than mocking the subroutine in its originating module,
you can instead mock it in the module you are testing:

	package MyModule;
	use POSIX qw/strftime/;

	sub minus_twentyfour
	{
		return strftime("%a, %b %d, %Y", localtime(time - 86400));
	}

	package main;
	use Test::More;
	use Test::MockModule;

	my $posix = Test::MockModule->new("POSIX");
	$posix->mock("strftime", "Yesterday");

	is MyModule::minus_twentyfour(), "Yesterday", "`minus-twentyfour` got mocked"; # fails

	my $mymodule = Test::MockModule->new("MyModule", no_auto => 1);
	$mymodule->mock("strftime", "Yesterday");
	is MyModule::minus_twentyfour(), "Yesterday", "`minus-twentyfour` got mocked"; # succeeds

=item redefine($subroutine)

The same behavior as C<mock()>, but this will preemptively check to be
sure that all passed subroutines actually exist. This is useful to ensure that
if a mocked module's interface changes the test doesn't just keep on testing a
code path that no longer behaves consistently with the mocked behavior.

Note that redefine is also now checking if one of the parent provides the sub
and will not die if it's available in the chain.

Returns the current C<Test::MockModule> object, so you can chain L<new> with L<redefine>.

	my $mock = Test::MockModule->new->(...)->redefine(...);

=item define($subroutine)

The reverse of redefine, this will fail if the passed subroutine exists.
While this use case is rare, there are times where the perl code you are
testing is inspecting a package and adding a missing subroutine is actually
what you want to do.

By using define, you're asserting that the subroutine you want to be mocked
should not exist in advance.

Note: define does not check for inheritance like redefine.

Returns the current C<Test::MockModule> object, so you can chain L<new> with L<define>.

	my $mock = Test::MockModule->new->(...)->define(...);

=item original($subroutine)

Returns the original (unmocked) subroutine

Here is a sample how to wrap a function with custom arguments using the original subroutine.
This is useful when you cannot (do not) want to alter the original code to abstract
one hardcoded argument pass to a function.

	package MyModule;

	sub sample {
		return get_path_for("/a/b/c/d");
	}

	sub get_path_for {
		... # anything goes there...
	}

	package main;
	use Test::MockModule;

	my $mock = Test::MockModule->new("MyModule");
	# replace all calls to get_path_for using a different argument
	$mock->redefine("get_path_for", sub {
		return $mock->original("get_path_for")->("/my/custom/path");
	});

	# or

	$mock->redefine("get_path_for", sub {
		my $path = shift;
		if ( $path && $path eq "/a/b/c/d" ) {
			# only alter calls with path set to "/a/b/c/d"
			return $mock->original("get_path_for")->("/my/custom/path");
		} else { # preserve the original arguments
			return $mock->original("get_path_for")->($path, @_);
		}
	});


=item unmock($subroutine [, ...])

Restores the original C<$subroutine>. You can specify a list of subroutines to
C<unmock()> in one go.

=item unmock_all()

Restores all the subroutines in the package that were mocked. This is
automatically called when all C<Test::MockObject> objects for the given package
go out of scope.

=item noop($subroutine [, ...])

Given a list of subroutine names, mocks each of them with a no-op subroutine. Handy
for mocking methods you want to ignore!

    # Neuter a list of methods in one go
    $module->noop('purge', 'updated');


=back

=over 4

=item TRACE

A stub for Log::Trace

=item DUMP

A stub for Log::Trace

=back

=head1 SEE ALSO

L<Test::MockObject::Extends>

L<Sub::Override>

=head1 AUTHORS

Current Maintainer: Geoff Franks <gfranks@cpan.org>

Original Author: Simon Flack E<lt>simonflk _AT_ cpan.orgE<gt>

Lexical scoping of strictness: David Cantrell E<lt>david@cantrell.org.ukE<gt>

=head1 COPYRIGHT

Copyright 2004 Simon Flack E<lt>simonflk _AT_ cpan.orgE<gt>.
All rights reserved

You may distribute under the terms of either the GNU General Public License or
the Artistic License, as specified in the Perl README file.

=cut

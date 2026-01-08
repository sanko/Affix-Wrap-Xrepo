use v5.40;
use feature 'class';
no warnings 'experimental::class';
class Affix::Wrap::Xrepo v1.0.0 {
    use Alien::Xmake;
    use Capture::Tiny qw[capture];
    use JSON::PP;
    use Path::Tiny;
    use Config;
    #
    field $verbose : param //= 0;
    field $xmake = Alien::Xmake->new;
    method blah ($msg) { return unless $verbose; say $msg; }
    #
    class Affix::Wrap::Xrepo::PackageInfo {
        use Path::Tiny;
        field $includedirs : param : reader;
        field $libfiles    : param : reader;
        field $license     : param : reader;
        field $linkdirs    : param : reader;
        field $links       : param : reader;
        field $shared      : param : reader;
        field $static      : param : reader;
        field $version     : param : reader;
        field $libpath     : param : reader //= ();

        # Helper to find a specific header inside the includedirs
        method find_header ($filename) {
            for my $dir (@$includedirs) {
                my $p = path($dir)->child($filename);
                return $p->stringify if $p->exists;
            }

            # Fallback check: sometimes xrepo returns the generic include root,
            # and the file is in a subdir (e.g. GL/gl.h)
            warn "Header '$filename' not found in package include directories:\n" . join( "\n", @$includedirs ) . "\n";
            return;
        }
    }
    #
    method install ( $pkg_spec, $version //= (), %opts ) {
        my $full_spec = defined $version && length $version ? "$pkg_spec $version" : $pkg_spec;

        # Build common arguments for both install and fetch
        my @args = $self->_build_args( \%opts );
        say "[*] xrepo: ensuring $full_spec is installed..." if $verbose;

        # Install
        my @install_cmd = ( $xmake->xrepo, 'install', '-y', @args, $full_spec );
        $self->blah("Running: @install_cmd");
        my ( $out, $err, $exit ) = capture { system @install_cmd };
        die "xrepo install failed:\nCommand: @install_cmd\nOutput:\n$out\nError:\n$err" if $exit != 0;

        # Fetch (must use same args to get correct paths for arch/mode)
        warn "[*] xrepo: fetching paths...\n" if $verbose;
        my @fetch_cmd = ( $xmake->xrepo, 'fetch', '--json', @args, $full_spec );
        $self->blah("Running: @fetch_cmd");
        my ( $json_out, $json_err, $json_exit ) = capture { system @fetch_cmd };
        die "xrepo fetch failed:\nCommand: @fetch_cmd\nError:\n$json_err" if $json_exit != 0;
        my $data;
        try { $data = decode_json($json_out); } catch ($e) {
            die "Failed to decode xrepo JSON output: $e\nOutput was: $json_out"
        };

        # xrepo might return a single object or a list.
        $self->_process_info( ( ref $data eq 'ARRAY' ) ? $data->[0] : $data );
    }

    method uninstall ( $pkg_spec, %opts ) {
        my @args = $self->_build_args( \%opts );
        say "[*] xrepo: uninstalling $pkg_spec..." if $verbose;
        system $xmake->xrepo, 'remove', '-y', @args, $pkg_spec;
    }

    method search ($query) {
        say "[*] xrepo: searching for $query..." if $verbose;
        system $xmake->xrepo, 'search', $query;
    }

    method clean () {
        say '[*] xrepo: cleaning cache...' if $verbose;
        system $xmake->xrepo, 'clean', '-y';
    }
    #
    method add_repo ( $name, $url, $branch //= () ) {
        say "[*] xrepo: adding repo $name..." if $verbose;
        my @cmd = ( $xmake->xrepo, 'add-repo', '-y', $name, $url );
        push @cmd, $branch if defined $branch;
        my ( $out, $err, $exit ) = capture { system @cmd };
        die "xrepo add-repo failed:\n$err" if $exit != 0;
        return 1;
    }

    method remove_repo ($name) {
        say "[*] xrepo: removing repo $name..." if $verbose;
        system $xmake->xrepo, 'remove-repo', '-y', $name;
    }

    method update_repo ( $name //= () ) {
        say '[*] xrepo: updating repositories...' if $verbose;
        my @cmd = ( $xmake->xrepo, 'update-repo', '-y' );
        push @cmd, $name if defined $name;
        system @cmd;
    }
    #
    method _build_args ($opts) {
        my @args;

        # Standard xmake/xrepo flags
        push @args, '-p', $opts->{plat} if $opts->{plat};                        # platform (iphoneos, android, etc)
        push @args, '-a', $opts->{arch} if $opts->{arch};                        # architecture (arm64, x86_64)
        push @args, '-m', $opts->{mode} if $opts->{mode};                        # debug/release
        push @args, '-k', ( $opts->{kind} // 'shared' );                         # static/shared (Default to shared for FFI)
        push @args, '--toolchain=' . $opts->{toolchain} if $opts->{toolchain};

        # Complex configs (passed as --configs='key=val,key2=val2')
        if ( my $c = $opts->{configs} ) {
            if ( ref $c eq 'HASH' ) {
                my $str = join( ',', map {"$_=$c->{$_}"} keys %$c );
                push @args, "--configs=$str";
            }
            else {
                push @args, "--configs=$c";
            }
        }

        # Build Includes (deps)
        if ( my $i = $opts->{includes} ) {
            push @args, '--includes=' . ( ref $i eq 'ARRAY' ? join( ',', @$i ) : $i );
        }
        return @args;
    }

    method _process_info ($info) {
        return () unless defined $info;

        # Check if the fetch actually returned valid data.
        # Sometimes if fetch fails silently or returns empty json logic, we guard here.
        my $libfiles = $info->{libfiles}    // [];
        my $incdirs  = $info->{includedirs} // [];
        unless (@$libfiles) {
            $self->blah('xrepo returned no library files. Is the package header-only or failed to build?');

            # If it's header only, we return the object but libpath will be undef
            return Affix::Wrap::Xrepo::PackageInfo->new(
                includedirs => $incdirs,
                libfiles    => $libfiles,
                license     => $info->{license}  // (),
                linkdirs    => $info->{linkdirs} // [],
                links       => $info->{links}    // (),
                shared      => $info->{shared}   // 0,
                static      => $info->{static}   // 0,
                version     => $info->{version}  // ()
            );
        }
        my $found_lib;

        # Filter libfiles for the runtime shared library (FFI target)
        if ( $^O eq 'MSWin32' ) {    # Windows: strict search for .dll
            ($found_lib) = grep {/\.dll$/i} @$libfiles;

            # If we asked for static, we might get .lib
            if ( !$found_lib && ( $info->{static} // 0 ) ) {
                ($found_lib) = grep {/\.lib$/i} @$libfiles;
            }
        }
        elsif ( $^O eq 'darwin' ) {    # macOS: prefer .dylib, then .so, then .a (if static)
            ($found_lib) = grep {/\.dylib$/i} @$libfiles;
            ($found_lib) //= grep {/\.so$/i} @$libfiles;
            ($found_lib) //= grep {/\.a$/i} @$libfiles unless $info->{shared};
        }
        else {                         # Linux/BSD: .so or .so.1.2.3, then .a
            ($found_lib) = grep {/\.so(\.|$)/} @$libfiles;
            ($found_lib) //= grep {/\.a$/i} @$libfiles unless $info->{shared};
        }
        $self->blah( "Could not identify primary binary from: " . join( ", ", @$libfiles ) ) unless $found_lib;
        return Affix::Wrap::Xrepo::PackageInfo->new(
            includedirs => $incdirs,
            libfiles    => $libfiles,
            license     => $info->{license}  // (),
            linkdirs    => $info->{linkdirs} // [],
            libpath     => $found_lib,
            links       => $info->{links} // (),
            shared      => $info->{shared},
            static      => $info->{static},
            version     => $info->{version} // ()
        );
    }
};
1;
__END__

=pod

=head1 NAME

Affix::Wrap::Xrepo - Solves the Headache of Finding and Building Shared Libraries for FFI

=head1 SYNOPSIS

    use Affix::Wrap;
    use Affix::Wrap::Xrepo;

    # Initialize
    my $repo = Affix::Wrap::Xrepo->new( verbose => 1 );

    # Add a custom repository (optional)
    # $repo->add_repo( 'my-repo', 'https://github.com/my/repo.git' );

    # Install a shared lib with an automatic configuration
    my $ogg = $repo->install( 'libvorbis' );

    # Install a library with specific configuration
    # equivalent to: xrepo install -p windows -a x86_64 -m debug --configs='shared=true,vs_runtime=MD' libpng
    my $pkg = $repo->install(
        libpng  => '1.6.x',
        plat    => 'windows',
        arch    => 'x64',
        mode    => 'debug',
        configs => { vs_runtime => 'MD' }
    );

    die "Install failed" unless $pkg;

    say 'Loaded: ' . $pkg->libpath; # Path to .dll/.so

    # Find a header for Affix::Wrap
    my $header_path = $pkg->find_header( 'png.h' );

=head1 DESCRIPTION

This module acts as an intelligent bridge between Perl and the C<xrepo> C/C++ package manager.

While L<Affix> or L<FFI::Platypus> or C<Inline::C> can handle the calling of native functions, Affix::Wrap::Xrepo
handles the B<acquisition> of the libraries containing those functions. It automates the entire dependency lifecycle:

=over

=item 1. Provisioning:

Downloads and installs libraries (C<libpng>, C<openssl>, etc.) via C<xrepo>, handling version constraints and custom
repository lookups.

=item 2. Configuration:

Ensures libraries are compiled with FFI compatible flags (forcing C<shared> libraries instead of static archives) and
supports cross-compilation parameters (platform, architecture, toolchains).

=item 3. Introspection:

Parses the build metadata to locate the exact absolute paths to the runtime binaries (C<.dll>, C<.so>, C<.dylib>) and
header files, abstracting away operating system filesystem differences.

=back

This eliminates the need for manual compilation steps or hard coding paths in your Perl scripts, making your FFI
bindings or XS wrappers portable and reproducible.

=head1 CONSTRUCTOR

=head2 C<new>

    my $repo = Affix::Wrap::Xrepo->new( verbose => 1 );

Creates a new instance.

=over

=item B<verbose>

Boolean. If true, prints command output and status messages to C<STDOUT>. Defaults to C<0>.

=back

=head1 METHODS

=head2 C<install( ... )>

    my $pkg_info = $repo->install( $package_name, $version_constraint, %options );

Installs (if missing) and fetches the metadata for a package.

=over

=item B<$package_name>

The name of the package (e.g., C<zlib>, C<opencv>).

=item B<$version_constraint>

Optional semantic version string (C<1.2.x>, C<latest>). Pass C<undef> or an empty string for default.

=item B<%options>

Configuration options passed to C<xrepo>:

=over

=item B<plat>

Target platform (e.g., C<windows>, C<linux>, C<macosx>, C<android>, C<iphoneos>, C<wasm>).

=item B<arch>

Target architecture (e.g., C<x86_64>, C<arm64>, C<riscv64>).

=item B<mode>

Build mode: C<debug> or C<release>.

=item B<kind>

Library kind: C<shared> (default) or C<static>.

I<Note: For FFI, you almost always want C<shared>, but C<static> is available if you are linking archives with, say, an
XS module.>

=item B<toolchain>

Specify a toolchain (e.g., C<llvm>, C<zig>, C<mingw>).

=item B<configs>

A hashsef or string of package-specific configurations.

    configs => { openssl => 'true', shared => 'true' }
    # becomes --configs='openssl=true,shared=true'

=item B<includes>

A list or string of extra dependencies to include in the environment.

=back

=back

Returns an L<Affix::Wrap::Xrepo::PackageInfo> object.

=head2 C<uninstall( ... )>

    $repo->uninstall('zlib');

Removes the specified package from the local cache. Accepts the same C<%options> as C<install( ... )>.

=head2 C<search>

    $repo->search( 'png' );

Runs `xrepo search` and prints the results to STDOUT.

=head2 C<clean( )>

    $repo->clean( );

Cleans the cached packages and downloads.

=head2 C<add_repo( ... )>

    $repo->add_repo($name, $git_url, $branch);

Adds a custom xmake repository.

=head2 C<remove_repo( ... )>

    $repo->remove_repo( $name );

Removes a custom repository.

=head2 C<update_repo( [...] )>

    $repo->update_repo( );        # Update all
    $repo->update_repo( 'main' ); # Update specific repo

Updates the local package lists from the remote repositories.

=head1 Affix::Wrap::Xrepo::PackageInfo

Returned by C<install( ... )>, this object contains the results of the dependency resolution.

=head3 Attributes

=over

=item B<libpath>

The absolute path to the main library file (C<.dll>, C<.dylib>, or C<.so>). Returns C<undef> if the package is
header-only or the binary could not be identified.

=item B<includedirs>

List of include paths.

=item B<libfiles>

List of all library files associated with the package (may include import libs, static archives, etc.).

=item B<license>

The license identifier.

=item B<version>

The installed version.

=back

=head3 Methods

=head4 C<find_header( ... )>

    my $path = $info->find_header( 'png.h' );

Scans C<includedirs> for the given filename and returns the absolute path if found. Returns C<undef> otherwise.

=head1 SEE ALSO

L<Affix>, L<Alien::Xmake>, L<https://xrepo.xmake.io>

=head1 AUTHOR

Sanko Robinson E<lt>sanko@cpan.orgE<gt>

=head1 COPYRIGHT

Copyright (C) 2026 by Sanko Robinson.

This library is free software; you can redistribute it and/or modify it under the terms of the Artistic License 2.0.

=cut

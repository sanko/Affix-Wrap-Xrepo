use v5.40;
use feature 'class';
no warnings 'experimental::class';
class Xrepo v1.0.0 {
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
    class Xrepo::PackageInfo {
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
            return Xrepo::PackageInfo->new(
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
        return Xrepo::PackageInfo->new(
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

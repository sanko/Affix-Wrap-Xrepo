# NAME

Affix::Wrap::Xrepo - Solves the Headache of Finding and Building Shared Libraries for FFI

# SYNOPSIS

```perl
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
```

# DESCRIPTION

This module acts as an intelligent bridge between Perl and the `xrepo` C/C++ package manager.

While [Affix](https://metacpan.org/pod/Affix) or [FFI::Platypus](https://metacpan.org/pod/FFI%3A%3APlatypus) or [Inline::C](https://metacpan.org/pod/Inline%3A%3AC) can handle the calling of native functions, Affix::Wrap::Xrepo
handles the **acquisition** of the libraries containing those functions. It automates the entire dependency lifecycle:

- 1. Provisioning:

    Downloads and installs libraries (`libpng`, `openssl`, etc.) via `xrepo`, handling version constraints and custom
    repository lookups.

- 2. Configuration:

    Ensures libraries are compiled with FFI compatible flags (forcing `shared` libraries instead of static archives) and
    supports cross-compilation parameters (platform, architecture, toolchains).

- 3. Introspection:

    Parses the build metadata to locate the exact absolute paths to the runtime binaries (`.dll`, `.so`, `.dylib`) and
    header files, abstracting away operating system filesystem differences.

This eliminates the need for manual compilation steps or hard coding paths in your Perl scripts, making your FFI
bindings or XS wrappers portable and reproducible.

# CONSTRUCTOR

## `new`

```perl
my $repo = Affix::Wrap::Xrepo->new( verbose => 1 );
```

Creates a new instance.

- **verbose**

    Boolean. If true, prints command output and status messages to `STDOUT`. Defaults to `0`.

# METHODS

## `install( ... )`

```perl
my $pkg_info = $repo->install( $package_name, $version_constraint, %options );
```

Installs (if missing) and fetches the metadata for a package.

- **$package\_name**

    The name of the package (e.g., `zlib`, `opencv`).

- **$version\_constraint**

    Optional semantic version string (`1.2.x`, `latest`). Pass `undef` or an empty string for default.

- **%options**

    Configuration options passed to `xrepo`:

    - **plat**

        Target platform (e.g., `windows`, `linux`, `macosx`, `android`, `iphoneos`, `wasm`).

    - **arch**

        Target architecture (e.g., `x86_64`, `arm64`, `riscv64`).

    - **mode**

        Build mode: `debug` or `release`.

    - **kind**

        Library kind: `shared` (default) or `static`.

        _Note: For FFI, you almost always want `shared`, but `static` is available if you are linking archives with, say, an
        XS module._

    - **toolchain**

        Specify a toolchain (e.g., `llvm`, `zig`, `mingw`).

    - **configs**

        A hashsef or string of package-specific configurations.

        ```perl
        configs => { openssl => 'true', shared => 'true' }
        # becomes --configs='openssl=true,shared=true'
        ```

    - **includes**

        A list or string of extra dependencies to include in the environment.

Returns an [Affix::Wrap::Xrepo::PackageInfo](https://metacpan.org/pod/Affix%3A%3AWrap%3A%3AXrepo%3A%3APackageInfo) object.

## `uninstall( ... )`

```
$repo->uninstall('zlib');
```

Removes the specified package from the local cache. Accepts the same `%options` as `install( ... )`.

## `search`

```
$repo->search( 'png' );
```

Runs \`xrepo search\` and prints the results to STDOUT.

## `clean( )`

```
$repo->clean( );
```

Cleans the cached packages and downloads.

## `add_repo( ... )`

```
$repo->add_repo($name, $git_url, $branch);
```

Adds a custom xmake repository.

## `remove_repo( ... )`

```
$repo->remove_repo( $name );
```

Removes a custom repository.

## `update_repo( [...] )`

```
$repo->update_repo( );        # Update all
$repo->update_repo( 'main' ); # Update specific repo
```

Updates the local package lists from the remote repositories.

# Affix::Wrap::Xrepo::PackageInfo

Returned by `install( ... )`, this object contains the results of the dependency resolution.

### Attributes

- **libpath**

    The absolute path to the main library file (`.dll`, `.dylib`, or `.so`). Returns `undef` if the package is
    header-only or the binary could not be identified.

- **includedirs**

    List of include paths.

- **libfiles**

    List of all library files associated with the package (may include import libs, static archives, etc.).

- **license**

    The license identifier.

- **version**

    The installed version.

### Methods

#### `find_header( ... )`

```perl
my $path = $info->find_header( 'png.h' );
```

Scans `includedirs` for the given filename and returns the absolute path if found. Returns `undef` otherwise.

# SEE ALSO

[Affix](https://metacpan.org/pod/Affix), [Alien::Xmake](https://metacpan.org/pod/Alien%3A%3AXmake), [https://xrepo.xmake.io](https://xrepo.xmake.io)

# AUTHOR

Sanko Robinson <sanko@cpan.org>

# COPYRIGHT

Copyright (C) 2026 by Sanko Robinson.

This library is free software; you can redistribute it and/or modify it under the terms of the Artistic License 2.0.

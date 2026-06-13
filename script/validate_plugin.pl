#!/usr/bin/env perl

# Validate that a managed plugin artifact loads.
#
# Usage:  perl script/validate_plugin.pl <plugin-relpath-under-lib>
#   e.g.  perl script/validate_plugin.pl LANraragi/Plugin/Managed/Metadata/Foo.pm
#
# Exit codes:
#   0  artifact loads and implements plugin_info()
#   1  artifact failed to load, or does not satisfy the plugin contract
#   2  usage / bad argument

use strict;
use warnings;
use utf8;

use FindBin;

BEGIN { unshift @INC, "$FindBin::Bin/../lib"; }

use LANraragi::Utils::Path qw(path_to_package);

my $relpath = shift @ARGV;
unless ( defined $relpath && length $relpath ) {
    print STDERR "usage: validate_plugin.pl <plugin-relpath-under-lib>\n";
    exit 2;
}

# Load the artifact exactly as a worker does: require by relative path, resolved
# through @INC (which now includes LRR's lib). Runs BEGIN and top-level code.
my $loaded = eval { require $relpath; 1 };
unless ($loaded) {
    print STDERR "failed to load '$relpath': " . ( $@ || "unknown error" );
    exit 1;
}

# The declared package must match the path and must implement the plugin
# metadata contract.
my $package = path_to_package($relpath);
unless ( $package && $package->can('plugin_info') ) {
    print STDERR "'$relpath' does not implement plugin_info()\n";
    exit 1;
}

exit 0;

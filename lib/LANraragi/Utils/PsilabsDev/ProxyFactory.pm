package LANraragi::Utils::PsilabsDev::ProxyFactory;

use strict;
use warnings;
use utf8;

use Exporter 'import';
our @EXPORT_OK = qw(make_proxy);

use B ();
use LANraragi::Utils::PsilabsDev::Database qw(BACKEND);

# Stash-copies subs defined in the selected backend into the proxy package.
# Only copies subs whose defining package matches $impl, filtering out
# functions imported from other modules (e.g. Carp::croak, Mojo::JSON::decode_json).
# Usage:
#   make_proxy(__PACKAGE__,
#       postgres => 'LANraragi::Model::PsilabsDev::PgArchive',
#       redis    => 'LANraragi::Model::Archive',
#   );
sub make_proxy {
    my ( $proxy_pkg, %backends ) = @_;
    my $impl = $backends{ BACKEND() } // die "No backend for: " . BACKEND;

    my $impl_file = $impl;
    $impl_file =~ s|::|/|g;
    require "$impl_file.pm";

    no strict 'refs';
    for my $sym ( keys %{"${impl}::"} ) {
        next if $sym eq 'import';    # preserve proxy's own Exporter import
        next unless defined &{"${impl}::$sym"};

        # Skip subs imported from other packages
        my $cv = B::svref_2object( \&{"${impl}::$sym"} );
        next unless $cv->GV->STASH->NAME eq $impl;

        *{"${proxy_pkg}::$sym"} = \&{"${impl}::$sym"};
    }
}

1;

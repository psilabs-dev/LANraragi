package LANraragi::Controller::Api::Extensions::Sqlite;

use strict;
use warnings;
use utf8;

# APIs to check if sqlite database exists.

# TODO: get status of postgres database.
sub get_sqlite_status {

    my $self = shift;

    $self->render(
        json => {
            operation   => "sqlite_status",
            status      => 1
        }
    )

}

1;
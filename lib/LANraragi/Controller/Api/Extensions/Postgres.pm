package LANraragi::Controller::Api::Extensions::Postgres;

# APIs to check connection/health to postgres database

# TODO: get status of postgres database.
sub get_postgres_status {

    my $self = shift;

    $self->render(
        json => {
            operation   => "postgres_status",
            status      => 1
        }
    )

}

1;
package LANraragi::Controller::Api::Metrics;
use Mojo::Base 'Mojolicious::Controller';

sub hello {
    my $self = shift;
    $self->render(
        json => {
            message => "success"
        }
    );
}

1;
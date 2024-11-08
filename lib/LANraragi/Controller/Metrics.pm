package LANraragi::Controller::Metrics;
use Mojo::Base 'Mojolicious::Controller';

sub metrics {
    my $self = shift;
    $self->render(
        text    => $self->LRR_PROMETHEUS->render,
        format  => 'text'
    );
}

1;
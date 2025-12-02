package LANraragi::Controller::Api::Metrics;
use Mojo::Base 'Mojolicious::Controller';
use Storable;
use Config;

use LANraragi::Model::Metrics;
use LANraragi::Utils::TempFolder qw(get_temp);
use LANraragi::Utils::Generic    qw(render_api_response);

use constant IS_UNIX => ( $Config{osname} ne 'MSWin32' );

# Serve metrics in Prometheus exposition format.
sub serve_metrics {
    my $self = shift;
    my $metrics_output = LANraragi::Model::Metrics::get_prometheus_metrics($self);
    $self->render(
        text    => $metrics_output,
        format  => 'txt',
        headers => { 'Content-Type' => 'text/plain; version=0.0.4; charset=utf-8' }
    );
}

sub metrics_status {
    my $self = shift;

    if ( IS_UNIX ) {
        my $proc = ${ retrieve( get_temp . "/metrics.pid" ) };
        $self->render(
            json => {
                operation => "metrics_status",
                success   => 1,
                is_alive  => $proc->poll(),
                pid       => $proc->pid
            }
        );
    } else {
        open( my $fh, "<", get_temp() . "/metrics.pid-s6" );
        chomp(my $pid = <$fh>);
        close($fh);

        my $metrics_proc;
        eval {
            require Win32::Process;
            Win32::Process->import( qw(NORMAL_PRIORITY_CLASS) );
            Win32::Process::Open($metrics_proc, $pid, 0);
            $self->render(
                json => {
                    operation => "metrics_status",
                    success   => 1,
                    is_alive  => $metrics_proc->GetProcessID() != 0,
                    pid       => "" . $metrics_proc->GetProcessID()
                }
            );
        };
    }
}

sub stop_metrics {
    my $self = shift;

    if ( IS_UNIX ) {
        my $proc = ${ retrieve( get_temp . "/metrics.pid" ) };
        $proc->kill();
    } else {
        open( my $fh, "<", get_temp() . "/metrics.pid-s6" );
        chomp(my $pid = <$fh>);
        close($fh);
        kill HUP => $pid;
    }

    render_api_response( $self, "metrics_stop" );
}

1;
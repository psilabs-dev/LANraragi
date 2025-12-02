package Metrics;

# LANraragi Prometheus metrics consumer and aggregator

use strict;
use warnings;
use utf8;
use feature qw(say signatures);
no warnings 'experimental::signatures';

use FindBin;

#As this is a new process, reloading the LRR libs into INC is needed.
BEGIN { unshift @INC, "$FindBin::Bin/../lib"; }

use Mojolicious;    # Needed by Model::Config to read configuration.
use LANraragi::Utils::Logging qw(get_logger);
use LANraragi::Model::Config;
use LANraragi::Model::Metrics;

# Logger and Database objects
my $logger = get_logger( "Metrics", "metrics" );

sub initialize_from_new_process {

    my $metrics_enabled = LANraragi::Model::Config->enable_metrics;

    unless ($metrics_enabled) {
        $logger->info("Metrics are disabled. Metrics Aggregator will not start.");
        return;
    }

    $logger->info("Metrics Aggregator started.");

    my $running          = 1;
    my $metrics_counter = 0;

    local $SIG{INT}  = sub { $running = 0 };
    local $SIG{TERM} = sub { $running = 0 };

    while ($running) {
        # Placeholder for IPC receive: future implementation will dequeue and aggregate here.
        eval { process_incoming_messages(); };
        if ($@) {
            $logger->error("Error while processing incoming metrics: $@");
        }

        # Collect process metrics every 30 seconds (30 * 1 second intervals)
        if ( ++$metrics_counter >= 30 ) {
            LANraragi::Model::Metrics::collect_process_metrics("aggregator");
            $metrics_counter = 0;
        }

        sleep 1;
    }

    $logger->info("Metrics Aggregator stopped.");
}

sub process_incoming_messages {
    # Future: receive and aggregate metrics from producers (HTTP workers, Minion, Shinobu, etc.)
    return;
}

__PACKAGE__->initialize_from_new_process unless caller;

1;

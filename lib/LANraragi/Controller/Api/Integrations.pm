package LANraragi::Controller::Api::Integrations;
use Mojo::Base 'Mojolicious::Controller';

use Mojo::UserAgent;
use Mojo::JSON qw(decode_json);
use LANraragi::Model::Config;
use LANraragi::Utils::Generic  qw(exec_with_lock);
use LANraragi::Utils::Logging  qw(get_logger);

use strict;
use warnings;

# Third party data source integrations.

sub get_pixiv_server_status {
    my $self = shift;
    my $pixivutil_server_url = $ENV{"PIXIVUTIL_SERVER_URL"};
    unless ( defined $pixivutil_server_url ) {
        return $self->render(
            json => {
                operation   => "pixiv_download_artist",
                success     => 0,
                error       => "PIXIVUTIL_SERVER_URL variable not set."
            },
            status => 501
        );
    }

    # Normalize base URL (remove trailing slash)
    $pixivutil_server_url =~ s/\/$//;

    my $ua = Mojo::UserAgent->new;
    my $logger = get_logger( "Integrations API ", "lanraragi" );
    my $tx = eval { $ua->get("$pixivutil_server_url/api/health/")->result };
    if ($@ || !$tx) {
        my $err = $@ || 'Unknown error when contacting Pixiv server';
        $logger->error("Pixiv health check failed: $err");
        return $self->render(
            json => {
                operation => "pixiv_server_status",
                success   => 0,
                error     => "Failed to contact Pixiv server: $err"
            },
            status => 502
        );
    }

    if ($tx->is_success) {
        return $self->render(
            json => {
                operation       => "pixiv_server_status",
                success         => 1,
                url             => $pixivutil_server_url,
                upstream_status => $tx->code,
                upstream_body   => $tx->body
            },
            status => 200
        );
    } else {
        return $self->render(
            json => {
                operation       => "pixiv_server_status",
                success         => 0,
                url             => $pixivutil_server_url,
                upstream_status => $tx->code,
                error           => $tx->body
            },
            status => 502
        );
    }
}

# pixivutil-server integration to download artwork by artist.
sub queue_pixiv_download_artworks_by_artist {
    my $self            = shift;
    my $member_id       = $self->stash('member_id');
    my $logger          = get_logger( "Integrations API ", "lanraragi" );
    my $redis           = LANraragi::Model::Config->get_redis;

    # get pixivutil-server base URL.
    my $pixivutil_server_url = $ENV{"PIXIVUTIL_SERVER_URL"};

    unless ( defined $pixivutil_server_url ) {
        return $self->render(
            json => {
                operation   => "pixiv_download_artist",
                success     => 0,
                error       => "PIXIVUTIL_SERVER_URL variable not set."
            },
            status => 501
        );
    }

    unless ( defined $member_id && $member_id =~ /^\d+$/ ) {
        return $self->render(
            json => {
                operation => "pixiv_download_artist",
                success   => 0,
                error     => "Invalid or missing member_id."
            },
            status => 400
        );
    }

    $pixivutil_server_url =~ s/\/$//;
    $logger->info("Queueing download by member ID $member_id to server: $pixivutil_server_url");
    return unless exec_with_lock( $self, $redis, "integrations:pixiv_download_artist-$member_id", "pixiv_download_artist", $member_id, sub {
        my $ua = Mojo::UserAgent->new;
        my $tx = eval { $ua->post("$pixivutil_server_url/api/download/member/$member_id")->result };
        if ($@ || !$tx) {
            my $err = $@ || 'Unknown error when contacting Pixiv server';
            $logger->error("Pixiv queue request failed: $err");
            return $self->render(
                json => {
                    operation => "pixiv_download_artist",
                    success   => 0,
                    error     => "Failed to contact Pixiv server: $err"
                },
                status => 502
            );
        }

        if ($tx->is_success) {
            my $json = eval { $tx->json };
            $json = {} unless $json && ref $json eq 'HASH';
            return $self->render(
                json => {
                    operation => "pixiv_download_artist",
                    success   => 1,
                    task_id   => $json->{task_id},
                    member_id => $json->{member_id} // "$member_id",
                    member_name => $json->{member_name}
                },
                status => 200
            );
        } else {
            return $self->render(
                json => {
                    operation => "pixiv_download_artist",
                    success   => 0,
                    error     => $tx->body,
                    upstream_status => $tx->code
                },
                status => 502
            );
        }
    });
}

sub get_twitterdl_server_status {
    my $self = shift;
    my $twitterdl_server_url = $ENV{"TWITTERDL_SERVER_URL"};
    unless ( defined $twitterdl_server_url ) {
        return $self->render(
            json => {
                operation   => "twitterdl_server_status",
                success     => 0,
                error       => "TWITTERDL_SERVER_URL variable not set."
            },
            status => 501
        );
    }

    $twitterdl_server_url =~ s/\/$//;
    my $ua = Mojo::UserAgent->new;
    my $logger = get_logger( "Integrations API ", "lanraragi" );
    my $tx = eval { $ua->get("$twitterdl_server_url/api/health/")->result };
    if ($@ || !$tx) {
        my $err = $@ || 'Unknown error when contacting TwitterDL server';
        $logger->error("TwitterDL health check failed: $err");
        return $self->render(
            json => {
                operation => "twitterdl_server_status",
                success   => 0,
                error     => "Failed to contact TwitterDL server: $err"
            },
            status => 502
        );
    }

    if ($tx->is_success) {
        my $json = eval { $tx->json };
        return $self->render(
            json => {
                operation       => "twitterdl_server_status",
                success         => 1,
                url             => $twitterdl_server_url,
                upstream_status => $tx->code,
                upstream_body   => $json || { raw => $tx->body }
            },
            status => 200
        );
    } else {
        return $self->render(
            json => {
                operation       => "twitterdl_server_status",
                success         => 0,
                url             => $twitterdl_server_url,
                upstream_status => $tx->code,
                error           => $tx->body
            },
            status => 502
        );
    }
}

# twitterdl-server integration to download by member
sub queue_twitterdl_download_posts_by_user_id {
    my $self            = shift;
    my $user_id         = $self->stash('user_id');
    my $logger          = get_logger( "Integrations API ", "lanraragi" );
    my $redis           = LANraragi::Model::Config->get_redis;

    my $twitterdl_server_url = $ENV{"TWITTERDL_SERVER_URL"};

    unless ( defined $twitterdl_server_url ) {
        return $self->render(
            json => {
                operation   => "twitterdl_download_user",
                success     => 0,
                error       => "TWITTERDL_SERVER_URL variable not set."
            },
            status => 501
        );
    }

    unless ( defined $user_id && $user_id =~ /^\d+$/ ) {
        return $self->render(
            json => {
                operation => "twitterdl_download_user",
                success   => 0,
                error     => "Invalid or missing user_id."
            },
            status => 400
        );
    }

    my $max_tweets = $self->param('max_tweets');
    $max_tweets = 50 unless defined $max_tweets && $max_tweets =~ /^-?\d+$/;

    $twitterdl_server_url =~ s/\/$//;
    $logger->info("Queueing download by user_id $user_id to server: $twitterdl_server_url (max_tweets=$max_tweets)");
    return unless exec_with_lock( $self, $redis, "integrations:twitterdl_download_user-$user_id", "twitterdl_download_user", $user_id, sub {
        my $ua = Mojo::UserAgent->new;
        my $tx = eval { $ua->post("$twitterdl_server_url/api/download/by_user_id/$user_id?max_tweets=$max_tweets")->result };
        if ($@ || !$tx) {
            my $err = $@ || 'Unknown error when contacting TwitterDL server';
            $logger->error("TwitterDL queue request failed: $err");
            return $self->render(
                json => {
                    operation => "twitterdl_download_user",
                    success   => 0,
                    error     => "Failed to contact TwitterDL server: $err"
                },
                status => 502
            );
        }

        if ($tx->is_success) {
            my $json = eval { $tx->json };
            $json = {} unless $json && ref $json eq 'HASH';
            return $self->render(
                json => {
                    operation => "twitterdl_download_user",
                    success   => 1,
                    task_id   => $json->{task_id},
                    user_id   => $json->{user_id} // $user_id,
                    max_tweets => $json->{max_tweets}
                },
                status => 200
            );
        } else {
            return $self->render(
                json => {
                    operation => "twitterdl_download_user",
                    success   => 0,
                    error     => $tx->body,
                    upstream_status => $tx->code
                },
                status => 502
            );
        }
    });
}

1;

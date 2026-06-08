package LANraragi::Controller::Api::Tankoubon;
use Mojo::Base 'Mojolicious::Controller';

use Scalar::Util qw(looks_like_number);

use LANraragi::Model::Config;
use LANraragi::Model::Tankoubon;
use LANraragi::Model::PsilabsDev::PgTankoubon;
use LANraragi::Model::PsilabsDev::PgArchive;
use LANraragi::Utils::Generic qw(render_api_response);
use LANraragi::Utils::Login   qw(is_logged_in_api);

sub get_tankoubon_list {

    my $self = shift->openapi->valid_input or return;
    my $req  = $self->req;

    my $page = $req->param('page');

    my ( $total, $filtered, @rgs ) = LANraragi::Model::PsilabsDev::PgTankoubon::get_tankoubon_list($page);
    $self->render( openapi => { result => \@rgs, total => $total, filtered => $filtered } );

}

sub get_tankoubon {

    my $self    = shift->openapi->valid_input or return;
    my $tank_id = $self->stash('id');

    my ( $total, $filtered, %tankoubon ) = LANraragi::Model::PsilabsDev::PgTankoubon::get_tankoubon($tank_id);

    unless (%tankoubon) {
        render_api_response( $self, "get_tankoubon", "The given tankoubon does not exist." );
        return;
    }

    $self->render( openapi => \%tankoubon );
}

sub get_tankoubon_full {

    my $self    = shift->openapi->valid_input or return;
    my $tank_id = $self->stash('id');
    my $req     = $self->req;

    my $fulldata = 1;
    my $page     = $req->param('page') // -1;

    my ( $total, $filtered, %tankoubon ) = LANraragi::Model::PsilabsDev::PgTankoubon::get_tankoubon( $tank_id, $fulldata, $page );

    unless (%tankoubon) {
        return render_api_response( $self, "get_tankoubon", "The given tankoubon does not exist." );
    }

    $self->render( openapi => { result => \%tankoubon, total => $total, filtered => $filtered } );
}

sub create_tankoubon {

    my $self   = shift->openapi->valid_input or return;
    my $name   = $self->req->param('name')   || "";
    my $tankid = $self->req->param('tankid') || "";

    if ( $name eq "" ) {
        render_api_response( $self, "create_tankoubon", "Tankoubon name not specified." );
        return;
    }

    my $created_id = LANraragi::Model::PsilabsDev::PgTankoubon::create_tankoubon( $name, $tankid );
    $self->render(
        openapi => {
            operation    => "create_tankoubon",
            tankoubon_id => $created_id,
            success      => 1
        }
    );

}

sub delete_tankoubon {

    my $self   = shift->openapi->valid_input or return;
    my $tankid = $self->stash('id');

    my $result = LANraragi::Model::PsilabsDev::PgTankoubon::delete_tankoubon($tankid);

    if ($result) {
        render_api_response( $self, "delete_tankoubon" );
    } else {
        render_api_response( $self, "delete_tankoubon", "The given tankoubon does not exist." );
    }
}

sub update_tankoubon {

    my $self   = shift->openapi->valid_input or return;
    my $tankid = $self->stash('id');
    my $data   = $self->req->json;

    my ( $result, $err ) = LANraragi::Model::PsilabsDev::PgTankoubon::update_tankoubon( $tankid, $data );

    if ($result) {
        my ( $total, $filtered, %tankoubon ) = LANraragi::Model::PsilabsDev::PgTankoubon::get_tankoubon($tankid);
        my $successMessage = "Updated tankoubon \"$tankoubon{name}\"!";

        render_api_response( $self, "update_tankoubon", undef, $successMessage );
    } else {
        render_api_response( $self, "update_tankoubon", $err );
    }
}

sub add_to_tankoubon {

    my $self   = shift->openapi->valid_input or return;
    my $tankid = $self->stash('id');
    my $arcid  = $self->stash('archive');

    my ( $result, $err ) = LANraragi::Model::PsilabsDev::PgTankoubon::add_to_tankoubon( $tankid, $arcid );

    if ($result) {
        my $successMessage = "Added $arcid to tankoubon $tankid!";
        my ( $total, $filtered, %tankoubon ) = LANraragi::Model::PsilabsDev::PgTankoubon::get_tankoubon($tankid);
        my $title = LANraragi::Model::PsilabsDev::PgArchive::get_title($arcid);

        if ( %tankoubon && defined($title) ) {
            $successMessage = "Added \"$title\" to tankoubon \"$tankoubon{name}\"!";
        }

        render_api_response( $self, "add_to_tankoubon", undef, $successMessage );
    } else {
        render_api_response( $self, "add_to_tankoubon", $err );
    }
}

sub remove_from_tankoubon {

    my $self   = shift->openapi->valid_input or return;
    my $tankid = $self->stash('id');
    my $arcid  = $self->stash('archive');

    my ( $result, $err ) = LANraragi::Model::PsilabsDev::PgTankoubon::remove_from_tankoubon( $tankid, $arcid );

    if ($result) {
        my $successMessage = "Removed $arcid from tankoubon $tankid!";
        my ( $total, $filtered, %tankoubon ) = LANraragi::Model::PsilabsDev::PgTankoubon::get_tankoubon($tankid);
        my $title = LANraragi::Model::PsilabsDev::PgArchive::get_title($arcid);

        if ( %tankoubon && defined($title) ) {
            $successMessage = "Removed \"$title\" from tankoubon \"$tankoubon{name}\"!";
        }

        render_api_response( $self, "remove_from_tankoubon", undef, $successMessage );
    } else {
        render_api_response( $self, "remove_from_tankoubon", $err );
    }
}

sub serve_tankoubon_thumbnail {
    my $self    = shift->openapi->valid_input or return;
    my $tank_id = $self->stash('id');
    LANraragi::Model::Tankoubon::serve_tankoubon_thumbnail( $self, $tank_id );
}

sub update_tankoubon_thumbnail {
    my $self    = shift->openapi->valid_input or return;
    my $tank_id = $self->stash('id');
    LANraragi::Model::PsilabsDev::PgTankoubon::update_tankoubon_thumbnail( $self, $tank_id );
}

sub update_tank_progress {

    my $self    = shift->openapi->valid_input or return;
    my $tank_id = $self->stash('id');
    my $page    = $self->stash('page') || 0;
    my $time    = time();

    # Enforce authentication if authprogress is enabled
    if ( LANraragi::Model::Config->enable_authprogress ) {
        unless ( is_logged_in_api($self) ) {
            return $self->render(
                openapi => {
                    operation => "update_tank_progress",
                    error     => "This operation requires authentication.",
                    success   => 0
                },
                status => 401
            );
        }
    }

    if ( LANraragi::Model::Config->enable_localprogress && !LANraragi::Model::Config->enable_authprogress ) {
        render_api_response( $self, "update_tank_progress", "Server-side Progress Tracking is disabled on this instance." );
        return;
    }

    unless ( looks_like_number($page) && $page > 0 ) {
        render_api_response( $self, "update_tank_progress", "Invalid progress value." );
        return;
    }

    my ( $result, $err ) = LANraragi::Model::PsilabsDev::PgTankoubon::update_tank_progress( $tank_id, $page );

    if ($result) {
        $self->render(
            openapi => {
                operation    => "update_tank_progress",
                id           => $tank_id,
                page         => int($page),
                lastreadtime => $time,
                success      => 1
            }
        );
    } else {
        render_api_response( $self, "update_tank_progress", $err );
    }
}

sub get_tankoubons_file {

    my $self  = shift->openapi->valid_input or return;
    my $arcid = $self->stash('id');

    if ( $arcid eq "" ) {
        render_api_response( $self, "get_tankoubons_file", "Archive not specified." );
        return;
    }

    my @tanks = LANraragi::Model::PsilabsDev::PgTankoubon::get_tankoubons_containing_archive($arcid);

    $self->render(
        openapi => {
            operation  => "find_arc_tankoubons",
            tankoubons => \@tanks,
            success    => 1
        }
    );
}

1;


package LANraragi::Controller::Index;
use Mojo::Base 'Mojolicious::Controller';

use utf8;
use URI::Escape;
use Redis;
use Encode;
use File::Basename;
use Authen::Passphrase;

use LANraragi::Utils::Generic qw(generate_themes_header);
use LANraragi::Utils::Path    qw(get_archive_path);
use LANraragi::Model::PsilabsDev::PgCategory;
use LANraragi::Model::PsilabsDev::PgArchive qw(get_random_archive_id);
use LANraragi::Utils::PsilabsDev::PgPath;

# This endpoint is technically superseded by /api/search/random, but it's still useful in the Reader.
sub random_archive {
    my $self          = shift;
    my $archive       = "";
    my $archiveexists = 0;

    # We get a random archive ID from Postgres.
    # We check to make sure the matching archive file still exists on the server.
    # TODO: This will loop infinitely if there are zero archives in store.
    until ($archiveexists) {
        $archive = get_random_archive_id();

        # If no archive was found, break to avoid infinite loop
        last if $archive eq "";

        $self->LRR_LOGGER->debug("Found key $archive");

        # Check if the matching archive file still exists on the server
        my $arclocation = LANraragi::Utils::PsilabsDev::PgPath::get_archive_path($archive);
        if ( -e $arclocation ) {
            $archiveexists = 1;
        }
    }

    # We redirect to the reader, with the key as parameter.
    $self->redirect_to( '/reader?id=' . $archive );
}

# Render the index template with a few prefilled arguments.
# Most of the work is done in JS these days.
sub index {

    my $self = shift;

    #Checking if the user still has the default password enabled
    my $ppr = Authen::Passphrase->from_rfc2307( $self->LRR_CONF->get_password );
    my $passcheck = ( $ppr->match("kamimamita") && $self->LRR_CONF->enable_pass );

    my $userlogged = $self->LRR_CONF->enable_pass == 0 || $self->session('is_logged');

    # Get static category list to populate the right-click menu
    my @categories = LANraragi::Model::PsilabsDev::PgCategory::get_static_category_list();

    $self->render(
        template     => "index",
        version      => $self->LRR_VERSION,
        title        => $self->LRR_CONF->get_htmltitle,
        descstr      => $self->LRR_DESC,
        userlogged   => $userlogged,
        categories   => \@categories,
        motd         => $self->LRR_CONF->get_motd,
        csshead      => generate_themes_header($self),
        usingdefpass => $passcheck
    );
}

1;

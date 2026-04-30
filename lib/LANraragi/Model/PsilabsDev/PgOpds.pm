package LANraragi::Model::PsilabsDev::PgOpds;

use strict;
use warnings;
use utf8;

use POSIX      qw(strftime);
use Mojo::Util qw(xml_escape);
use File::Basename;

use LANraragi::Utils::Generic  qw(get_tag_with_namespace);
use LANraragi::Utils::Archive  qw(get_filelist extract_single_file);
use LANraragi::Utils::PageCache qw(fetch put);
use LANraragi::Utils::Resizer  qw(get_resizer);
use LANraragi::Utils::PsilabsDev::PgDatabase qw(get_archive_json);
use LANraragi::Utils::PsilabsDev::PgPath     qw(get_archive_path);
use LANraragi::Utils::PsilabsDev::Database    qw(get_dbh);

use LANraragi::Model::PsilabsDev::PgCategory;
use LANraragi::Model::PsilabsDev::PgSearch;

# replaces LANraragi::Model::Opds::generate_opds_catalog
sub generate_opds_catalog {

    my $mojo   = shift;
    my $cat_id = $mojo->req->param('category') || "";
    my $start  = $mojo->req->param('start')    || 0;

    # If the user authentified to this via an API key, we need to carry it over to the OPDS links.
    my $api_key = $mojo->req->param('key');
    my @cats    = LANraragi::Model::PsilabsDev::PgCategory::get_category_list();

    # Use the Postgres search engine to get the list of archives to show in the catalog.
    # TODO Add tankgroup/hidecompleted support to opds?
    my ( $total, $filtered, @keys ) = LANraragi::Model::PsilabsDev::PgSearch::do_search( "", $cat_id, $start, "title", 0, 0, 0, 0, 0 );

    my @list = ();

    foreach my $id (@keys) {
        my $arcdata = get_opds_data($id);
        push @list, $arcdata if $arcdata;
    }

    foreach my $cat (@cats) {

        for ( values %{$cat} ) { $_ = xml_escape($_); }

        # If the category doesn't have a search string, we can add the total count of archives to the entry.
        if ( $cat->{search} eq "" ) {
            $cat->{count} = scalar @{ $cat->{archives} };
        }

        if ( $cat->{id} eq $cat_id ) {
            $cat->{active} = 1;
        }
    }

    # Sort lists to get reproducible results
    @list = sort { lc( $a->{title} ) cmp lc( $b->{title} ) } @list;
    @cats = sort { lc( $a->{name} ) cmp lc( $b->{name} ) } @cats;

    return $mojo->render_to_string(
        template      => "opds",
        arclist       => \@list,
        catlist       => \@cats,
        nocat         => $cat_id eq "",
        nextpage      => $start + scalar @list,
        title         => $mojo->LRR_CONF->get_htmltitle,
        motd          => $mojo->LRR_CONF->get_motd,
        version       => $mojo->LRR_VERSION,
        api_key_query => $api_key ? "?key=" . $api_key     : "",
        api_key_and   => $api_key ? "&amp;key=" . $api_key : ""
    );
}

# replaces LANraragi::Model::Opds::generate_opds_item
sub generate_opds_item {

    my ( $mojo, $id ) = @_;

    # If the user authentified to this via an API key, we need to carry it over to the OPDS links.
    my $api_key = $mojo->req->param('key');

    # Detailed pages just return a single entry instead of all the archives.
    my $arcdata = get_opds_data($id);

    return $mojo->render_to_string(
        template      => "opds_entry",
        arc           => $arcdata,
        title         => $mojo->LRR_CONF->get_htmltitle,
        motd          => $mojo->LRR_CONF->get_motd,
        version       => $mojo->LRR_VERSION,
        api_key_query => $api_key ? "?key=" . $api_key     : "",
        api_key_and   => $api_key ? "&amp;key=" . $api_key : ""
    );
}

# replaces LANraragi::Model::Opds::get_opds_data
sub get_opds_data {

    my $id  = shift;
    my $dbh = get_dbh();

    my $file = get_archive_path( $dbh, $id );
    unless ( -e $file ) {
        $dbh->disconnect();
        return;
    }

    my $arcdata = get_archive_json( $dbh, $id );
    unless ($arcdata) {
        $dbh->disconnect();
        return;
    }

    my $tags = $arcdata->{tags};

    # Parse date from the date_added tag, and convert from unix time to ISO 8601.
    my $date = get_tag_with_namespace( "date_added", $tags, "0" );
    $arcdata->{dateadded} = strftime( "%Y-%m-%dT%H:%M:%SZ", gmtime($date) );

    # Infer a few OPDS-related fields from the tags
    $arcdata->{author}   = get_tag_with_namespace( "artist",   $tags, "" );
    $arcdata->{language} = get_tag_with_namespace( "language", $tags, "" );
    $arcdata->{circle}   = get_tag_with_namespace( "group",    $tags, "" );
    $arcdata->{event}    = get_tag_with_namespace( "event",    $tags, "" );

    # Application/zip is universally hated by all readers so it's better to use x-cbz and x-cbr here.
    if ( $file =~ /^(.*\/)*.+\.(pdf)$/ ) {
        $arcdata->{mimetype} = "application/pdf";
    } elsif ( $file =~ /^(.*\/)*.+\.(rar|cbr)$/ ) {
        $arcdata->{mimetype} = "application/x-cbr";
    } elsif ( $file =~ /^(.*\/)*.+\.(epub)$/ ) {
        $arcdata->{mimetype} = "application/epub+zip";
    } else {
        $arcdata->{mimetype} = "application/x-cbz";
    }

    if ( $arcdata->{lastreadtime} > 0 ) {
        $arcdata->{lastreaddate} = strftime( "%Y-%m-%dT%H:%M:%SZ", gmtime( $arcdata->{lastreadtime} ) );
    }

    for ( values %{$arcdata} ) { $_ = xml_escape($_); }

    $dbh->disconnect();
    return $arcdata;
}

# replaces LANraragi::Model::Opds::render_archive_page
sub render_archive_page {

    my ( $mojo, $id, $page ) = @_;

    my $logger = LANraragi::Utils::Logging::get_logger( "OPDS Page Serving", "lanraragi" );

    my $dbh     = get_dbh();
    my $archive = get_archive_path( $dbh, $id );
    $dbh->disconnect();

    # Parse archive to get its list of images
    my @images = get_filelist($archive, $id);

    # If the page number is invalid, use the first page.
    if ( $page > scalar @images ) {
        $page = 1;
    }

    # If the page number is valid, render the page.
    my $path = $images[ $page - 1 ];

    $logger->debug("Page /$id/$path was requested");

    # Implement page serving logic directly (replaces Archive::serve_page)
    # This avoids the Redis metadata access in Archive::serve_page -> get_page_data -> get_archive_path

    # Apply resizing transformation if set in Settings
    if ( LANraragi::Model::Config->enable_resize ) {

        # Store resized files in a subfolder of the ID's temp folder, keyed by quality
        my $threshold = LANraragi::Model::Config->get_threshold;
        my $quality   = LANraragi::Model::Config->get_readquality;

        my $cachekey = "resize_page/$id/$path/$threshold/$quality";
        my $content  = fetch($cachekey);
        if ( !defined($content) ) {
            # Get page data from cache or extract from archive
            my $page_cachekey = "page/$id/$path";
            my $page_content  = fetch($page_cachekey);
            if ( !defined($page_content) ) {
                # Extract the file from the parent archive using the Postgres-retrieved path
                $page_content = extract_single_file( $archive, $path );
                put( $page_cachekey, $page_content );
            }

            # Inline resize_image logic (replaces LANraragi::Model::Reader::resize_image)
            # Is the file size higher than the threshold?
            if ( ( ( length($page_content) / 1024 * 10 ) / 10 ) > $threshold ) {
                my $resizer = get_resizer();
                my $resized = $resizer->resize_page( $page_content, $quality, "jpg" );
                if ( defined($resized) ) {
                    $content = $resized;
                } else {
                    $content = $page_content;
                }
            } else {
                $content = $page_content;
            }

            put( $cachekey, $content );
        }

        # resize_image always converts the image to jpg
        $mojo->render_file(
            data                => $content,
            content_disposition => "inline",
            format              => "jpg"
        );
    } else {

        # Get the file extension to report content-type properly
        my ( $n, $p, $file_ext ) = fileparse( $path, qr/\.[^.]*/ );

        # Get page data from cache or extract from archive
        my $cachekey = "page/$id/$path";
        my $content  = fetch($cachekey);
        if ( !defined($content) ) {
            # Extract the file from the parent archive using the Postgres-retrieved path
            $content = extract_single_file( $archive, $path );
            put( $cachekey, $content );
        }

        $logger->debug( "Data size:" . length($content) );

        # Serve extracted file directly
        $mojo->render_file(
            data                => $content,
            content_disposition => "inline",
            format              => substr( $file_ext, 1 )
        );
    }
}

1;

#!/usr/bin/perl
BEGIN
{
	use strict;
	use utf8;
	use Encode qw( decode_utf8 encode_utf8 decode encode is_utf8 );
	use IO::File;
	use WWW::Mechanize;
	use HTTP::Cookies;
	use HTML::TreeBuilder;
	use Time::HiRes qw( gettimeofday tv_interval sleep time alarm );
	use HTTP::Date;
	use File::Basename;
	use JSON;
};

{
	## http://world-almanac.org/csv/democratic-republic-of-the-congo-file-basic.csv
	my $baseUrl = 'https://www.cia.gov/library/publications/the-world-factbook';
	our $COOKIE_FILE = "./cookies.txt";
	our $DATADIR = 'cache';
	our $POPULATION_PYRAMID = 'pyramid';
	mkdir( $DATADIR ) if( !-e( $DATADIR ) );
	mkdir( $POPULATION_PYRAMID ) if( !-e( $POPULATION_PYRAMID ) );
	## Contains the core structure of the section, category, sub-category found and check with other subsequent page for discrepancies
	## This is set only once with the first country
	## If there is a discrepancy, it will say so on the STDERR
	my $struct = {};
    
	our $out = IO::File->new();
	our $err = IO::File->new();
	$out->fdopen( fileno( STDOUT ), 'w' );
	$out->binmode( ":utf8" );
	$out->autoflush( 1 );
	$err->autoflush( 1 );
	$err->fdopen( fileno( STDERR ), 'w' );
	$err->binmode( ":utf8" );
	
	our $mech = WWW::Mechanize->new(
		## agent => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_6_8) AppleWebKit/534.59.10 (KHTML, like Gecko) Version/5.1.9 Safari/534.59.10',
		agent => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.10; rv:44.0) Gecko/20100101 Firefox/44.0',
		sleep => '1..3',
		cookie_jar => HTTP::Cookies->new('file' => $COOKIE_FILE, 'autosave' => 1, ignore_discard => 1)
	);
	$mech->add_header( 'Accept' => 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' );
	##$mech->add_header( 'Accept-Encoding' => 'gzip, deflate' );
	$mech->add_header( 'Accept-Language' => 'en-GB,fr-FR;q=0.8,fr;q=0.6,ja;q=0.4,en;q=0.2' );
	$mech->add_header( 'Connection' => 'keep-alive' );
	$mech->add_header( 'Referer' => $baseUrl );
	
	my $json = JSON->new->utf8->pretty->allow_nonref;
	
	## First we get the main page, and get the list of countries from the drop-down menu named 'selecter_links'
	$out->print( "Accessing $baseUrl\n" );
	my $resp = _get( $baseUrl, "$DATADIR/index.html" );
	if( !defined( $resp ) )
	{
		exit( 1 );
	}
	$out->print( "Parsing html located in $DATADIR/index.html\n" );
	my $tree = HTML::TreeBuilder->new;
	$tree->parse( $mech->content );
	$tree->eof();
	my $menu = $tree->look_down( _tag => 'select', name => 'selecter_links' );
	if( !defined( $menu ) )
	{
		$err->print( "Unable to find the menu holding all the available countries.\n" );
		exit( 1 );
	}
	my @pool = ();
	foreach my $opt ( $menu->look_down( _tag => 'option' ) )
	{
		## <option value="geos/xq.html"> Arctic Ocean </option>
		my $val = $opt->attr( 'value' );
		my $country = $opt->as_trimmed_text( 'extra_chars' => '[:space:]' );
		if( index( $val, 'geos' ) != -1 )
		{
			my $countryFile = basename( $val );
			my $code = lc( substr( $countryFile, 0, 2 ) );
			push( @pool, { 'link' => "$baseUrl/$val", 'country_name' => $country, 'country_file' => $countryFile, 'code' => $code } );
			#$out->print( "Adding country $country with link $val, code $code and local file $countryFile\n" );
		}
	}
	$out->printf( "Found %d countries to process\n", scalar( @pool ) );
	my $isFirstCountry = 1;
	my $countryData = {};
	for( my $i = 0; $i < scalar( @pool ); $i++ )
	{
		my $ref = $pool[ $i ];
		## Skip the 'World'
		next if( $ref->{ 'code' } eq 'xx' );
		my $link = $ref->{ 'link' };
		my $countryFile = $ref->{ 'country_file' };
		## Fetch some graphics first
		## https://www.cia.gov/library/publications/the-world-factbook/graphics/population/AF_popgraph%202015.bmp
		my $popPyramidLink = sprintf( 'https://www.cia.gov/library/publications/the-world-factbook/graphics/population/%s_popgraph %d.bmp', uc( $ref->{ 'code' } ), ( 1900 + ( localtime( time() ) )[5] ) - 1 );
		my $popFile = "$POPULATION_PYRAMID/" . $ref->{ 'code' } . '.bmp';
		if( !-e( $popFile ) || -z( $popFile ) )
		{
			my $respImg = '';
			eval
			{
				local $SIG{ '__DIE__' } = sub {};
				local $SIG{ '__WARN__' } = sub{};
				local $SIG{ 'ALRM' } = sub { die "alarm\n" };
				alarm( 20 );
				$respImg = $mech->get( $popPyramidLink, ':content_file' => $popFile );
				alarm( 0 );
			};
			my( $httpCode, $httpMsg ) = ( '', '' );
			$httpCode = $respImg->code if( $respImg );
			$httpMsg  = $respImg->message if( $respImg );
			if( $@ || !$mech->success )
			{
				$err->print( "Could not fetch remote image $popPyramidLink to local file $popFile: $httpMsg ($httpCode)\n[Error: $@]\n" );
			}
		}
		
		$out->printf( "Fetching data for country %s (%s) at url %s\n", @$ref{ qw( country_name code link ) } );
		my $resp2 = _get( $link, "$DATADIR/$countryFile" ) || exit( 1 );
		my $html = HTML::TreeBuilder->new;
		my $data = $mech->content;
		my $hash = {};
		$countryData->{ $ref->{ 'code' } } = $hash;
		## Searching for this string:
		## Page last updated on March 03, 2016
		if( $data =~ /Page[[:blank:]]+last[[:blank:]]+updated[[:blank:]]+on[[:blank:]]+([^<]+)</ )
		{
			my $date = $1;
		}
		else
		{
			$out->print( "\tCould not find the page last modification date\n" );
		}
		$html->parse( $data );
		$html->eof();
		## The meat is in a unordered list (ul) named 'expandcollapse'
		my $list = $html->look_down( _tag => 'ul', 'class' => 'expandcollapse' ) ||
		die( "Unable to find the data list expandcollapse\n" );
		## Each 'li' is a section name and the following 'li' contains its data, so there must be an even number of sections
		my @lis = $list->content_list;
		$hash->{ 'total_sections' } = ( scalar( @lis ) / 2 );
		$out->printf( "\tFound %d section. %s\n", $hash->{ 'total_sections' }, ( scalar( @lis ) % 2 ? 'Something is wrong' : 'Ok' ) );
		my $section_name = '';
		for( my $j = 0; $j < scalar( @lis ); $j++ )
		{
			my $o = $lis[ $j ];
			## print( ref( $o ) && $o->can( 'as_text' ) ? $o->tag : $o, "\n" );
			if( !ref( $o ) || !$o->isa( 'HTML::Element' ) )
			{
				next;
			}
			## li contains section name and section data
			if( $o->tag ne 'li' )
			{
				$err->print( "\t** Was expecting a tag li, but found a tag %s instead\n", $o->tag );
			}
			## An odd number, so we are in a section name
			if( !( $j % 2 ) )
			{
				## my $section_name = ( $o->as_text =~ /^[[:blank:]]*(.*?)[[:blank:]]+\:{2}/ )[0];
				## or we could also do :
				my $h2 = $o->look_down( _tag => 'h2' ) || 
				die( "Was expecting a h2 tag for this section name, but could not find one.\n" );
				$section_name = _trim( $h2->attr( 'sectiontitle' ) );
				$out->printf( "\tFound a section '$section_name' (%s)\n", $o->as_text );
				if( $isFirstCountry )
				{
					$struct->{ $section_name } = {};
				}
				elsif( !exists( $struct->{ $section_name } ) )
				{
					$err->printf( "\tFound a non-standard section $section_name for country %s (%s)\n", @$ref{ qw( country_name link ) } );
					$struct->{ $section_name } = {};
				}
				$hash->{ $section_name } = {};
			}
			## We are in a section data
			else
			{
				## We get all the divs
				## Then we check for div like <div id='field' class='category sas_light' that represent category name
				## and div class="category_data"> that represent category data
				## div that have no attribute, have spans inside that have a class equal to 'category' are sub-category and followed by sub-category data such as:
				## <span class="category">total: </span><span class="category_data">652,230 sq km</span>
				my @elems = $o->content_list;
				if( !scalar( @elems ) )
				{
					$out->print( "\t** There is no category or category data for section $section_name\n" );
				}
				my $cat_name = '';
				foreach my $el ( @elems )
				{
					next if( !ref( $el ) );
					##$out->printf( "\t\tFound tag %s with class attribute '%s' and id '%s'\n", $el->tag, $el->attr( 'class' ), $el->id );
					## I am expecting only divs
					if( $el->tag ne 'div' )
					{
						$err->print( "\t\tI was expecting a div, but got a %s instead for country %s\n", $e->tag, $ref->{ 'country_name' } );
						next;
					}
					## if( $el->tag eq 'div' && $el->attr( 'class' ) eq 'category sas_light' )
					if( $el->id eq 'field' )
					{
						$cat_name = _trim( $el->as_text );
						$out->print( "\t\tFound category $cat_name\n" );
						if( $isFirstCountry )
						{
							$struct->{ $section_name }->{ $cat_name } = {};
						}
						elsif( !exists( $struct->{ $section_name }->{ $cat_name } ) )
						{
							$err->printf( "\t\tFound a non-standard category $cat_name for section $section_name and for country %s (%s)\n", @$ref{ qw( country_name link ) } );
							$struct->{ $section_name }->{ $cat_name } = {};
						}
						$hash->{ $section_name }->{ $cat_name } = {};
					}
					elsif( $el->attr( 'class' ) eq 'category_data' )
					{
						my $str = $el->as_trimmed_text;
						$out->printf( "\t\tFound category data: %d bytes\n", length( $str ) );
						$hash->{ $section_name }->{ $cat_name }->{ 'data' } = $str;
					}
					## A div with no class implies a sub-category defined with spans
					elsif( $el->attr( 'class' ) eq '' )
					{
						my @subs = $el->look_down( _tag => 'span' );
						if( !scalar( @subs ) )
						{
							$out->print( "\t\t\tCould not find any sub data for the category $cat_name\n" );
						}
						my $subcat = '';
						##$out->printf( "\t\t\tFound %d span tags\n", scalar( @subs ) );
						foreach my $s ( @subs )
						{
							if( $s->attr( 'class' ) eq 'category' )
							{
								$subcat = _trim( $s->as_text );
								$out->print( "\t\t\tFound sub-category $subcat\n" );
								if( $isFirstCountry )
								{
									$struct->{ $section_name }->{ $cat_name }->{ $subcat } = {};
								}
								elsif( !exists( $struct->{ $section_name }->{ $cat_name }->{ $subcat } ) )
								{
									$err->printf( "\t\t\tFound a non-standard sub-category $subcat for category $cat_name and for section $section_name and for country %s (%s)\n", @$ref{ qw( country_name link ) } );
									$struct->{ $section_name }->{ $cat_name }->{ $subcat } = {};
								}
								$hash->{ $section_name }->{ $cat_name }->{ $subcat } = {};
							}
							elsif( $s->attr( 'class' ) eq 'category_data' )
							{
								my $str = $s->as_trimmed_text;
								##$out->print( "\t\t\tFound sub-category data: $str\n" );
								$out->printf( "\t\t\tFound sub-category data: %d bytes\n", length( $str ) );
								if( length( $hash->{ $section_name }->{ $cat_name }->{ $subcat }->{ 'data' } ) )
								{
									$hash->{ $section_name }->{ $cat_name }->{ $subcat }->{ 'data' } .= "\n\n" . $str;
								}
								else
								{
									$hash->{ $section_name }->{ $cat_name }->{ $subcat }->{ 'data' } = $str;
								}
							}
							else
							{
								$out->printf( "\t\t\tFound a span tag that looks like this: %s\n", $s->as_HTML( '' ) );
							}
						}
					}
					else
					{
						$out->printf( "\t\tFound an unrecognised div that looks like this: %s\n", $el->as_HTML( '' ) );
					}
				}
			}
		}
		$isFirstCountry = 0;
	}
	my $fh = IO::File->new( ">data.json" ) || die( "Unable to create file data.json\n" );
	$fh->print( $json->encode( $countryData ) );
	$fh->close;
	$fh = IO::File->new( ">structure.json" ) || die( "Unable to create file structure.json\n" );
	$fh->print( $json->encode( $struct ) );
	$fh->close;
    exit( 0 );
}

sub _trim
{
	my $str = shift( @_ );
	$str =~ s/^[[:blank:]]+|[[:blank:]]+$//g;
	$str =~ s/\:$//g;
	return( $str );
}

sub _get
{
	my $url  = shift( @_ );
	my $file = shift( @_ );
	$out->print( "## Accessing url $url\n" );
	## Check if there is a newer proxy list file
	my $resp = '';
    if( -e( $file ) ) 
    {
        my $mtime = ( stat($file) )[9];
        if( $mtime ) 
        {
        	$out->printf( "Setting the If-Modified-Since header to %s\n", scalar( localtime( $mtime ) ) );
            $mech->add_header( 'If-Modified-Since' => HTTP::Date::time2str( $mtime ) );
        }
    }
	eval
	{
		local $SIG{'__DIE__'} = sub {};
		local $SIG{ 'ALRM' } = sub { die "alarm\n" };
		alarm( 60 );
		##$resp = $mech->mirror( $url, $file );
		##decoded_content
		$resp = $mech->get( $url );
		alarm( 0 );
	};
	$mech->delete_header( 'If-Modified-Since' );
	if( $@ || ( !$mech->success && $resp->code != 304 ) )
	{
		my $this_url = $mech->uri;
		$out->print( "\t## URI is now '$this_url' (was '$url')\n" );
		return( undef() );
	}
	elsif( $resp->code == 304 )
	{
		$out->print( "Using cache file $file instead of remote file\n" );
		my $fh = IO::File->new( "<$file" ) || die( "Unable to read file $file: $!\n" );
		$fh->binmode( ":utf8" );
		my $data = join( '', $fh->getlines );
		$fh->close;
		$data = decode_utf8( $data ) if( !is_utf8( $data ) );
		$mech->{ 'content' } = $data;
	}
	## The file does not exist yet or has changed
	elsif( $mech->success || !-e( $file ) )
	{
		my $io = IO::File->new( ">$file" ) || die( "Cannot open file $file in write mode: $!\n" );
		$io->binmode( ":utf8" );
		my $data = $resp->decoded_content;
		$data    = decode_utf8( $data ) if( !is_utf8( $data ) );
		$io->print( $data );
		$io->close;
		## Make sure the data is in utf8
		$mech->{ 'content' } = $data;
		if( my $lm = $resp->last_modified ) 
		{
			utime( $lm, $lm, $file );
		}
		return( $resp );
	}
	return( $resp );
}


__END__

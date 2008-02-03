package WEC::PlRPC::Server;
use 5.006;
use strict;
use warnings;
use Carp;

use WEC::PlRPC::Connection;

our $VERSION = "1.000";
our @CARP_NOT	= qw(WEC::FieldServer);

use base qw(WEC::Server);

my $default_options = {
    %{__PACKAGE__->SUPER::server_options},
    InCipher	=> undef,
    OutCipher	=> undef,
    Cipher	=> undef,
    Compression	=> undef,
    Application	=> undef,
    Version	=> undef,
    MaxMessage	=> 2**16,
    AcceptApplication	=> undef,
    AcceptVersion	=> undef,
    AcceptUser		=> undef,
    Methods		=> undef,
};

sub default_options {
    return $default_options;
}

sub connection_class {
    return shift->{options}{Application};
}

sub init {
    my ($server, $params) = @_;
    my $options = $server->{options};
    defined $options->{Application}	|| croak "No Application specified";
    defined $options->{Version}		|| croak "No Version specified";
    defined $options->{Methods}		|| croak "No Methods specified";
    if ($options->{Compression}) {
        my $comp = uc($options->{Compression});
        if ($comp eq "GZIP") {
	    require Compress::Zlib;
        } else {
            croak "Unknown compression method '$server->{options}{Compression}'";
        }
    }
    if (defined(my $cipher = delete $params->{Cipher})) {
        croak "Both InCipher and Cipher"  if defined $options->{InCipher};
        croak "Both OutCipher and Cipher" if defined $options->{OutCipher};
        $options->{InCipher} = $options->{OutCipher} = $cipher;
    }
    $options->{InBlockSize} = $options->{InCipher}->blocksize if 
        $options->{InCipher};
    $options->{OutBlockSize} = $options->{OutCipher}->blocksize if 
        $options->{OutCipher};
}

1;
__END__
